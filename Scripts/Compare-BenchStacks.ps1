<#
.SYNOPSIS
    Compare what the benchmark history measured on two stacks.

.DESCRIPTION
    After a stack change (a GenieX release, a driver, an onnxruntime package) the question
    is what moved. This answers it from the history: for every cell (model, compute unit,
    prompt length, measuring script) measured on both stacks, the figure on each, the change,
    and whether it is a real change, within the noise, or the same.

    Rules, see BenchCompare.psm1: records measured on battery and records marked invalid are
    never used; AC power is preferred over "not recorded"; the latest record stands for a
    cell. A control (stock llama.cpp) is shown first and apart: if it moved, the machine was
    not in the same state, and everything else has to be read with that in mind.

    Only cells measured on BOTH stacks are compared. A cell on one side has nothing to be
    compared with, and is counted, not listed. The comparison is as good as the history: it
    pairs records, it does not check that two records were taken in comparable conditions
    beyond AC power. The `power` columns say what each side's power state was, and `?` means
    it was never recorded (every record before the conditions check).

.PARAMETER From
    The earlier stack: a short id, or a prefix of one. Default: the most recent stack other
    than -To that has records.

.PARAMETER To
    The later stack. Default: the current stack.

.PARAMETER List
    List the stacks that have records, with the versions that identify each, and exit.

.PARAMETER Threshold
    Relative change, in percent, below which two figures are called the same. Default 10.

.PARAMETER IncludeBattery
    Use records measured on battery too (they are marked in the power columns).

.PARAMETER All
    List the figures that are the same too. By default only controls and changes are listed.

.PARAMETER Markdown
    Print the table as Markdown, for pasting into a document.

.PARAMETER PassThru
    Return the rows as objects.

.EXAMPLE
    .\Scripts\Compare-BenchStacks.ps1 -List

.EXAMPLE
    .\Scripts\Compare-BenchStacks.ps1 -From 44a1e6e -To af42e97
#>
#requires -Version 7
[CmdletBinding()]
param(
    [string]$From,
    [string]$To,
    [switch]$List,
    [double]$Threshold = 10,
    [switch]$IncludeBattery,
    [switch]$Markdown,
    [switch]$All,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BenchCompare.psm1') -Force

$records = @(Get-AtlasBenchmarkHistory)
if (-not $records.Count) { Write-Host 'The history is empty.' -ForegroundColor Yellow; return }
$stacks = @(Get-AtlasStackSummary -Records $records)

if ($List) {
    $stacks | Format-Table -AutoSize -Property Stack, Records, AC, Battery,
        @{ n = 'First'; e = { $_.First.ToString('MM-dd HH:mm') } }, @{ n = 'Last'; e = { $_.Last.ToString('MM-dd HH:mm') } },
        GenieX, LlamaCpp, Foundry, OrtQnn, Adreno | Out-String | Write-Host
    Write-Host 'AC and Battery count records with a recorded power state; the rest are "not recorded".'
    return
}

if (-not $To) { $To = Get-AtlasShortId (Get-AtlasState).id }
if (-not $From) {
    $prev = $stacks | Where-Object { $_.Stack -notlike "$To*" } | Select-Object -Last 1
    if (-not $prev) { Write-Host 'No other stack has records to compare with.' -ForegroundColor Yellow; return }
    $From = $prev.Stack
}
$fromStack = @($stacks | Where-Object { $_.Stack -like "$From*" })
$toStack = @($stacks | Where-Object { $_.Stack -like "$To*" })
if ($fromStack.Count -ne 1) { Write-Host "-From '$From' matches $($fromStack.Count) stacks. See -List." -ForegroundColor Red; exit 1 }
if ($toStack.Count -ne 1) { Write-Host "-To '$To' matches $($toStack.Count) stacks with records. See -List." -ForegroundColor Red; exit 1 }
$From = $fromStack[0].Stack; $To = $toStack[0].Stack

Write-Host "Comparing $From -> $To" -ForegroundColor Cyan
$stateFrom = ($records | Where-Object stateId -EQ $From | Select-Object -Last 1).state
$stateTo = ($records | Where-Object stateId -EQ $To | Select-Object -Last 1).state
$diff = @(Get-AtlasStateDiff -From $stateFrom -To $stateTo)
if ($diff.Count) {
    Write-Host 'What differs between the stacks:'
    $diff | ForEach-Object { Write-Host ("  {0,-28} {1}  ->  {2}" -f $_.Name, $_.From, $_.To) }
}
Write-Host ''

$rows = @(Compare-AtlasStacks -Records $records -From $From -To $To -Threshold $Threshold -IncludeBattery:$IncludeBattery)
$cellsFrom = @($records | Where-Object { $_.stateId -eq $From } | ForEach-Object { Get-AtlasCellKey $_ } | Select-Object -Unique).Count
$cellsTo = @($records | Where-Object { $_.stateId -eq $To } | ForEach-Object { Get-AtlasCellKey $_ } | Select-Object -Unique).Count
$shared = @($rows.Key | Select-Object -Unique).Count

$controls = @($rows | Where-Object Control)
$moved = @($controls | Where-Object { $_.Verdict -in 'better', 'worse' })
if ($controls.Count) {
    if ($moved.Count) {
        Write-Host ("A CONTROL MOVED ({0} of {1} control figures): the machine was not in the same state on both stacks. Read the rest with that in mind." -f $moved.Count, $controls.Count) -ForegroundColor Yellow
    }
    else { Write-Host ("The control held ({0} figure(s) within {1} %): the machine looks to have been in the same state." -f $controls.Count, $Threshold) -ForegroundColor Green }
}
else { Write-Host 'No control figure is shared by the two stacks, so nothing says the machine was in the same state.' -ForegroundColor Yellow }
Write-Host ''

$view = $rows | Where-Object { $All -or $_.Control -or $_.Verdict -ne 'same' } | Sort-Object @{ Expression = { -not $_.Control } }, Model, Compute, Prompt, Metric
if ($Markdown) {
    Write-Host "| Model | Compute | Prompt | Metric | $From | $To | Change | |"
    Write-Host '| --- | --- | --- | --- | --- | --- | --- | --- |'
    foreach ($r in $view) {
        Write-Host ('| {0} | {1} | {2} | {3} | {4:N2} | {5:N2} | {6:+0.0;-0.0} % | {7} |' -f $r.Model, $r.Compute, $r.Prompt, $r.Metric, $r.From, $r.To, $r.ChangePercent, $r.Verdict)
    }
}
else {
    $view | Format-Table -AutoSize -Property @{ n = 'Model'; e = { $_.Model -replace '^.*/', '' } }, Compute, Prompt,
        @{ n = 'Metric'; e = { if ($_.Control) { "$($_.Metric) (control)" } else { $_.Metric } } },
        @{ n = 'From'; e = { '{0:N2}' -f $_.From }; a = 'right' }, @{ n = 'To'; e = { '{0:N2}' -f $_.To }; a = 'right' },
        @{ n = 'Change'; e = { '{0:+0.0;-0.0} %' -f $_.ChangePercent }; a = 'right' }, Verdict,
        @{ n = 'Power'; e = { "$($_.FromPower)>$($_.ToPower)" } },
        @{ n = 'Noise'; e = { if ($null -ne $_.NoisePercent) { '{0:N0} %' -f $_.NoisePercent } else { 'n=1' } }; a = 'right' } |
        Out-String | Write-Host
}

if (-not $All) { Write-Host ("Showing controls and changes; {0} figure(s) that are the same are left out (-All lists them)." -f @($rows | Where-Object { -not $_.Control -and $_.Verdict -eq 'same' }).Count) -ForegroundColor DarkGray }
Write-Host ("{0} cell(s) on both stacks ({1} only on {2}, {3} only on {4}); {5} figure(s) compared." -f `
    $shared, ($cellsFrom - $shared), $From, ($cellsTo - $shared), $To, $rows.Count)
$notable = @($rows | Where-Object { -not $_.Control -and $_.Verdict -in 'better', 'worse' })
Write-Host ("{0} changed by {1} % or more beyond the noise: {2} better, {3} worse." -f $notable.Count, $Threshold,
    @($notable | Where-Object Verdict -EQ 'better').Count, @($notable | Where-Object Verdict -EQ 'worse').Count)
if ($rows | Where-Object { $_.FromPower -eq '?' -or $_.ToPower -eq '?' }) {
    Write-Host 'Power: ? means the power state was not recorded; those figures may have been measured on battery.' -ForegroundColor DarkGray
}
if ($PassThru) { $rows }
