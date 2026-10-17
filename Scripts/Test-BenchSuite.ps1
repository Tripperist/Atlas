<#
.SYNOPSIS
    Check Invoke-AtlasBenchSuite.ps1 against stub steps, without running a benchmark.

.DESCRIPTION
    Builds a temporary suite of stub scripts (one that records a measurement, one that
    fails, one that exits 4 for "prerequisite missing") and checks that the runner:

      * lists suites and shows a dry run without running anything;
      * refuses on battery before creating a run folder or running a step;
      * runs the steps, continues past a failed one, reports exit 4 as skipped, and
        stops at the first failure with -StopOnError;
      * binds array and switch arguments in the step's own process;
      * writes suite.json, steps.json, records.jsonl, logs and summary.md, with the
        records tagged suiteRun;
      * honours -Only and -Skip, and rejects an unknown step id.

    Everything is written under a temporary folder and a temporary history. The committed
    suite manifests are also checked to be well formed and to name scripts that exist.
    Exit code is the number of failures.

.EXAMPLE
    .\Scripts\Test-BenchSuite.ps1
#>
#requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$runner = Join-Path $PSScriptRoot 'Invoke-AtlasBenchSuite.ps1'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("atlas-suite-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
$suites = Join-Path $tmp 'suites'; $runs = Join-Path $tmp 'runs'
New-Item -ItemType Directory -Force -Path $suites, $runs | Out-Null
$env:ATLAS_HISTORY_PATH = Join-Path $tmp 'history.jsonl'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if (-not $Ok) { $script:fail++ }
    '  {0}  {1}{2}' -f $(if ($Ok) { 'ok  ' } else { 'FAIL' }), $Name, $(if (-not $Ok -and $Detail) { "   $Detail" } else { '' })
}
function Run([string]$ArgText) {
    # `pwsh -Command` reports 0 or 1 from $?, so pass the script's own exit code through
    $out = (& pwsh -NoProfile -Command "& '$runner' $ArgText; if (`$?) { exit 0 } else { exit `$(if (`$LASTEXITCODE) { `$LASTEXITCODE } else { 1 }) }" 2>&1 | Out-String)
    [pscustomobject]@{ Output = $out; Exit = $LASTEXITCODE }
}
function Latest { Get-ChildItem $runs -Directory -ErrorAction SilentlyContinue | Sort-Object Name | Select-Object -Last 1 }
function Steps { Get-Content (Join-Path (Latest).FullName 'steps.json') -Raw | ConvertFrom-Json }

try {
    $mod = Join-Path $PSScriptRoot 'AtlasBaseline.psm1'
    # stubs: ok records a measurement and echoes its arguments; bad fails; gone exits 4
    $okScript = @'
param([string]$Model, [int[]]$Sizes, [switch]$Flag, [switch]$AllowBattery)
Import-Module '@@MODULE@@' -Force
$null = Add-AtlasBenchmarkRecord -State @{ id = ('ab' * 32) } -Source 'stub' -Model $Model -Compute 'cpu' -TokPerSec 12.5 -PromptTokens $Sizes[-1] -N 1
Write-Host "stub ok: model=$Model sizes=$($Sizes -join '+') flag=$Flag battery=$AllowBattery"
'@ -replace '@@MODULE@@', $mod
    Set-Content (Join-Path $tmp 'ok.ps1') $okScript
    Set-Content (Join-Path $tmp 'bad.ps1') 'param([switch]$AllowBattery); Write-Host "stub failing"; exit 1'
    Set-Content (Join-Path $tmp 'gone.ps1') 'param([switch]$AllowBattery); Write-Host "stub prerequisite missing"; exit 4'
    $okPath = (Join-Path $tmp 'ok.ps1') -replace '\\', '/'
    $badPath = (Join-Path $tmp 'bad.ps1') -replace '\\', '/'
    $gonePath = (Join-Path $tmp 'gone.ps1') -replace '\\', '/'
    $manifest = @'
{ "description": "stub suite", "steps": [
  { "id": "first",  "script": "@@OK@@",   "estimateMinutes": 1, "needs": ["cpu"], "args": { "Model": "it's a model", "Sizes": [128, 512], "Flag": true } },
  { "id": "broken", "script": "@@BAD@@",  "estimateMinutes": 1, "needs": ["cpu"], "args": {} },
  { "id": "absent", "script": "@@GONE@@", "estimateMinutes": 1, "needs": ["cpu"], "optional": true, "args": {} },
  { "id": "last",   "script": "@@OK@@",   "estimateMinutes": 1, "needs": ["cpu"], "args": { "Model": "second", "Sizes": [64] } }
] }
'@ -replace '@@OK@@', $okPath -replace '@@BAD@@', $badPath -replace '@@GONE@@', $gonePath
    Set-Content (Join-Path $suites 'stub.json') $manifest

    # a stub canary: exits with $env:STUB_CANARY_EXIT (default 0), and says so
    Set-Content (Join-Path $tmp 'canary.ps1') @'
param([switch]$AllowBattery)
Write-Host "stub canary"
if ($env:STUB_CANARY_EXIT -eq '0' -and $env:STUB_CANARY_NOREF) { Write-Host 'No reference yet: 0 earlier runs' }
exit $(if ($env:STUB_CANARY_EXIT) { [int]$env:STUB_CANARY_EXIT } else { 0 })
'@
    $canaryPath = (Join-Path $tmp 'canary.ps1') -replace '\\', '/'
    $common = "-SuiteDir '$suites' -RunsDir '$runs' -CanaryScript '$canaryPath'"

    Write-Host 'Listing and dry run' -ForegroundColor Cyan
    $r = Run "-List $common"
    Check '-List names the suite and its estimate' (($r.Output -match 'stub') -and ($r.Output -match '4 steps, about 4 min')) $r.Output
    $r = Run "-Suite stub -DryRun $common"
    Check 'a dry run shows the commands and runs nothing' (($r.Output -match "it''s a model") -and ($r.Output -match '-Sizes 128,512') -and ($r.Output -match '-Flag') -and -not (Latest) -and -not (Test-Path $env:ATLAS_HISTORY_PATH)) $r.Output
    $r = Run "-Suite nosuch $common"
    Check 'an unknown suite is refused' (($r.Exit -ne 0) -and ($r.Output -match "No suite 'nosuch'"))
    $r = Run "-Suite stub -Only nosuch $common"
    Check 'an unknown step id is refused' (($r.Exit -ne 0) -and ($r.Output -match "no step 'nosuch'"))

    Write-Host ''
    Write-Host 'On battery' -ForegroundColor Cyan
    $env:ATLAS_TEST_ON_BATTERY = '1'
    try {
        $r = Run "-Suite stub $common"
        Check 'refuses before creating a run folder or running a step' (($r.Exit -ne 0) -and ($r.Output -match 'refusing: on battery') -and -not (Latest) -and ($r.Output -notmatch 'stub ok'))

        Write-Host ''
        Write-Host 'A full run, with -AllowBattery' -ForegroundColor Cyan
        $r = Run "-Suite stub -AllowBattery $common"
        $dir = Latest
        Check 'exit code is the number of failed steps that were not optional' ($r.Exit -eq 1) "exit $($r.Exit)"
        Check 'a failed step did not stop the rest' ($r.Output -match 'model=second sizes=64')
        Check 'array and switch arguments bound, a quote in a string survived' ($r.Output -match "stub ok: model=it's a model sizes=128\+512 flag=True battery=True") $r.Output
        $steps = Steps
        Check 'steps.json: ok, failed, skipped, ok' ((($steps.status) -join ',') -eq 'ok,failed,skipped,ok') (($steps.status) -join ',')
        Check 'exit 4 is skipped, not failed' (($steps | Where-Object id -EQ 'absent').exitCode -eq 4)
        Check 'record counts per step' ((($steps.records) -join ',') -eq '1,0,0,1') (($steps.records) -join ',')
        $recs = @(Get-Content (Join-Path $dir.FullName 'records.jsonl') | ForEach-Object { $_ | ConvertFrom-Json })
        Check 'records.jsonl holds the two records, tagged with the run' (($recs.Count -eq 2) -and (@($recs | Where-Object suiteRun -EQ $dir.Name).Count -eq 2))
        Check 'the records are also in the history' (@(Get-Content $env:ATLAS_HISTORY_PATH).Count -eq 2)
        $meta = Get-Content (Join-Path $dir.FullName 'suite.json') -Raw | ConvertFrom-Json
        Check 'suite.json: run id, battery recorded, manifest copied' (($meta.runId -eq $dir.Name) -and ($meta.onAcPower -eq $false) -and ($meta.manifest.steps.Count -eq 4))
        Check 'a log per step, and one per canary' ((@(Get-ChildItem (Join-Path $dir.FullName 'logs') -Filter '*.log' | Where-Object Name -NotLike 'canary-*').Count -eq 4) -and (Test-Path (Join-Path $dir.FullName 'logs/canary-before.log')) -and (Test-Path (Join-Path $dir.FullName 'logs/canary-after.log')))
        $md = Get-Content (Join-Path $dir.FullName 'summary.md') -Raw
        Check 'summary.md: battery warning, step table, measurement table' (($md -match 'not comparable with AC') -and ($md -match '\| broken \| failed') -and ($md -match "\| it's a model \| cpu \| 512 \|")) $md
        Check 'no suiteRun leaks into the environment' (-not $env:ATLAS_SUITE_RUN)

        Write-Host ''
        Write-Host 'Selecting steps, and stopping' -ForegroundColor Cyan
        Start-Sleep -Seconds 1   # run folders are named to the second
        $r = Run "-Suite stub -AllowBattery -Only first,last $common"
        Check '-Only runs just those steps' ((((Steps).id) -join ',') -eq 'first,last' -and $r.Exit -eq 0)
        Start-Sleep -Seconds 1
        $r = Run "-Suite stub -AllowBattery -Skip first $common"
        Check '-Skip leaves a step out' ((((Steps).id) -join ',') -eq 'broken,absent,last')
        Start-Sleep -Seconds 1
        $r = Run "-Suite stub -AllowBattery -StopOnError $common"
        Check '-StopOnError stops at the failed step' ((((Steps).id) -join ',') -eq 'first,broken')

        Write-Host ''
        Write-Host 'The canary' -ForegroundColor Cyan
        Start-Sleep -Seconds 1
        $r = Run "-Suite stub -AllowBattery -Only first $common"
        $c = Get-Content (Join-Path (Latest).FullName 'canary.json') -Raw | ConvertFrom-Json
        Check 'runs before and after the steps, and the summary says ok' ((($c.when) -join ',') -eq 'before,after' -and (($c.verdict) -join ',') -eq 'ok,ok' -and ((Get-Content (Join-Path (Latest).FullName 'summary.md') -Raw) -match 'Canary: before ok, after ok')) $r.Output
        $env:STUB_CANARY_EXIT = '11'
        try {
            Start-Sleep -Seconds 1
            $r = Run "-Suite stub -AllowBattery -Only first $common"
            $dir = Latest
            Check 'abort: exit 11, no step ran, no second canary, the summary says why' (($r.Exit -eq 11) -and ($r.Output -notmatch 'stub ok') -and ((Get-Content (Join-Path $dir.FullName 'canary.json') -Raw | ConvertFrom-Json).Count -eq 1) -and ((Get-Content (Join-Path $dir.FullName 'summary.md') -Raw) -match 'The suite did not run')) $r.Output
            Start-Sleep -Seconds 1
            $r = Run "-Suite stub -AllowBattery -Only first -IgnoreCanary $common"
            Check '-IgnoreCanary runs the steps anyway, and says the figures are suspect' (($r.Exit -eq 0) -and ($r.Output -match 'stub ok') -and ((Get-Content (Join-Path (Latest).FullName 'summary.md') -Raw) -match 'suspect'))
            $env:STUB_CANARY_EXIT = '10'
            Start-Sleep -Seconds 1
            $r = Run "-Suite stub -AllowBattery -Only first $common"
            Check 'warn: the suite runs, and the summary carries the caveat' (($r.Exit -eq 0) -and ($r.Output -match 'stub ok') -and ((Get-Content (Join-Path (Latest).FullName 'summary.md') -Raw) -match 'caveat'))
            $env:STUB_CANARY_EXIT = '4'
            Start-Sleep -Seconds 1
            $r = Run "-Suite stub -AllowBattery -Only first $common"
            Check 'unavailable (exit 4): the suite runs' (($r.Exit -eq 0) -and ($r.Output -match 'stub ok') -and ((Get-Content (Join-Path (Latest).FullName 'canary.json') -Raw | ConvertFrom-Json)[0].verdict -eq 'unavailable'))
            $env:STUB_CANARY_EXIT = '0'; $env:STUB_CANARY_NOREF = '1'
            Start-Sleep -Seconds 1
            $r = Run "-Suite stub -AllowBattery -Only first $common"
            Check 'no reference is read from the canary''s output' ((Get-Content (Join-Path (Latest).FullName 'canary.json') -Raw | ConvertFrom-Json)[0].verdict -eq 'no-reference')
        }
        finally { Remove-Item Env:STUB_CANARY_EXIT, Env:STUB_CANARY_NOREF -ErrorAction SilentlyContinue }
        Start-Sleep -Seconds 1
        $r = Run "-Suite stub -AllowBattery -Only first -NoCanary $common"
        Check '-NoCanary skips it' (-not (Test-Path (Join-Path (Latest).FullName 'logs/canary-before.log')))
    }
    finally { Remove-Item Env:ATLAS_TEST_ON_BATTERY -ErrorAction SilentlyContinue }

    Write-Host ''
    Write-Host 'The committed suites' -ForegroundColor Cyan
    foreach ($f in Get-ChildItem (Join-Path $PSScriptRoot 'suites') -Filter '*.json') {
        $m = Get-Content $f.FullName -Raw | ConvertFrom-Json
        $ids = @($m.steps.id)
        $missing = @($m.steps | Where-Object { -not (Test-Path (Join-Path $PSScriptRoot $_.script)) })
        $thin = @($m.steps | Where-Object { -not $_.estimateMinutes -or -not $_.needs })
        $ok = $m.description -and $m.steps.Count -and ($ids.Count -eq @($ids | Select-Object -Unique).Count) -and -not $missing.Count -and -not $thin.Count
        Check ("{0,-14} {1} steps, ids unique, scripts exist, estimates and needs given" -f $f.BaseName, @($m.steps).Count) ([bool]$ok) ($missing.script -join ',')
    }
    $r = Run '-List'
    Check 'the committed suites list' (($r.Exit -eq 0) -and ($r.Output -match 'smoke') -and ($r.Output -match 'stack-compare'))
    $r = Run '-Suite stack-compare -DryRun'
    Check 'a dry run of stack-compare prints every step' (($r.Exit -eq 0) -and ($r.Output -match 'prefill-matrix') -and ($r.Output -match 'ort-genai') -and ($r.Output -match '-Matrix'))

    Write-Host ''
    if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red } else { Write-Host 'all checks passed' -ForegroundColor Green }
    exit $fail
}
finally {
    Remove-Item Env:ATLAS_HISTORY_PATH, Env:ATLAS_TEST_ON_BATTERY, Env:ATLAS_SUITE_RUN -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}
