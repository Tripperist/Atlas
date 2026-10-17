<#
.SYNOPSIS
    Check the benchmark conditions policy, then show the conditions right now.

.DESCRIPTION
    Part 1 runs the policy (Test-AtlasConditions) over synthetic conditions, so it
    gives the same answer whether or not the laptop is plugged in. It covers the
    cases that produced wrong numbers: battery, a competing process that may hold
    the NPU, a model left loaded in the Foundry daemon, a busy CPU.

    Part 2 captures the real conditions and checks the fields are there.

    Exit code is the number of failures.

.EXAMPLE
    .\Scripts\Test-AtlasConditions.ps1
#>
#requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AtlasConditions.psm1') -Force

function New-Conditions {
    param(
        $OnAc = $true, $Percent = 98, $Scheme = 'Balanced', $Busy = 4.0,
        $Competing = @(), $Hogs = @(), $FoundryRunning = $false, $Loaded = @()
    )
    [pscustomobject]@{
        capturedAt = 'synthetic'; onAcPower = $OnAc; batteryPercent = $Percent; batteryStatus = 2
        powerScheme = $Scheme; cpuBusyPercent = $Busy; competing = @($Competing)
        backgroundConsumers = @($Hogs)
        foundry = [pscustomobject]@{ running = $FoundryRunning; loadedModels = @($Loaded) }
        overrides = @()
    }
}
function Proc([string]$Name, [string]$Cmd = $null) {
    [pscustomobject]@{ name = $Name; pids = @(1234); commandLine = $Cmd }
}
function Model([string]$Alias, [string]$Device) {
    [pscustomobject]@{ alias = $Alias; size = '442 MB'; device = $Device }
}

# name, conditions, parameters, expected Ok, text that must appear among blockers/warnings
$cases = @(
    @('AC, nothing else running',              (New-Conditions), @{ Needs = 'npu' }, $true, $null),
    @('battery is refused',                    (New-Conditions -OnAc $false), @{ Needs = 'npu' }, $false, 'on battery'),
    @('battery, even for a CPU-only run',      (New-Conditions -OnAc $false), @{ Needs = 'cpu' }, $false, 'on battery'),
    @('battery with -AllowBattery runs, warned', (New-Conditions -OnAc $false), @{ Needs = 'npu'; AllowBattery = $true }, $true, 'onAcPower = false'),
    @('power state unknown warns, runs',       (New-Conditions -OnAc $null), @{ Needs = 'npu' }, $true, 'could not tell'),
    @('geniex running blocks an NPU run',      (New-Conditions -Competing (Proc 'geniex' 'geniex serve --compute cpu')), @{ Needs = 'npu' }, $false, 'may hold the NPU'),
    @('geniex running only warns off the NPU', (New-Conditions -Competing (Proc 'geniex')), @{ Needs = 'cpu' }, $true, 'competes for the CPU'),
    @('an expected process is not flagged',    (New-Conditions -Competing (Proc 'geniex')), @{ Needs = 'npu'; Expect = 'geniex' }, $true, $null),
    @('Foundry model on the NPU blocks',       (New-Conditions -FoundryRunning $true -Loaded (Model 'phi-3.5-mini' 'NPU')), @{ Needs = 'npu' }, $false, 'loaded on the NPU'),
    @('Foundry model on the GPU does not',     (New-Conditions -FoundryRunning $true -Loaded (Model 'qwen3-4b' 'GPU')), @{ Needs = 'npu' }, $true, 'loaded on the GPU'),
    @('Foundry expected: not flagged',         (New-Conditions -FoundryRunning $true -Loaded (Model 'phi-3.5-mini' 'NPU')), @{ Needs = 'npu'; Expect = 'foundry' }, $true, $null),
    @('idle daemon with nothing loaded is fine', (New-Conditions -FoundryRunning $true), @{ Needs = 'npu' }, $true, $null),
    @('busy CPU warns',                        (New-Conditions -Busy 40), @{ Needs = 'npu' }, $true, '40 % busy'),
    @('a background hog warns',                (New-Conditions -Hogs ([pscustomobject]@{ name = 'CrossDeviceService'; cores = 0.96 })), @{ Needs = 'npu' }, $true, 'CrossDeviceService')
)

$fail = 0
Write-Host 'Policy, over synthetic conditions' -ForegroundColor Cyan
foreach ($c in $cases) {
    $name, $cond, $params, $wantOk, $wantText = $c
    $r = Test-AtlasConditions -Conditions $cond @params
    $text = (@($r.Blockers) + @($r.Warnings)) -join ' | '
    $ok = ($r.Ok -eq $wantOk) -and ((-not $wantText) -or ($text -like "*$wantText*"))
    if (-not $ok) { $fail++ }
    '  {0}  {1}' -f $(if ($ok) { 'ok  ' } else { 'FAIL' }), $name
    if (-not $ok) { '        got Ok={0}; "{1}"; wanted Ok={2}, containing "{3}"' -f $r.Ok, $text, $wantOk, $wantText }
}

Write-Host ''
Write-Host 'Live capture' -ForegroundColor Cyan
$sw = [System.Diagnostics.Stopwatch]::StartNew()
$live = Get-AtlasConditions -Seconds 3
$sw.Stop()
$expected = 'capturedAt', 'onAcPower', 'batteryPercent', 'powerScheme', 'cpuBusyPercent', 'competing', 'backgroundConsumers', 'foundry', 'overrides'
$missing = @($expected | Where-Object { $_ -notin $live.PSObject.Properties.Name })
$liveOk = ($missing.Count -eq 0) -and ($sw.Elapsed.TotalSeconds -lt 15) -and ($null -ne $live.foundry.running)
if (-not $liveOk) { $fail++ }
'  {0}  captured in {1:N1} s, fields present: {2}' -f $(if ($liveOk) { 'ok  ' } else { 'FAIL' }), $sw.Elapsed.TotalSeconds, ($missing.Count -eq 0)
'        ' + (Get-AtlasConditionsSummary -Conditions $live)
$verdict = Test-AtlasConditions -Conditions $live -Needs 'npu'
'        right now a run that needs the NPU would be: ' + $(if ($verdict.Ok) { 'allowed' } else { 'REFUSED' })
foreach ($b in $verdict.Blockers) { '          refusing: ' + $b }
foreach ($w in $verdict.Warnings) { '          warning: ' + $w }

Write-Host ''
Write-Host 'Assert-AtlasConditions, with the battery test hook (deterministic whether or not you are plugged in)' -ForegroundColor Cyan
$env:ATLAS_TEST_ON_BATTERY = '1'
try {
    $threw = $false
    try { $null = Assert-AtlasConditions -Needs @() 6>$null } catch { $threw = $true }
    if (-not $threw) { $fail++ }
    '  {0}  refuses on battery by throwing' -f $(if ($threw) { 'ok  ' } else { 'FAIL' })

    $c = Assert-AtlasConditions -Needs @() -AllowBattery 6>$null
    $ok = ($c.onAcPower -eq $false) -and ($c.overrides -contains 'allowBattery')
    if (-not $ok) { $fail++ }
    '  {0}  -AllowBattery returns the conditions and marks the override' -f $(if ($ok) { 'ok  ' } else { 'FAIL' })

    $c = Assert-AtlasConditions -Needs @() -WarnOnly 6>$null
    $ok = ($c.overrides -contains 'warnOnly')
    if (-not $ok) { $fail++ }
    '  {0}  -WarnOnly reports but never refuses, and marks it' -f $(if ($ok) { 'ok  ' } else { 'FAIL' })
}
finally { Remove-Item Env:ATLAS_TEST_ON_BATTERY -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red } else { Write-Host "all checks passed" -ForegroundColor Green }
exit $fail
