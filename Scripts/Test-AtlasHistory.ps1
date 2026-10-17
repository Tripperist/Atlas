<#
.SYNOPSIS
    Check the benchmark history format: writing, reading older records, filtering.

.DESCRIPTION
    Everything runs against a temporary history (ATLAS_HISTORY_PATH); the real one is
    never touched. Covers:

      * a new record carries schemaVersion, a unique id, kind, the conditions the run
        was checked under, onAcPower and codeRev, and leaves out fields that do not apply;
      * records written before format 2 still read: `n` from `repetitions` or `runs`,
        `kind` inferred, `valid` and `onAcPower` filled;
      * -Valid leaves out invalid records and those measured on battery;
      * the Python writer produces the same shape (src/setup/test_atlas_history.py).

    Exit code is the number of failures.

.EXAMPLE
    .\Scripts\Test-AtlasHistory.ps1
#>
#requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("atlas-history-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
$env:ATLAS_HISTORY_PATH = $tmp

try {
    Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'AtlasConditions.psm1') -Force

    $fail = 0
    function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
        if (-not $Ok) { $script:fail++ }
        '  {0}  {1}{2}' -f $(if ($Ok) { 'ok  ' } else { 'FAIL' }), $Name, $(if (-not $Ok -and $Detail) { "   $Detail" } else { '' })
    }
    function LastRecord { Get-Content $tmp | Select-Object -Last 1 | ConvertFrom-Json }
    $state = @{ id = ('ab' * 32); geniex = @{ version = 'vtest' } }

    Write-Host 'PowerShell Add-AtlasBenchmarkRecord, against a temporary history' -ForegroundColor Cyan

    Set-AtlasRunConditions $null
    $null = Add-AtlasBenchmarkRecord -State $state -Source 't' -Model 'm' -Compute 'npu' -TokPerSec 1.0
    $r = LastRecord
    Check 'schemaVersion 2' ($r.schemaVersion -eq 2)
    Check '12-hex id' ($r.id -match '^[0-9a-f]{12}$') $r.id
    Check 'kind defaults to benchmark' ($r.kind -eq 'benchmark')
    Check 'onAcPower null with no conditions' (($r.PSObject.Properties.Name -contains 'onAcPower') -and $null -eq $r.onAcPower)
    Check 'no conditions object when none was checked' ($r.PSObject.Properties.Name -notcontains 'conditions')
    Check 'codeRev recorded' ($r.PSObject.Properties.Name -contains 'codeRev') "$($r.codeRev)"
    Check 'unused optional fields left out' (-not ($r.PSObject.Properties.Name | Where-Object { $_ -in 'n', 'stdev', 'reps', 'ctxSize', 'seed', 'order' }))

    # what Assert-AtlasConditions does on success
    $cond = [pscustomobject]@{ onAcPower = $false; powerScheme = 'Balanced'; batteryPercent = 95; overrides = @('allowBattery') }
    Set-AtlasRunConditions $cond
    $null = Add-AtlasBenchmarkRecord -State $state -Source 't' -Model 'm' -Compute 'npu' -Kind smoke -N 3 -Stdev 0.5 -Reps 1.0, 2.0, 3.0 -CtxSize 16384 -Seed 42 -Order 'npu>gpu' -Extra @{ repetitions = 3 }
    $r = LastRecord
    Check 'conditions from the run are stamped, onAcPower copied' (($r.conditions.powerScheme -eq 'Balanced') -and ($r.onAcPower -eq $false) -and ($r.conditions.overrides -contains 'allowBattery'))
    Check 'kind, n, stdev, reps, ctxSize, seed, order recorded' (($r.kind -eq 'smoke') -and ($r.n -eq 3) -and ($r.stdev -eq 0.5) -and (@($r.reps).Count -eq 3) -and ($r.ctxSize -eq 16384) -and ($r.seed -eq 42) -and ($r.order -eq 'npu>gpu'))
    Check '-Extra still works' ($r.repetitions -eq 3)

    $null = Add-AtlasBenchmarkRecord -State $state -Source 't' -Model 'm' -Compute 'npu' -Conditions ([pscustomobject]@{ onAcPower = $true; powerScheme = 'High' })
    Check 'an explicit -Conditions wins over the run conditions' ((LastRecord).conditions.powerScheme -eq 'High')

    Set-AtlasRunConditions $null
    1..20 | ForEach-Object { $null = Add-AtlasBenchmarkRecord -State $state -Source 't' -Model 'm' -Compute 'npu' }
    $ids = Get-Content $tmp | ForEach-Object { ($_ | ConvertFrom-Json).id }
    Check 'ids are unique across all records written' (@($ids | Select-Object -Unique).Count -eq @($ids).Count)

    Write-Host ''
    Write-Host 'Get-AtlasBenchmarkHistory, over records written before format 2' -ForegroundColor Cyan
    Remove-Item $tmp -Force
    $legacy = @(
        @{ ts = 'a'; stateId = 's'; source = 'Invoke-Benchmark.ps1'; model = 'm'; compute = 'npu'; repetitions = 3 },
        @{ ts = 'b'; stateId = 's'; source = 'Invoke-Benchmark.ps1'; model = 'm'; compute = 'cpu'; runs = 2 },
        @{ ts = 'c'; stateId = 's'; source = 'Update-Workspace.ps1'; model = 'm'; compute = 'npu' },
        @{ ts = 'd'; stateId = 's'; source = 'llama-bench (stock llama.cpp b10566, control)'; model = 'm'; compute = 'gpu' },
        @{ ts = 'e'; stateId = 's'; source = 'x'; model = 'm'; compute = 'npu'; valid = $false; validReason = 'contended' },
        @{ ts = 'f'; stateId = 's'; source = 'x'; model = 'm'; compute = 'npu'; onAcPower = $false },
        @{ ts = 'g'; stateId = 'other'; source = 'x'; model = 'm'; compute = 'npu' },
        @{ ts = 'h'; stateId = 's'; source = 'llama-bench (stock llama.cpp b10566)'; model = 'm'; compute = 'cpu' }
    )
    $legacy | ForEach-Object { Add-Content -Path $tmp -Value ($_ | ConvertTo-Json -Compress) -Encoding UTF8 }
    $all = @(Get-AtlasBenchmarkHistory)
    Check 'all eight records read' ($all.Count -eq 8)
    Check 'n from repetitions, and from runs' (($all[0].n -eq 3) -and ($all[1].n -eq 2))
    Check 'n is null when neither was recorded' ($null -eq $all[2].n)
    Check 'kind: smoke for Update-Workspace, control for a control or a llama-bench run, benchmark otherwise' (($all[2].kind -eq 'smoke') -and ($all[3].kind -eq 'control') -and ($all[7].kind -eq 'control') -and ($all[0].kind -eq 'benchmark'))
    Check 'valid defaults to true; an explicit false is kept' (($all[0].valid -eq $true) -and ($all[4].valid -eq $false))
    Check 'onAcPower reads null unless recorded' (($null -eq $all[0].onAcPower) -and ($all[5].onAcPower -eq $false))
    $valid = @(Get-AtlasBenchmarkHistory -Valid)
    Check '-Valid leaves out the invalid and the battery record' (($valid.Count -eq 6) -and (-not ($valid | Where-Object { $_.ts -in 'e', 'f' })))
    Check '-Kind smoke' (@(Get-AtlasBenchmarkHistory -Kind smoke).Count -eq 1)
    Check '-StateId still filters' (@(Get-AtlasBenchmarkHistory -StateId other).Count -eq 1)

    Write-Host ''
    Write-Host 'Python writer' -ForegroundColor Cyan
    $py = Join-Path (Split-Path $PSScriptRoot -Parent) '.venv\Scripts\python.exe'
    if (-not (Test-Path $py)) { $py = 'python' }
    & $py (Join-Path (Split-Path $PSScriptRoot -Parent) 'src\setup\test_atlas_history.py')
    if ($LASTEXITCODE -ne 0) { $fail += $LASTEXITCODE }

    Write-Host ''
    if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red } else { Write-Host 'all checks passed' -ForegroundColor Green }
    exit $fail
}
finally {
    Remove-Item Env:ATLAS_HISTORY_PATH -ErrorAction SilentlyContinue
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
