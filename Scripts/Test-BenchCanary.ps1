<#
.SYNOPSIS
    Check the canary verdict rules, and optionally the canary script against a real build.

.DESCRIPTION
    Part 1 runs the rules over synthetic records: which earlier runs may be the reference
    (canary kind, valid, on AC power, healthy, same cell), the median over the last runs,
    the ok / warn / abort levels at the default and at custom thresholds, and no verdict
    without enough reference.

    Part 2 (-IncludeRuns) runs Invoke-BenchCanary.ps1 for real against a temporary history
    it seeds: with no reference (no-reference, exit 0), with a reference far above this
    machine (abort, exit 11), and far below it (ok, exit 0); then checks what was recorded.
    It needs llama-bench: the pinned build if it is unpacked under .atlas-local/tools, or
    -LlamaBenchPath. It reports battery through the ATLAS_TEST_ON_BATTERY hook and runs with -AllowBattery,
    so the checks mean the same plugged in or not, and the records show battery. Each run is about half a minute.

    Exit code is the number of failures.

.PARAMETER IncludeRuns
    Also run the canary for real.

.PARAMETER LlamaBenchPath
    An extracted llama-bench.exe for -IncludeRuns.

.EXAMPLE
    .\Scripts\Test-BenchCanary.ps1
#>
#requires -Version 7
[CmdletBinding()]
param([switch]$IncludeRuns, [string]$LlamaBenchPath)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BenchCanary.psm1') -Force
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if (-not $Ok) { $script:fail++ }
    '  {0}  {1}{2}' -f $(if ($Ok) { 'ok  ' } else { 'FAIL' }), $Name, $(if (-not $Ok -and $Detail) { "   $Detail" } else { '' })
}
$n = 0
function Ref([double]$Decode, [double]$Prefill, [string]$Cfg = 'gpu', $Ac = $true, $Valid = $true, [string]$Verdict = 'ok', [string]$Model = 'm', [int]$Prompt = 256, [string]$Kind = 'canary') {
    $script:n++
    [pscustomobject]@{
        ts = (Get-Date '2026-10-01').AddMinutes($script:n).ToString('o'); kind = $Kind; model = $Model; compute = "llama.cpp-b1/$Cfg"
        promptTokens = $Prompt; tokPerSec = $Decode; prefillTps = $Prefill; onAcPower = $Ac; valid = $Valid; canaryVerdict = $Verdict
    }
}
function Cur([double]$Decode, [double]$Prefill, [string]$Cfg = 'gpu') { [pscustomobject]@{ Config = $Cfg; Prefill = $Prefill; Decode = $Decode } }

Write-Host 'Which runs may be the reference' -ForegroundColor Cyan
$all = @(
    (Ref 50 1000), (Ref 50 1000 -Ac $false), (Ref 50 1000 -Valid $false), (Ref 50 1000 -Verdict 'warn'), (Ref 50 1000 -Verdict 'abort'),
    (Ref 50 1000 -Model 'other'), (Ref 50 1000 -Prompt 512), (Ref 50 1000 -Kind 'control'), (Ref 50 1000 -Ac $null)
)
$ref = @(Get-AtlasCanaryReference -Records $all -Model 'm' -PromptTokens 256)
Check 'only canary, valid, AC, healthy, same model and prompt' ($ref.Count -eq 1) "$($ref.Count) kept"
Check 'a record from before the verdict existed (no canaryVerdict) is kept' (@(Get-AtlasCanaryReference -Records @((Ref 50 1000 | Select-Object -ExcludeProperty canaryVerdict)) -Model 'm' -PromptTokens 256).Count -eq 1)
Check 'an empty history gives an empty reference' (@(Get-AtlasCanaryReference -Records @() -Model 'm' -PromptTokens 256).Count -eq 0)

Write-Host ''
Write-Host 'Levels' -ForegroundColor Cyan
$refs = 1..5 | ForEach-Object { Ref 50 1000 }
$v = Get-AtlasCanaryVerdict -Current (Cur 50 1000) -Reference $refs
Check 'at the reference is ok' ($v.Verdict -eq 'ok')
$v = Get-AtlasCanaryVerdict -Current (Cur 44 1000) -Reference $refs
Check '88 % is ok' ($v.Verdict -eq 'ok')
$v = Get-AtlasCanaryVerdict -Current (Cur 40 1000) -Reference $refs
Check '80 % is a warn' (($v.Verdict -eq 'warn') -and ($v.Worst.Metric -eq 'decode') -and ([math]::Abs($v.Worst.Ratio - 0.8) -lt 1e-9))
$v = Get-AtlasCanaryVerdict -Current (Cur 50 550) -Reference $refs
Check '55 % in prefill alone is an abort, naming prefill' (($v.Verdict -eq 'abort') -and ($v.Worst.Metric -eq 'prefill'))
$v = Get-AtlasCanaryVerdict -Current (Cur 17 330) -Reference $refs
Check 'the battery case (about a third) is an abort' ($v.Verdict -eq 'abort')
$v = Get-AtlasCanaryVerdict -Current (Cur 40 1000) -Reference $refs -WarnBelow 0.7
Check 'custom thresholds move the line' ($v.Verdict -eq 'ok')
$v = Get-AtlasCanaryVerdict -Current (Cur 40 1000) -Reference $refs -WarnBelow 0.9 -AbortBelow 0.85
Check '... and so does the abort line' ($v.Verdict -eq 'abort')
$v = Get-AtlasCanaryVerdict -Current (Cur 55 1000) -Reference $refs
Check 'faster than the reference is ok' ($v.Verdict -eq 'ok')

Write-Host ''
Write-Host 'The median, and not enough reference' -ForegroundColor Cyan
$spiky = @((Ref 50 1000), (Ref 50 1000), (Ref 10 1000), (Ref 50 1000), (Ref 50 1000))
$v = Get-AtlasCanaryVerdict -Current (Cur 50 1000) -Reference $spiky
Check 'one bad earlier run does not move the reference (median)' ((($v.Rows | Where-Object Metric -EQ 'decode').Reference) -eq 50)
$many = 1..8 | ForEach-Object { Ref ($_ * 10) 1000 }
$v = Get-AtlasCanaryVerdict -Current (Cur 70 1000) -Reference $many -Runs 3
Check 'only the last N runs count' ((($v.Rows | Where-Object Metric -EQ 'decode').Reference) -eq 70) "ref $((($v.Rows | Where-Object Metric -EQ 'decode').Reference))"
$v = Get-AtlasCanaryVerdict -Current (Cur 1 1) -Reference @((Ref 50 1000), (Ref 50 1000))
Check 'two earlier runs are not enough: no-reference, however bad' (($v.Verdict -eq 'no-reference') -and ($v.Rows[0].Level -eq 'no-reference'))
$v = Get-AtlasCanaryVerdict -Current (Cur 1 1) -Reference @()
Check 'no earlier run: no-reference' ($v.Verdict -eq 'no-reference')
$v = Get-AtlasCanaryVerdict -Current @((Cur 50 1000 'gpu'), (Cur 1 1 'cpu')) -Reference ($refs)
Check 'a configuration with no reference does not hide a bad one that has one' ($v.Verdict -eq 'ok') $v.Verdict
$v = Get-AtlasCanaryVerdict -Current @((Cur 10 1000 'gpu'), (Cur 1 1 'cpu')) -Reference ($refs)
Check '... and a bad configuration with a reference still aborts' ($v.Verdict -eq 'abort')

if ($IncludeRuns) {
    Write-Host ''
    Write-Host 'The canary script, against a real llama-bench' -ForegroundColor Cyan
    $bench = $LlamaBenchPath
    if (-not $bench) {
        $root = Split-Path $PSScriptRoot -Parent
        $bench = Get-ChildItem (Join-Path $root '.atlas-local/tools') -Filter 'llama-bench.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    }
    if (-not $bench) { Write-Host '  skipped: no llama-bench (give -LlamaBenchPath, or unpack the pinned build)' -ForegroundColor Yellow }
    else {
        $tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("atlas-canary-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
        $env:ATLAS_HISTORY_PATH = $tmp
        # report battery whatever the charger is doing, so the checks mean the same plugged in or not
        $env:ATLAS_TEST_ON_BATTERY = '1'
        $script = Join-Path $PSScriptRoot 'Invoke-BenchCanary.ps1'
        $model = 'unsloth/Qwen3-0.6B-GGUF:Q4_0'
        function Seed([double]$Decode, [double]$Prefill) {
            if (Test-Path $tmp) { Remove-Item $tmp -Force }
            foreach ($i in 1..3) { foreach ($cfg in 'cpu', 'gpu') {
                $r = [ordered]@{ schemaVersion = 2; ts = (Get-Date).AddMinutes(-$i).ToString('o'); stateId = 'seed'; kind = 'canary'; source = 'seed'; model = $model
                                 compute = "llama.cpp-b10566/$cfg"; tokPerSec = $Decode; prefillTps = $Prefill; promptTokens = 256; onAcPower = $true; valid = $true }
                Add-Content $tmp ($r | ConvertTo-Json -Compress) } }
        }
        function RunCanary { $o = (& pwsh -NoProfile -File $script -LlamaBenchPath $bench -AllowBattery 2>&1 | Out-String); [pscustomobject]@{ Output = $o; Exit = $LASTEXITCODE } }
        function Recorded { @(Get-Content $tmp | ForEach-Object { $_ | ConvertFrom-Json } | Where-Object source -EQ 'Invoke-BenchCanary.ps1') }
        try {
            if (Test-Path $tmp) { Remove-Item $tmp -Force }
            $r = RunCanary
            $rec = Recorded
            Check 'no history: no-reference, exit 0' (($r.Exit -eq 0) -and ($r.Output -match 'No reference yet')) "exit $($r.Exit)"
            Check 'four canary records, kind canary, verdict and battery recorded' (($rec.Count -eq 4) -and ($rec[0].kind -eq 'canary') -and ($rec[0].canaryVerdict -eq 'no-reference') -and ($rec[0].onAcPower -eq $false)) "$($rec.Count)"

            Seed 100000 100000
            $r = RunCanary
            Check 'a reference far above this machine: abort, exit 11' (($r.Exit -eq 11) -and ($r.Output -match 'Canary ABORT')) "exit $($r.Exit)"
            Check 'the aborting run is recorded with its verdict' ((Recorded | Where-Object canaryVerdict -EQ 'abort').Count -eq 4)

            Seed 1 1
            $r = RunCanary
            Check 'a reference far below it: ok, exit 0' (($r.Exit -eq 0) -and ($r.Output -match 'Canary ok')) "exit $($r.Exit)"
            Check 'the records of an ok run on battery are not eligible as a reference' (@(Get-AtlasCanaryReference -Records @(Get-Content $tmp | ForEach-Object { $_ | ConvertFrom-Json }) -Model $model -PromptTokens 256 | Where-Object source -EQ 'Invoke-BenchCanary.ps1').Count -eq 0)
        }
        finally { Remove-Item Env:ATLAS_HISTORY_PATH, Env:ATLAS_TEST_ON_BATTERY -ErrorAction SilentlyContinue; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }
    }
}

Write-Host ''
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red } else { Write-Host 'all checks passed' -ForegroundColor Green }
exit $fail
