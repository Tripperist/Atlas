<#
.SYNOPSIS
    Verify that a Foundry Local model emits tool calls, and measure whether it
    stays on the NPU while doing so.

.DESCRIPTION
    Automates the README section 12 backlog item.

    Scout needs tool calls, and "Tools: yes" in the catalogue is not evidence
    of the two things that must both hold:

      1. the model returns `tool_calls` for a prompt that needs one;
      2. it is still on the NPU while doing so.

    The second matters because constrained or grammar-based decoding can run
    outside the accelerated path, which would look like success unless
    placement is measured during the tool call specifically.

    Two measurement traps shaped this script:

    * A single tool call returns in about a second, and each Get-Counter
      sample also costs about a second, so one-shot sampling reads near-random
      values. Every condition is therefore driven as a sustained loop over a
      fixed window.

    * A long plain completion is not a fair control for a short tool call,
      because duty cycle alone would explain a lower reading. The control is
      therefore length-matched: the same prompt with `max_tokens` capped to
      roughly a tool call's length, so only the tools array differs.

    `\GPU Engine(*engtype_compute)\Utilization Percentage` is the NPU counter
    (section 7). The wildcard is re-expanded every sample because those
    instances are per-process, and no adapter LUID is hardcoded because LUIDs
    change across reboots.

.PARAMETER Model
    Foundry alias whose selected variant is the NPU one; check with
    `foundry model list`.

.PARAMETER Seconds
    Length of each measurement window.

.EXAMPLE
    .\Scripts\Test-ToolCalling.ps1 -Model qwen2.5-0.5b
#>
[CmdletBinding()]
param(
    [string]$Model = 'qwen2.5-0.5b',
    [int]$Seconds = 25,
    [int]$ControlMaxTokens = 40
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force

if (-not (Get-Command foundry -ErrorAction SilentlyContinue)) {
    Write-Host 'foundry not found on PATH. See README section 5.6.' -ForegroundColor Red
    exit 1
}

$startOut = (foundry server start 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
$status   = (foundry status 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
$endpoint = $null
foreach ($t in @($startOut, $status)) {
    $m = [regex]::Match($t, 'http://127\.0\.0\.1:(\d+)')
    if ($m.Success) { $endpoint = $m.Value; break }
}
if (-not $endpoint) { Write-Host 'No Foundry endpoint.' -ForegroundColor Red; exit 1 }

$state = Get-AtlasState
Write-Host 'Foundry tool calling on the NPU' -ForegroundColor Cyan
Write-Host ("stack {0} | foundry {1}" -f (Get-AtlasShortId $state.id), $state.foundry)
Write-Host ''

# Record the catalogue's device, so a pass is not read as "on the NPU" when
# Foundry actually selected the GPU variant.
$listRaw = (foundry model list 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
$row = ($listRaw -split "`r?`n" | Where-Object { $_ -match "\|\s*$([regex]::Escape($Model))\s*\|" } | Select-Object -First 1)
$device = if ($row -match '\|\s*(NPU|GPU|CPU)\s*\|') { $Matches[1] } else { 'unknown' }
Write-Host "catalogue device : $device"
if ($device -ne 'NPU') {
    Write-Host '  Not an NPU model here; a pass proves nothing about NPU tool calling.' -ForegroundColor Yellow
}

$null = foundry model load $Model 2>&1
$resolved = $Model
try {
    $catalog = Invoke-RestMethod -Uri "$endpoint/v1/models" -TimeoutSec 60
    $hit = @($catalog.data) | Where-Object { $_.id -eq $Model -or $_.parent -eq $Model } |
           Sort-Object { if ($_.id -match 'qnn-npu') { 0 } else { 1 } } | Select-Object -First 1
    if ($hit) { $resolved = $hit.id }
}
catch { }
Write-Host "variant          : $resolved"
Write-Host ''

$tools = @(
    @{
        type     = 'function'
        function = @{
            name        = 'get_weather'
            description = 'Get the current weather for a city.'
            parameters  = @{
                type       = 'object'
                properties = @{ city = @{ type = 'string'; description = 'City name' } }
                required   = @('city')
            }
        }
    }
)
$question = 'What is the weather in Lisbon?'

function Measure-Window {
    param([string]$Label, [string]$Body)

    $job = Start-Job -ScriptBlock {
        param($U, $B, $Secs)
        $n = 0; $tok = 0; $calls = 0; $err = $null
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        while ($sw.Elapsed.TotalSeconds -lt $Secs) {
            try {
                $r = Invoke-RestMethod -Uri $U -Method Post -Body $B -ContentType 'application/json' -TimeoutSec 120
                $n++
                $tok += [int]$r.usage.completion_tokens
                $calls += @($r.choices[0].message.tool_calls).Count
            }
            catch { if (-not $err) { $err = $_.ErrorDetails.Message ?? $_.Exception.Message } }
        }
        [pscustomobject]@{ Requests = $n; Tokens = $tok; ToolCalls = $calls; Error = $err }
    } -ArgumentList "$endpoint/v1/chat/completions", $Body, $Seconds

    $peak = 0.0
    while ($job.State -eq 'Running') {
        try {
            $g = (Get-Counter '\GPU Engine(*engtype_compute)\Utilization Percentage' -EA Stop).CounterSamples |
                 Measure-Object CookedValue -Maximum
            if ($g.Maximum -gt $peak) { $peak = [math]::Min($g.Maximum, 100) }
        }
        catch { }
    }
    $r = Receive-Job $job -Wait
    Remove-Job $job -Force
    [pscustomobject]@{
        Condition = $Label
        Requests  = $r.Requests
        Tokens    = $r.Tokens
        ToolCalls = $r.ToolCalls
        NPUPeak   = [math]::Round($peak, 1)
        Error     = $r.Error
    }
}

function New-Body {
    param([hashtable]$Extra, [int]$MaxTokens)
    $b = @{
        model      = $resolved
        messages   = @(@{ role = 'user'; content = $question })
        max_tokens = $MaxTokens
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $b[$k] = $Extra[$k] } }
    $b | ConvertTo-Json -Depth 10 -Compress
}

Write-Host "measuring, $Seconds s per condition ..." -ForegroundColor DarkGray
$results = @(
    (Measure-Window 'plain (length-matched control)' (New-Body $null $ControlMaxTokens)),
    (Measure-Window 'tools, tool_choice=auto'       (New-Body @{ tools = $tools; tool_choice = 'auto' } 120)),
    (Measure-Window 'tools, tool_choice=required'   (New-Body @{ tools = $tools; tool_choice = 'required' } 120))
)

Write-Host ''
$results | Format-Table -AutoSize -Property Condition, Requests, Tokens, ToolCalls, NPUPeak |
    Out-String | Write-Host

foreach ($r in $results) {
    if ($r.Error) { Write-Host ("  {0}: first error -- {1}" -f $r.Condition, $r.Error) -ForegroundColor Yellow }
}

$control  = $results[0]
$auto     = $results[1]
$required = $results[2]

Write-Host 'Findings' -ForegroundColor Cyan
Write-Host '--------'
Write-Host ("  tool calls under auto     : {0}" -f $auto.ToolCalls)
Write-Host ("  tool calls under required : {0} of {1} requests" -f $required.ToolCalls, $required.Requests)
Write-Host ("  NPU peak, control         : {0}%" -f $control.NPUPeak)
Write-Host ("  NPU peak, tool calling    : {0}%" -f $required.NPUPeak)
Write-Host ''

if ($required.ToolCalls -eq 0) {
    Write-Host 'RESULT: no tool_calls even when required -- tool calling does not work here.' -ForegroundColor Red
    exit 1
}

Write-Host 'RESULT: tool calling WORKS on this variant.' -ForegroundColor Green
if ($auto.ToolCalls -eq 0) {
    Write-Host '  But not under tool_choice=auto: the model does not choose to call the' -ForegroundColor Yellow
    Write-Host '  tool on its own. That is a model-capability limit, not a runtime one.' -ForegroundColor Yellow
}
# A markedly lower peak than a length-matched control is the signature the
# backlog item predicted for constrained decoding leaving the accelerated path.
if ($control.NPUPeak -gt 0 -and $required.NPUPeak -lt ($control.NPUPeak * 0.6)) {
    Write-Host ('  NPU utilization during tool calls is well below the length-matched ' +
                'control, so part of the work appears to leave the accelerated path.') -ForegroundColor Yellow
}
exit 0
