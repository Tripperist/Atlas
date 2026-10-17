<#
.SYNOPSIS
    Mark benchmark history records that are known not to be comparable as valid = false.

.DESCRIPTION
    Records written before history format 2 flagged a bad measurement with a free-text
    `note` (a run that was contended, in a half-speed state, or measured on battery).
    Free text cannot be filtered on. This turns each such record into valid = false
    with the note as validReason, so `Get-AtlasBenchmarkHistory -Valid` leaves it out.

    Marked:
      * a record that has a `note` field (every note written so far flags a problem);
      * a record with onAcPower = false.

    Not touched: a record that already has a `valid` field, and everything else. Only
    the lines that change are rewritten; the rest are kept byte for byte. A backup is
    written beside the history first. Running it again marks nothing.

    From now on, write a reason as validReason with valid = false, not as a note.

.PARAMETER DryRun
    Say what would be marked without writing anything.

.EXAMPLE
    .\Scripts\Mark-AtlasInvalidRecords.ps1 -DryRun

.EXAMPLE
    .\Scripts\Mark-AtlasInvalidRecords.ps1
#>
#requires -Version 7
[CmdletBinding()]
param([switch]$DryRun)

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force

$path = Get-AtlasHistoryPath
if (-not (Test-Path $path)) { Write-Host "no history at $path"; return }

$lines = @(Get-Content $path)
$marked = [System.Collections.Generic.List[string]]::new()
$result = foreach ($line in $lines) {
    if (-not $line.Trim()) { $line; continue }
    try { $r = $line | ConvertFrom-Json } catch { $line; continue }   # keep a truncated line as it is
    $names = $r.PSObject.Properties.Name
    $reason = $null
    if ('valid' -in $names) { $line; continue }
    if ('note' -in $names -and $r.note) { $reason = [string]$r.note }
    elseif ('onAcPower' -in $names -and $r.onAcPower -eq $false) { $reason = 'measured on battery' }
    if (-not $reason) { $line; continue }

    $r | Add-Member -NotePropertyName valid -NotePropertyValue $false -Force
    $r | Add-Member -NotePropertyName validReason -NotePropertyValue $reason -Force
    $marked.Add(('{0}  {1} {2}  {3}' -f ([string]$r.ts).Substring(0, [Math]::Min(16, ([string]$r.ts).Length)), $r.model, $r.compute,
                 $(if ($reason.Length -gt 70) { $reason.Substring(0, 70) + '...' } else { $reason })))
    $r | ConvertTo-Json -Depth 8 -Compress
}

if ($marked.Count -eq 0) { Write-Host 'nothing to mark (already done, or nothing flagged)'; return }
Write-Host ("{0} record(s) {1}:" -f $marked.Count, $(if ($DryRun) { 'would be marked invalid' } else { 'marked invalid' }))
$marked | ForEach-Object { Write-Host "  $_" }

if (-not $DryRun) {
    $backup = "$path.bak-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
    Copy-Item $path $backup
    [System.IO.File]::WriteAllLines($path, [string[]]$result, [System.Text.UTF8Encoding]::new($false))
    Write-Host "backup: $backup"
}
