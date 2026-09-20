<#
.SYNOPSIS
    Verify the Atlas toolchain and print a pass/fail status table.

.DESCRIPTION
    Automates the README section 2 status table. Read-only: checks that each
    layer is installed and functional. Does NOT prove any model runs on the
    NPU -- use Test-ComputeUnits.ps1 for that.

.PARAMETER SkipNetwork
    Skip checks that contact Qualcomm AI Hub.

.EXAMPLE
    .\Scripts\Test-Environment.ps1

.EXAMPLE
    .\Scripts\Test-Environment.ps1 -SkipNetwork
#>
[CmdletBinding()]
param(
    [switch]$SkipNetwork
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$python = Join-Path $root '.venv\Scripts\python.exe'
$hub = Join-Path $root '.venv\Scripts\qai-hub-models.exe'
$results = [System.Collections.Generic.List[pscustomobject]]::new()

function Add-Result {
    param(
        [string]$Check,
        [bool]$Passed,
        [string]$Detail = ''
    )
    $script:results.Add([pscustomobject]@{
            Status = if ($Passed) { 'PASS' } else { 'FAIL' }
            Check  = $Check
            Detail = $Detail
        })
}

Write-Host 'Atlas environment verification' -ForegroundColor Cyan
Write-Host ''

# ----------------------------------------------------------------- shell
$arch = "$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
Add-Result 'Shell is ARM64' ($arch -eq 'Arm64') $arch

# ------------------------------------------------------------------ venv
if (Test-Path $python) {
    $pyInfo = & $python -c "import platform,sys;print(f'{sys.version.split()[0]} {platform.machine()}')" 2>&1 | Out-String
    $pyInfo = $pyInfo.Trim()
    Add-Result 'Python venv present' $true $pyInfo
    Add-Result 'Python is ARM64' ($pyInfo -match 'ARM64') $pyInfo
}
else {
    Add-Result 'Python venv present' $false 'run Initialize-Workspace.ps1'
    Add-Result 'Python is ARM64' $false 'no venv'
}

# ------------------------------------------------------- ONNX + QNN stack
if (Test-Path $python) {
    $checkScript = Join-Path $root 'src\setup\check_qnn.py'
    if (Test-Path $checkScript) {
        $qnnOut = & $python $checkScript 2>$null | Out-String
        $ortVersion = if ($qnnOut -match 'onnxruntime (\d\S+)') { "onnxruntime $($Matches[1])" } else { '' }
        Add-Result 'QNN execution provider registers' ($LASTEXITCODE -eq 0) $ortVersion
        Add-Result 'onnxruntime-genai sees QNN' ($qnnOut -match 'is_qnn_available\(\) -> True') ''
    }
    else {
        Add-Result 'QNN execution provider registers' $false 'check_qnn.py missing'
    }
}

# ---------------------------------------------------------------- GenieX
$geniex = Get-Command geniex -ErrorAction SilentlyContinue
if ($geniex) {
    $ver = (geniex version 2>&1 | Out-String)
    $chipset = (geniex config get chipset 2>&1 | Out-String).Trim()
    $v = if ($ver -match 'Version:\s*(\S+)') { $Matches[1] } else { 'unknown' }
    Add-Result 'GenieX CLI installed' $true $v
    Add-Result 'GenieX detects chipset' ($chipset -match 'Snapdragon') $chipset

    $cached = (geniex list 2>&1 | Out-String)
    # 'geniex list' draws a box-drawing table, so match the owner/name cell
    # itself rather than an ASCII pipe.
    $hasModel = $cached -match '[\w.-]+/[\w.-]+'
    $modelDetail = if ($hasModel) { 'see: geniex list' } else { 'run: geniex pull ai-hub-models/Qwen3-4B' }
    Add-Result 'At least one model cached' $hasModel $modelDetail
}
else {
    Add-Result 'GenieX CLI installed' $false 'not on PATH - see README 4.2'
    Add-Result 'GenieX detects chipset' $false 'geniex missing'
    Add-Result 'At least one model cached' $false 'geniex missing'
}

# --------------------------------------------------------------- AI Hub
if (Test-Path $hub) {
    Add-Result 'qai-hub-models installed' $true 'native ARM64'
    if (-not $SkipNetwork) {
        $job = Start-Job { & $using:hub devices 2>&1 }
        if (Wait-Job $job -Timeout 90) {
            $devices = Receive-Job $job | Out-String
            Add-Result 'AI Hub reachable' ($devices -match 'Snapdragon') 'devices listed'
            Add-Result 'X2 Elite is a valid target' ($devices -match 'X2 Elite') 'Snapdragon X2 Elite CRD'
        }
        else {
            Stop-Job $job
            Add-Result 'AI Hub reachable' $false 'timed out - check auth/network'
        }
        Remove-Job $job -Force
    }
}
else {
    Add-Result 'qai-hub-models installed' $false 'run Initialize-Workspace.ps1'
}

# ---------------------------------------------------------------- report
$results | Format-Table -AutoSize -Property Status, Check, Detail

$failed = @($results | Where-Object Status -eq 'FAIL').Count
if ($failed -eq 0) {
    Write-Host 'All checks passed.' -ForegroundColor Green
}
else {
    Write-Host "$failed check(s) failed." -ForegroundColor Yellow
}
Write-Host ''
Write-Host 'Note: this verifies the stack loads. It does NOT prove a model runs' -ForegroundColor DarkGray
Write-Host 'on the NPU. Run .\Scripts\Test-ComputeUnits.ps1 for that.' -ForegroundColor DarkGray

exit $failed
