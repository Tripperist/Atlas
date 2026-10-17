<#
.SYNOPSIS
    Measure Foundry Local prefill, first-token time and decode against prompt length,
    over HTTP or in process, and record each cell in the benchmark history.

.DESCRIPTION
    The published Foundry context-length curves (docs/BENCHMARKS.md, "Prefill against
    prompt length") came from scratch scripts. This is that measurement, committed.

    HTTP route (default). For every prompt size and every model, interleaved, one
    stateless, streamed request gives: the time to the first token; the EXACT prompt length
    (`usage.prompt_tokens`), so prefill tok/s is that length over the first-token time
    (which includes producing the token and the HTTP hop); and decode tok/s over the time
    after the first token.

    The prompt is built by New-BenchPrompt.ps1 from pinned repository text, so it can be
    rebuilt byte for byte; its SHA256 is recorded. Request bodies are sent as UTF-8 bytes.
    Nothing samples utilization during a timed request (a sampler lowers the rate), so
    this measures speed and does not prove placement; see Invoke-FoundryBench.ps1 for that.

    -InProcess runs the same prompts through bench_foundry_sdk.py (the Python SDK, a fresh
    ChatSession per run). The SDK does not report prompt_tokens, so the exact count comes
    from an earlier HTTP run of the same prompt and model, kept in
    .atlas-local/benchmarks/prompts/counts.json; without one, the target is used and a
    warning says so. The SDK loads the model into its own process, so a daemon holding the
    same model on the NPU must be unloaded first; the conditions check says so.

    Models are loaded by this script and unloaded again, but only the ones it loaded. The
    daemon is stopped afterwards only if this script started it.

.PARAMETER Model
    Foundry aliases. `alias@npu`, `alias@gpu` or `alias@cpu` selects a hardware variant
    over HTTP; the in-process route cannot choose one. Several models are interleaved.

.PARAMETER PromptTokens
    Target prompt lengths. The exact length each run used is read from the server and
    recorded; it differs from the target by several percent.

.PARAMETER MaxTokens
    Tokens to generate, 64 or more: a small value relative to the prompt fails in
    GroupQueryAttention on Foundry (see AtlasFoundry.psm1).

.PARAMETER Repeat
    Measured runs per cell, after one warm-up request per model.

.PARAMETER InProcess
    Use the Python SDK instead of HTTP.

.PARAMETER KeepRunning
    Leave the daemon running even if this script started it.

.PARAMETER NoRecord
    Print results without appending them to the history.

.EXAMPLE
    pwsh -Command "& .\Scripts\Invoke-FoundryContextBench.ps1 -Model qwen2.5-coder-7b -PromptTokens 512,2048,4096"

.EXAMPLE
    # the same lengths through the SDK; run the HTTP route first so the counts are exact
    pwsh -Command "& .\Scripts\Invoke-FoundryContextBench.ps1 -Model qwen2.5-coder-7b -PromptTokens 512,2048,4096 -InProcess"
#>
#requires -Version 7
[CmdletBinding()]
param(
    [string[]]$Model = @('qwen2.5-coder-7b'),
    [int[]]$PromptTokens = @(512, 2048, 4096),
    [ValidateRange(64, 4096)][int]$MaxTokens = 128,
    [int]$Repeat = 2,
    [switch]$InProcess,
    [switch]$KeepRunning,
    [switch]$NoRecord,
    # Run on battery anyway; the result is recorded as onAcPower = false
    [switch]$AllowBattery
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AtlasConditions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AtlasFoundry.psm1') -Force
if (-not (Get-Command foundry -ErrorAction SilentlyContinue)) {
    Write-Host 'foundry not found on PATH. See the README "Foundry Local" section.' -ForegroundColor Red
    exit 1
}
$newPrompt = Join-Path $PSScriptRoot 'New-BenchPrompt.ps1'
$countsPath = Join-Path $root '.atlas-local/benchmarks/prompts/counts.json'

function Get-Counts { if (Test-Path $countsPath) { Get-Content $countsPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} } }
function Save-Count([string]$Sha, [string]$Alias, [int]$Count) {
    $c = Get-Counts
    if (-not $c.ContainsKey($Sha)) { $c[$Sha] = @{} }
    $c[$Sha][$Alias] = $Count
    New-Item -ItemType Directory -Force -Path (Split-Path $countsPath) | Out-Null
    $c | ConvertTo-Json -Depth 4 | Set-Content $countsPath -Encoding utf8
}

# ------------------------------------------------------------------ in process

if ($InProcess) {
    # bench_foundry_sdk.py checks the conditions itself, in its own process, and refuses if a
    # daemon holds a model on the NPU. Nothing here starts the daemon.
    $py = Join-Path $root '.venv\Scripts\python.exe'
    if (-not (Test-Path $py)) { $py = 'python' }
    $sdk = Join-Path $root 'src\setup\bench_foundry_sdk.py'
    $sizeIndex = 0; $failures = 0
    foreach ($size in $PromptTokens) {
        $ordered = if ($sizeIndex % 2 -eq 1) { @($Model)[($Model.Count - 1)..0] } else { @($Model) }
        $sizeIndex++
        $p = & $newPrompt -Tokens $size
        foreach ($spec in $ordered) {
            if ($spec -match '@') { Write-Host "  $spec : the SDK cannot choose a variant; using the alias." -ForegroundColor Yellow }
            $alias = ($spec -split '@')[0]
            $count = (Get-Counts)[$p.Sha256]?[$alias]
            if (-not $count) {
                Write-Host "  no exact count for $alias on this prompt; recording the target ($size). Run the HTTP route first." -ForegroundColor Yellow
                $count = $size
            }
            Write-Host ("  {0,6} tok (target)  {1}  in process ..." -f $size, $alias)
            $argv = @($sdk, '--model', $alias, '--prompt-file', $p.Path, '--prompt-tokens', $count,
                      '--max-tokens', $MaxTokens, '--repeat', $Repeat)
            if ($AllowBattery) { $argv += '--allow-battery' }
            if ($NoRecord) { $argv += '--no-record' }
            & $py @argv
            if ($LASTEXITCODE -ne 0) { $failures++ }
        }
    }
    exit $(if ($failures) { 1 } else { 0 })
}

# ------------------------------------------------------------------------ HTTP

$needsNpu = @($Model | Where-Object { $_ -notmatch '@(gpu|cpu)$' }).Count -gt 0
# The Foundry daemon is the thing under test here, so it is expected and not flagged.
$null = Assert-AtlasConditions -Needs $(if ($needsNpu) { 'npu' } else { @() }) -AllowBattery:$AllowBattery -Expect 'foundry'

$state = Get-AtlasState
$daemon = Start-FoundryDaemon
$endpoint = $daemon.Endpoint
Write-Host 'Foundry Local context benchmark (HTTP)' -ForegroundColor Cyan
Write-Host ("stack {0} | foundry {1} | endpoint {2}{3}" -f (Get-AtlasShortId $state.id), $state.foundry, $endpoint,
    $(if ($daemon.StartedByUs) { ' (started by this script)' } else { '' }))

$loadedBefore = @(Get-FoundryLoadedAliases)
$weLoaded = [System.Collections.Generic.List[string]]::new()
$targets = foreach ($spec in $Model) {
    $v = Resolve-FoundryVariant -Endpoint $endpoint -Spec $spec
    [pscustomobject]@{ Spec = $spec; Alias = $v.Alias; Id = $v.Id; Unit = $v.Unit }
}

function Initialize-Targets {
    foreach ($t in $targets) {
        # A unit-specific spec is loaded by its variant id; a bare alias lets Foundry choose.
        $arg = if ($t.Spec -match '@') { $t.Id } else { $t.Alias }
        Write-Host "loading $arg ..."
        $out = (foundry model load $arg 2>&1 | Out-String) -replace '\x1b\[[0-9;]*[a-zA-Z]', ''
        if ($out -notmatch 'success|Loaded') { throw "load did not report success: $($out.Trim())" }
        if ($t.Alias -notin $loadedBefore -and $t.Alias -notin $weLoaded) { $weLoaded.Add($t.Alias) }
        # One short request so graph initialisation is not in the first timed run.
        $null = Invoke-FoundryStream -Endpoint $endpoint -Model $t.Id -Prompt 'Say hello in one short sentence.' -MaxTokens 64
    }
}

$cells = [System.Collections.Generic.List[object]]::new()
try {
    Initialize-Targets
    $sizeIndex = 0
    foreach ($size in $PromptTokens) {
        $p = & $newPrompt -Tokens $size
        $text = [System.IO.File]::ReadAllText($p.Path)
        # Reverse the order on alternate sizes so a drift in machine state does not belong to one model.
        $ordered = if ($sizeIndex % 2 -eq 1) { @($targets)[($targets.Count - 1)..0] } else { @($targets) }
        $sizeIndex++
        $orderLabel = ($ordered | ForEach-Object { "$($_.Alias)/$($_.Unit)" }) -join '>'

        foreach ($t in $ordered) {
            $rows = [System.Collections.Generic.List[object]]::new()
            for ($i = 1; $i -le $Repeat; $i++) {
                try {
                    $str = Invoke-FoundryStream -Endpoint $endpoint -Model $t.Id -Prompt $text -MaxTokens $MaxTokens
                    if (-not $str.PromptTokens) { throw 'the server sent no usage block, so the prompt length is unknown' }
                    $rows.Add([pscustomobject]@{ Str = $str; Prefill = $str.PromptTokens / $str.FirstTokenS })
                }
                catch {
                    $msg = ($_.ErrorDetails.Message ?? $_.Exception.Message) -replace '\s+', ' '
                    Write-Host ("  {0,6} tok  {1,-26} run {2}: FAILED - {3}" -f $size, "$($t.Alias)/$($t.Unit)", $i, $msg.Substring(0, [Math]::Min(160, $msg.Length))) -ForegroundColor Red
                    # A failed request has taken the daemon down before; bring it back so later cells can run.
                    try { $null = Invoke-RestMethod -Uri "$endpoint/v1/models" -TimeoutSec 10 }
                    catch {
                        Write-Host '  the daemon stopped answering; restarting it' -ForegroundColor Yellow
                        $d2 = Start-FoundryDaemon; $endpoint = $d2.Endpoint
                        if ($d2.StartedByUs) { $daemon.StartedByUs = $true }
                        Initialize-Targets
                    }
                }
            }
            if ($rows.Count -eq 0) { continue }

            $exact = [int]($rows | ForEach-Object { $_.Str.PromptTokens } | Select-Object -First 1)
            $dec = @($rows | ForEach-Object { $_.Str.DecodeTps })
            $ttft = @($rows | ForEach-Object { $_.Str.FirstTokenS })
            $pre = @($rows | ForEach-Object { $_.Prefill })
            $gen = @($rows | ForEach-Object { $_.Str.Tokens })
            $stdev = if ($dec.Count -gt 1) { [math]::Sqrt((($dec | ForEach-Object { ($_ - ($dec | Measure-Object -Average).Average) * ($_ - ($dec | Measure-Object -Average).Average) }) | Measure-Object -Sum).Sum / ($dec.Count - 1)) } else { $null }
            $cell = [pscustomobject]@{
                Size = $size; Target = $t; PromptTokens = $exact; Prompt = $p; Order = $orderLabel; N = $rows.Count
                Decode = ($dec | Measure-Object -Average).Average; Ttft = ($ttft | Measure-Object -Average).Average
                Prefill = ($pre | Measure-Object -Average).Average; Gen = [int](($gen | Measure-Object -Average).Average)
                DecodeStdev = $stdev; DecodeReps = $dec
            }
            $cells.Add($cell)
            Save-Count -Sha $p.Sha256 -Alias $t.Spec -Count $exact
            Write-Host ("  {0,6} tok  {1,-26} {2,5} prompt tok | prefill {3,6:N0} tok/s | first token {4,6:N2} s | decode {5,5:N1} tok/s" -f `
                $size, "$($t.Alias)/$($t.Unit)", $exact, $cell.Prefill, $cell.Ttft, $cell.Decode)
        }
    }
}
finally {
    foreach ($a in $weLoaded) { $null = foundry model unload $a 2>&1 }
    if ($daemon.StartedByUs -and -not $KeepRunning) {
        $null = foundry server stop 2>&1
        Write-Host 'stopped the daemon this script started' -ForegroundColor DarkGray
    }
}

Write-Host ''
if ($cells.Count -eq 0) { Write-Host 'No cell produced a result.' -ForegroundColor Red; exit 1 }

if (-not $NoRecord) {
    foreach ($c in $cells) {
        Add-AtlasBenchmarkRecord -State $state -Source 'Invoke-FoundryContextBench.ps1' `
            -Model $c.Target.Alias -Compute "foundry/$($c.Target.Unit)" `
            -TokPerSec ([math]::Round($c.Decode, 1)) -FirstTokenS ([math]::Round($c.Ttft, 3)) `
            -Tokens $c.Gen -PrefillTps ([math]::Round($c.Prefill, 1)) -PromptTokens $c.PromptTokens `
            -N $c.N -Stdev $(if ($null -ne $c.DecodeStdev) { [math]::Round($c.DecodeStdev, 2) } else { $null }) `
            -Reps @($c.DecodeReps | ForEach-Object { [math]::Round($_, 1) }) `
            -Order $c.Order -PromptKind 'repo-source (New-BenchPrompt.ps1)' `
            -Harness 'foundry openai endpoint (context)' -ModelArtifact $c.Target.Id `
            -Extra @{ statistic = 'mean'; promptSha256 = $c.Prompt.Sha256; targetTokens = $c.Size; maxTokens = $MaxTokens
                      temperature = 0; streamed = $true; throughputSampled = $false
                      prefillBasis = 'prompt_tokens / first-token time' } | Out-Null
    }
    Write-Host ("Recorded {0} cell(s) under stack {1}" -f $cells.Count, (Get-AtlasShortId $state.id)) -ForegroundColor Green
}
