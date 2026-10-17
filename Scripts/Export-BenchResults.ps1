<#
.SYNOPSIS
    Publish the benchmark figures: write docs/data/benchmarks.json and regenerate the tables in
    docs/BENCHMARKS.md from it.

.DESCRIPTION
    The history (.atlas-local/benchmarks/history.jsonl) is a local ledger of everything that was
    run. What gets published is a curated view of it, chosen by a stated rule (also written into
    the export, and implemented in BenchExport.psm1):

      * AC-powered, valid benchmark and control records only. Records measured on battery, or with no
        recorded power state (everything before 2026-10-17), do not qualify; smoke and canary runs are
        never published.
      * One record per cell (model, compute unit, prompt length, measuring script, context size, and the
        software variant where one stack can differ, such as the QNN package a C# run was built against):
        the latest, unless docs/data/pins.json pins another.
      * Each published figure carries its stack and its date.

    The export is committed. The tables in docs/BENCHMARKS.md, between the markers
    `<!-- BEGIN GENERATED: current-figures -->` and `<!-- END GENERATED: current-figures -->`, are
    generated from it: do not edit them by hand. Local paths are never copied.

    Run it after a benchmark run, review the diff, and commit. Nothing is ever published without
    that commit.

    -Check does not read the history: it verifies that the committed tables match the committed
    export, so it works on any clone. Exit code 1 if they differ.

.PARAMETER Check
    Verify docs/BENCHMARKS.md against docs/data/benchmarks.json, change nothing.

.PARAMETER NoDocs
    Write the export, leave BENCHMARKS.md alone.

.PARAMETER OutFile
    The export. Default docs/data/benchmarks.json.

.PARAMETER PinFile
    Pins that override "the latest" for a cell. Default docs/data/pins.json.

.PARAMETER Docs
    The document holding the generated block. Default docs/BENCHMARKS.md.

.PARAMETER PassThru
    Return the export object.

.EXAMPLE
    .\Scripts\Export-BenchResults.ps1
    git diff docs/

.EXAMPLE
    .\Scripts\Export-BenchResults.ps1 -Check
#>
#requires -Version 7
[CmdletBinding()]
param(
    [switch]$Check,
    [switch]$NoDocs,
    [string]$OutFile,
    [string]$PinFile,
    [string]$Docs,
    [switch]$PassThru
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (-not $OutFile) { $OutFile = Join-Path $root 'docs/data/benchmarks.json' }
if (-not $PinFile) { $PinFile = Join-Path $root 'docs/data/pins.json' }
if (-not $Docs) { $Docs = Join-Path $root 'docs/BENCHMARKS.md' }
$block = 'current-figures'

Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BenchCompare.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BenchExport.psm1') -Force

if ($Check) {
    if (-not (Test-Path $OutFile)) { Write-Host "No export at $OutFile." -ForegroundColor Red; exit 1 }
    $export = [System.IO.File]::ReadAllText($OutFile) | ConvertFrom-Json
    $stale = Set-AtlasDocBlock -Path $Docs -Name $block -Content (Format-AtlasResultTables -Export $export) -CheckOnly
    if ($stale) {
        Write-Host "The generated tables in $(Resolve-Path -Relative $Docs) do not match $(Resolve-Path -Relative $OutFile). Run Export-BenchResults.ps1." -ForegroundColor Red
        exit 1
    }
    Write-Host ("The generated tables match the export ({0} figures)." -f $export.cellCount) -ForegroundColor Green
    return
}

$records = @(Get-AtlasBenchmarkHistory)
$pins = @()
if (Test-Path $PinFile) { $pins = @(([System.IO.File]::ReadAllText($PinFile) | ConvertFrom-Json).pins) }
$current = Get-AtlasShortId (Get-AtlasState).id

$cells = @(Get-AtlasPublishedCells -Records $records -Pins $pins -CurrentStack $current)
$export = New-AtlasExport -Cells $cells -CurrentStack $current

# Pins that match nothing are a mistake worth saying.
foreach ($p in $pins) {
    if (-not ($cells | Where-Object { $_.key -eq $p.cell -and $_.pinned })) {
        Write-Host "pin not applied: cell '$($p.cell)' / record $($p.id) is not among the qualifying records." -ForegroundColor Yellow
    }
}

$json = (($export | ConvertTo-Json -Depth 8) -replace "`r`n", "`n").TrimEnd() + "`n"
New-Item -ItemType Directory -Force -Path (Split-Path $OutFile) | Out-Null
$old = if (Test-Path $OutFile) { ([System.IO.File]::ReadAllText($OutFile) -replace "`r`n", "`n") } else { $null }
if ($old -ne $json) {
    [System.IO.File]::WriteAllText($OutFile, $json.Replace("`n", "`r`n"), [System.Text.UTF8Encoding]::new($false))
    Write-Host ("wrote {0}: {1} figure(s)" -f (Resolve-Path -Relative $OutFile), $cells.Count) -ForegroundColor Green
}
else { Write-Host ("{0} is unchanged ({1} figure(s))" -f (Resolve-Path -Relative $OutFile), $cells.Count) }

if (-not $NoDocs) {
    $changed = Set-AtlasDocBlock -Path $Docs -Name $block -Content (Format-AtlasResultTables -Export ($json | ConvertFrom-Json))
    Write-Host $(if ($changed) { "regenerated the tables in $(Resolve-Path -Relative $Docs)" } else { "the tables in $(Resolve-Path -Relative $Docs) are up to date" })
}

$olderStack = @($cells | Where-Object { -not $_.current }).Count
Write-Host ("{0} figure(s) from {1} stack(s); {2} on an older stack than the current {3}; {4} pinned." -f $cells.Count,
    @($cells.stack.id | Select-Object -Unique).Count, $olderStack, $current, @($cells | Where-Object pinned).Count) -ForegroundColor DarkGray
if ($PassThru) { $export }
