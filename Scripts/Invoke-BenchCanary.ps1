<#
.SYNOPSIS
    A short fixed run that says whether the machine is in the state earlier AC runs measured.

.DESCRIPTION
    Several wrong benchmark figures this project published were the machine, not the
    software: a laptop on battery (about a third of the speed), and an intermittent half-speed
    state nobody explained. The conditions check catches battery. The canary catches the rest
    by measuring something that should not change and comparing it with what it gave before.

    It runs the pinned stock llama.cpp (Scripts/bench-control.json) on a small model, CPU
    and GPU, a fixed prompt and generation length, two interleaved rounds: about half a
    minute. That is the control build, so a GenieX or Foundry update cannot move it; only the
    machine can. The result is compared with the median of the last five earlier canary runs
    that were measured on AC power and were healthy themselves (see BenchCanary.psm1).

        ok            at or above 85 % of the reference
        warn          below 85 %: the run goes on, and the figures need a caveat
        abort         below 60 %: do not benchmark now
        no-reference  fewer than three earlier AC canary runs: recorded, nothing gated

    CPU decode is shown but does not count: it moved about 20 % between healthy runs, where GPU
    decode moved about 2 %. GPU prefill, GPU decode and CPU prefill decide the verdict.

    The thresholds are provisional; there was no AC data to set them from (BenchCanary.psm1
    says what they were chosen from). Every run is recorded as kind canary, with its verdict,
    and a run that warned or aborted is never used as a reference.

    Exit code: 0 ok or no-reference, 10 warn, 11 abort, 4 the pinned build is not unpacked
    (see Invoke-BenchControl.ps1 -Download), 1 anything else.

.PARAMETER WarnBelow
    Ratio below which the verdict is warn. Default 0.85.

.PARAMETER AbortBelow
    Ratio below which the verdict is abort. Default 0.60.

.PARAMETER LlamaBenchPath
    Use an existing extracted llama-bench.exe instead of the pinned build.

.PARAMETER NoRecord
    Print the verdict without appending to the history.

.EXAMPLE
    .\Scripts\Invoke-BenchCanary.ps1
#>
#requires -Version 7
[CmdletBinding()]
param(
    [double]$WarnBelow = 0.85,
    [double]$AbortBelow = 0.60,
    [int]$MinReference = 3,
    [string]$LlamaBenchPath,
    [switch]$NoRecord,
    # Run on battery anyway; the result is recorded as onAcPower = false and is never a reference
    [switch]$AllowBattery
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BenchConditions.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BenchCanary.psm1') -Force

# The fixed cell. Changing any of these starts a new reference, so change them on purpose.
$model = 'unsloth/Qwen3-0.6B-GGUF'
$prompt = 256; $gen = 32; $rounds = 2

$controlArgs = @{
    Model = $model; Config = @('cpu', 'gpu'); PromptTokens = $prompt; GenTokens = $gen; Rounds = $rounds
    NoRecord = $true; PassThru = $true; AllowBattery = $AllowBattery.IsPresent
}
if ($LlamaBenchPath) { $controlArgs.LlamaBenchPath = $LlamaBenchPath }

Write-Host 'Canary: stock llama.cpp, small model, fixed run' -ForegroundColor Cyan
$global:LASTEXITCODE = 0
$run = & (Join-Path $PSScriptRoot 'Invoke-BenchControl.ps1') @controlArgs | Where-Object { $_ -is [pscustomobject] -and $_.PSObject.Properties['Results'] } | Select-Object -Last 1
$code = $LASTEXITCODE
if (-not $run) {
    if ($code -eq 4) { Write-Host 'The canary needs the pinned llama.cpp build. Run Invoke-BenchControl.ps1 -Download once.' -ForegroundColor Yellow; exit 4 }
    Write-Host 'The canary run produced no result.' -ForegroundColor Red; exit 1
}

$current = @($run.Results | Group-Object Config | ForEach-Object {
    [pscustomobject]@{
        Config = $_.Name
        Prefill = ($_.Group | Measure-Object Prefill -Average).Average
        Decode = ($_.Group | Measure-Object Decode -Average).Average
    }
})

$history = @(Get-AtlasBenchmarkHistory)
$reference = @(Get-AtlasCanaryReference -Records $history -Model $run.Model -PromptTokens $prompt)
$v = Get-AtlasCanaryVerdict -Current $current -Reference $reference -WarnBelow $WarnBelow -AbortBelow $AbortBelow -MinReference $MinReference

Write-Host ''
$v.Rows | Format-Table -AutoSize -Property Config, Metric,
    @{ n = 'Now'; e = { '{0:N1}' -f $_.Current }; a = 'right' },
    @{ n = 'Reference'; e = { if ($null -ne $_.Reference) { '{0:N1}' -f $_.Reference } else { '-' } }; a = 'right' },
    @{ n = 'Ratio'; e = { if ($null -ne $_.Ratio) { '{0:P0}' -f $_.Ratio } else { '-' } }; a = 'right' },
    @{ n = 'Runs'; e = { $_.Count } }, Level | Out-String | Write-Host

$conditions = Get-AtlasRunConditions
$color = switch ($v.Verdict) { 'ok' { 'Green' } 'no-reference' { 'Yellow' } 'warn' { 'Yellow' } default { 'Red' } }
switch ($v.Verdict) {
    'ok' { Write-Host ("Canary ok: the lowest ratio is {0:P0} of the AC reference." -f $v.Worst.Ratio) -ForegroundColor $color }
    'warn' { Write-Host ("Canary WARN: {0} {1} is {2:P0} of the AC reference (below {3:P0}). Benchmarks run now need a caveat." -f $v.Worst.Config, $v.Worst.Metric, $v.Worst.Ratio, $WarnBelow) -ForegroundColor $color }
    'abort' { Write-Host ("Canary ABORT: {0} {1} is {2:P0} of the AC reference (below {3:P0}). The machine is not in its normal state; do not benchmark now." -f $v.Worst.Config, $v.Worst.Metric, $v.Worst.Ratio, $AbortBelow) -ForegroundColor $color }
    default {
        $have = @($reference | Where-Object { $_.compute -like '*/gpu' }).Count
        Write-Host ("No reference yet: {0} earlier healthy AC canary run(s) of the {1} needed. This run is recorded and nothing is gated on it.{2}" -f $have, $MinReference,
            $(if ($conditions.onAcPower -ne $true) { ' It was not measured on AC power, so it will not count towards the reference.' } else { '' })) -ForegroundColor $color
    }
}

if (-not $NoRecord) {
    foreach ($r in $run.Results) {
        Add-AtlasBenchmarkRecord -State $run.State -Source 'Invoke-BenchCanary.ps1' -Kind canary `
            -Model $run.Model -Compute "llama.cpp-$($run.Tag)/$($r.Config)" `
            -TokPerSec ([math]::Round($r.Decode, 2)) -Tokens $gen -PrefillTps ([math]::Round($r.Prefill, 2)) -PromptTokens $prompt `
            -N $run.Repeat -Order $r.Order -PromptKind 'synthetic (llama-bench -p)' `
            -Harness 'llama-bench' -HarnessVersion "$($run.Tag) ($($r.BuildCommit))" -ModelArtifact $run.ModelArtifact `
            -Extra @{ engine = 'llama.cpp stock'; round = $r.Round; ngl = $r.Ngl; canaryVerdict = $v.Verdict
                      canaryWorstRatio = $(if ($v.Worst) { [math]::Round($v.Worst.Ratio, 3) } else { $null })
                      binarySource = $run.BinarySource; llamaBenchSha256 = $run.LlamaBenchSha256 } | Out-Null
    }
    Write-Host ("Recorded {0} canary measurement(s)." -f @($run.Results).Count) -ForegroundColor DarkGray
}

switch ($v.Verdict) { 'warn' { exit 10 } 'abort' { exit 11 } default { exit 0 } }
