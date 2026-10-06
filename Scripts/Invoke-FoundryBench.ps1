<#
.SYNOPSIS
    Benchmark Microsoft Foundry Local over its OpenAI-compatible endpoint and
    record the result in the Atlas benchmark history.

.DESCRIPTION
    Automates the README "Foundry Local" section.

    Foundry Local is driven over HTTP rather than by a CLI that prints timings,
    so throughput is measured here: wall time around the request, divided by
    the `completion_tokens` the server reports. That is end-to-end token
    throughput including HTTP overhead, which is what a Scout-like client would
    actually see -- it is not directly comparable to geniex-bench's isolated
    decode rate.

    NPU and CPU utilization are sampled during the run, because "it used the
    NPU" is a placement claim that needs evidence. The NPU appears as an
    ordinary GPU Engine counter under engtype_compute (see the README, "Proving which compute unit ran"); the wildcard
    is re-expanded on every sample because those instances are per-process and
    do not exist until the workload starts.

.PARAMETER Model
    Foundry model alias. The NPU variant is selected by Foundry per model;
    `foundry model info <model>` lists which.

.PARAMETER MaxTokens
    Upper bound on generated tokens. Actual count comes from the response.

.PARAMETER Repeat
    Measured runs.

.PARAMETER NoRecord
    Print results without appending them to the benchmark history.

.EXAMPLE
    .\Scripts\Invoke-FoundryBench.ps1

.EXAMPLE
    .\Scripts\Invoke-FoundryBench.ps1 -Model qwen2.5-1.5b -Repeat 5
#>
[CmdletBinding()]
param(
    [string]$Model = 'phi-3.5-mini',
    [string]$Prompt = 'Plan a detailed day in Lisbon, with specific neighbourhoods, food and timings.',
    [int]$MaxTokens = 400,
    [int]$Repeat = 3,
    [switch]$NoRecord
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force

if (-not (Get-Command foundry -ErrorAction SilentlyContinue)) {
    Write-Host 'foundry not found on PATH. See the README "Foundry Local" section.' -ForegroundColor Red
    exit 1
}

# `foundry server start` is idempotent and prints the endpoint; `foundry
# status` reports it as "Web URLs" once running. Ask the server to start
# rather than assuming it is, since it stops between sessions.
$startOut = (foundry server start 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
$status   = (foundry status 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
$endpoint = $null
foreach ($text in @($startOut, $status)) {
    $m = [regex]::Match($text, 'http://127\.0\.0\.1:(\d+)')
    if ($m.Success) { $endpoint = $m.Value; break }
}
if (-not $endpoint) {
    Write-Host 'Could not determine the Foundry endpoint.' -ForegroundColor Red
    Write-Host ($startOut.Trim())
    exit 1
}

$state = Get-AtlasState
Write-Host 'Foundry Local benchmark' -ForegroundColor Cyan
Write-Host ("stack {0} | foundry {1}" -f (Get-AtlasShortId $state.id), $state.foundry)
Write-Host "endpoint: $endpoint"
Write-Host "model   : $Model"
Write-Host ''

# The CLI takes an alias ("phi-3.5-mini") but the OpenAI API wants the concrete
# variant id ("phi-3.5-mini-instruct-qnn-npu"); the alias appears only as the
# variant's `parent`. Passing the alias returns a bare 400 with no hint, so
# resolve it here. A loaded NPU variant is preferred when several match.
$resolved = $Model
try {
    $catalog = Invoke-RestMethod -Uri "$endpoint/v1/models" -TimeoutSec 60
    $ids = @($catalog.data)
    if (-not ($ids | Where-Object { $_.id -eq $Model })) {
        $match = @($ids | Where-Object { $_.parent -eq $Model })
        $npu   = @($match | Where-Object { $_.id -match 'qnn-npu' })
        $pick  = if ($npu.Count) { $npu[0] } elseif ($match.Count) { $match[0] } else { $null }
        if ($pick) {
            $resolved = $pick.id
            Write-Host "resolved: $Model -> $resolved"
        }
        else {
            Write-Host "Model '$Model' is not loaded. Available:" -ForegroundColor Yellow
            $ids | ForEach-Object { Write-Host ("  {0}" -f $_.id) }
            Write-Host 'Download one with: foundry model download <alias>' -ForegroundColor DarkGray
            exit 1
        }
    }
}
catch {
    Write-Host "Could not list models: $($_.Exception.Message)" -ForegroundColor Yellow
}
# Being downloaded is not the same as being loaded: /v1/models lists what is
# available on disk, but a request against an unloaded model returns 400 with
# "Model ... is not loaded". Load it explicitly, which is idempotent and cheap
# once it is already resident.
Write-Host "loading $Model ..."
$loadOut = (foundry model load $Model 2>&1 | Out-String) -replace '\[[0-9;]*m', ''
if ($loadOut -notmatch 'success|Loaded') {
    Write-Host '  load did not report success:' -ForegroundColor Yellow
    Write-Host ('  ' + $loadOut.Trim())
}
Write-Host ''

$uri  = "$endpoint/v1/chat/completions"
$rows = [System.Collections.Generic.List[object]]::new()

for ($run = 1; $run -le $Repeat; $run++) {
    $body = @{
        model       = $resolved
        messages    = @(@{ role = 'user'; content = $Prompt })
        max_tokens  = $MaxTokens
        temperature = 0.7
    } | ConvertTo-Json -Depth 5 -Compress

    $job = Start-Job -ScriptBlock {
        param($Uri, $Body)
        try {
            $r = Invoke-RestMethod -Uri $Uri -Method Post -Body $Body `
                    -ContentType 'application/json' -TimeoutSec 600
            [pscustomobject]@{ Ok = $true; Tokens = $r.usage.completion_tokens }
        }
        catch { [pscustomobject]@{ Ok = $false; Error = $_.Exception.Message } }
    } -ArgumentList $uri, $body

    $npuPeak = 0.0; $cpuPeak = 0.0; $cpuSum = 0.0; $cpuN = 0
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($job.State -eq 'Running') {
        try {
            # Re-expanded every sample: GPU Engine instances are per-process
            # and do not exist before the workload starts.
            $g = (Get-Counter '\GPU Engine(*engtype_compute)\Utilization Percentage' -EA Stop).CounterSamples |
                 Measure-Object CookedValue -Maximum
            if ($g.Maximum -gt $npuPeak) { $npuPeak = [math]::Min($g.Maximum, 100) }
            $c = (Get-Counter '\Processor Information(_Total)\% Processor Time' -EA Stop).CounterSamples[0].CookedValue
            $cpuSum += $c; $cpuN++
            if ($c -gt $cpuPeak) { $cpuPeak = $c }
        }
        catch { }
        if ($sw.Elapsed.TotalSeconds -gt 600) { break }
    }
    $sw.Stop()
    $res = Receive-Job $job -Wait
    Remove-Job $job -Force

    if (-not $res.Ok) {
        Write-Host ("  run {0}: FAILED - {1}" -f $run, $res.Error) -ForegroundColor Red
        continue
    }
    $tokens = [int]$res.Tokens
    $secs   = $sw.Elapsed.TotalSeconds
    $tps    = if ($secs -gt 0) { $tokens / $secs } else { 0 }
    $rows.Add([pscustomobject]@{
        Run      = $run
        Tokens   = $tokens
        Seconds  = [math]::Round($secs, 2)
        TokPerS  = [math]::Round($tps, 1)
        NPUPeak  = [math]::Round($npuPeak, 1)
        CPUMean  = if ($cpuN) { [math]::Round($cpuSum / $cpuN, 1) } else { 0 }
    })
    Write-Host ("  run {0}: {1,6:N1} tok/s  {2} tok in {3:N1}s  NPU peak {4:N1}%  CPU mean {5:N1}%" -f `
        $run, $tps, $tokens, $secs, $npuPeak, $(if ($cpuN) { $cpuSum / $cpuN } else { 0 }))
}

if ($rows.Count -eq 0) { Write-Host 'No run succeeded.' -ForegroundColor Red; exit 1 }

Write-Host ''
$rows | Format-Table -AutoSize | Out-String | Write-Host

$meanTps = ($rows | Measure-Object TokPerS -Average).Average
$meanCpu = ($rows | Measure-Object CPUMean -Average).Average
# Peak aggregates by maximum: one sample that caught the active phase is proof
# of placement, whereas averaging would dilute it with idle samples.
$maxNpu  = ($rows | Measure-Object NPUPeak -Maximum).Maximum
Write-Host ("mean {0:N1} tok/s | NPU peak {1:N1}% | CPU mean {2:N1}%" -f $meanTps, $maxNpu, $meanCpu)

if (-not $NoRecord) {
    # Derive the compute unit from the resolved variant rather than assuming the
    # NPU: Foundry publishes one variant per unit, and the GPU and CPU ones were
    # being recorded as NPU runs.
    $unit = switch -Regex ($resolved) {
        'qnn-npu'     { 'npu';  break }
        'generic-gpu' { 'gpu';  break }
        'generic-cpu' { 'cpu';  break }
        default       { 'auto' }
    }
    Add-AtlasBenchmarkRecord -State $state -Source 'Invoke-FoundryBench.ps1' `
        -Model $Model -Compute "foundry/$unit" `
        -TokPerSec ([math]::Round($meanTps, 1)) `
        -Tokens ([int](($rows | Measure-Object Tokens -Average).Average)) `
        -Extra @{ runs = $rows.Count; npuPeak = $maxNpu; cpuMean = [math]::Round($meanCpu, 1)
                  harness = 'foundry openai endpoint' } | Out-Null
    Write-Host ("Recorded under stack {0}; see -History" -f (Get-AtlasShortId $state.id)) -ForegroundColor Green
}
