<#
.SYNOPSIS
    Collect the Snapdragon hardware inventory Atlas depends on.

.DESCRIPTION
    Automates README section 1. Read-only: queries CIM/PnP and, when present,
    the GenieX and AI Hub CLIs. Installs and changes nothing.

    Captures the four facts everything downstream depends on:
      1. Exact SoC SKU
      2. NPU and GPU driver versions
      3. The AI Hub device name matching your chip
      4. Whether this shell is genuinely ARM64

.PARAMETER OutFile
    Also write the report to this path (Markdown fenced block).

.EXAMPLE
    .\Scripts\Get-SystemInfo.ps1

.EXAMPLE
    .\Scripts\Get-SystemInfo.ps1 -OutFile inventory.md
#>
[CmdletBinding()]
param(
    [string]$OutFile
)

$ErrorActionPreference = 'Continue'
$lines = [System.Collections.Generic.List[string]]::new()

function Write-Section {
    param([string]$Title)
    $bar = '-' * $Title.Length
    $script:lines.Add('')
    $script:lines.Add($Title)
    $script:lines.Add($bar)
}

function Write-Line {
    param([string]$Text = '')
    $script:lines.Add($Text)
}

function Add-Table {
    param($InputObject)
    if ($null -eq $InputObject) { Write-Line '  (none found)'; return }
    ($InputObject | Format-Table -AutoSize | Out-String -Width 160).TrimEnd() -split "`r?`n" |
        Where-Object { $_.Trim() } | ForEach-Object { Write-Line "  $_" }
}

Write-Line "Atlas hardware inventory - $(Get-Date -Format 'yyyy-MM-dd HH:mm')"

# ---------------------------------------------------------------- 1.1 machine
Write-Section 'Machine, SoC, memory'
Add-Table (Get-CimInstance Win32_ComputerSystem |
    Select-Object Manufacturer, Model, SystemType,
        @{n = 'RAM_GiB'; e = { [math]::Round($_.TotalPhysicalMemory / 1GB, 1) } })

Add-Table (Get-CimInstance Win32_Processor |
    Select-Object Name, NumberOfCores, NumberOfLogicalProcessors, MaxClockSpeed)

Write-Section 'Operating system'
Add-Table (Get-CimInstance Win32_OperatingSystem |
    Select-Object Caption, Version, BuildNumber, OSArchitecture)

Write-Section 'Storage'
Add-Table (Get-Volume | Where-Object DriveLetter |
    Select-Object DriveLetter,
        @{n = 'Size_GiB'; e = { [math]::Round($_.Size / 1GB, 1) } },
        @{n = 'Free_GiB'; e = { [math]::Round($_.SizeRemaining / 1GB, 1) } })

# ------------------------------------------------------- 1.1 accelerators
# The NPU enumerates under class ComputeAccelerator, not Display. Most guides
# miss this, and it is the query that yields the exact SoC SKU.
Write-Section 'Accelerators (NPU + GPU)'
$accelerators = Get-PnpDevice -Class 'Display', 'ComputeAccelerator' -Status OK -ErrorAction SilentlyContinue |
    Select-Object Class, FriendlyName
Add-Table $accelerators

if (-not ($accelerators | Where-Object Class -eq 'ComputeAccelerator')) {
    Write-Line '  WARNING: no ComputeAccelerator device found.'
    Write-Line '  The NPU driver is missing or the device is disabled.'
    Write-Line '  No runtime will reach the Hexagon HTP until that is fixed.'
}

Write-Section 'Accelerator drivers'
Add-Table (Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue |
    Where-Object { $_.DeviceName -match 'Adreno|Hexagon|NPU|Neural' } |
    Select-Object DeviceName, DriverVersion, DriverDate)

Write-Section 'Shell architecture'
$arch = [System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture
Write-Line "  ProcessArchitecture : $arch"
if ("$arch" -ne 'Arm64') {
    Write-Line '  WARNING: not an ARM64 shell. Native NPU paths require ARM64.'
}

# ------------------------------------------------- 1.2 match to a runtime target
Write-Section 'Runtime target match'
if (Get-Command geniex -ErrorAction SilentlyContinue) {
    $chipset = (geniex config get chipset 2>&1 | Out-String).Trim()
    Write-Line "  GenieX detected chipset : $chipset"
    ((geniex version 2>&1 | Out-String).TrimEnd() -split "`r?`n") |
        Where-Object { $_.Trim() } | ForEach-Object { Write-Line "  $_" }
    Write-Line ''
    Write-Line "  Pass this exact string to 'qai-hub-models ... --device'."
}
else {
    Write-Line '  geniex not on PATH - see README section 4.2.'
}

Write-Line ''
$hub = Join-Path $PSScriptRoot '..\.venv\Scripts\qai-hub-models.exe'
if (Test-Path $hub) {
    Write-Line '  AI Hub device catalog: run the following and match your Chipset row.'
    Write-Line '  Note the HTP Version column - assets are compiled against it.'
    Write-Line '    .\.venv\Scripts\qai-hub-models.exe devices'
}
else {
    Write-Line '  qai-hub-models not installed - run .\Scripts\Initialize-Workspace.ps1'
}

$report = $lines -join [Environment]::NewLine
Write-Output $report

if ($OutFile) {
    @('```text', $report, '```') -join [Environment]::NewLine |
        Set-Content -Path $OutFile -Encoding UTF8
    Write-Output ''
    Write-Output "Written to $OutFile"
}
