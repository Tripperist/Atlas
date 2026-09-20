<#
.SYNOPSIS
    Create the native ARM64 Python environment and sync dependencies.

.DESCRIPTION
    Automates README section 4.3. Creates .venv on the pinned Python version,
    syncs dependencies from pyproject.toml, and verifies the result is a
    genuine ARM64 interpreter.

    Optionally sets the model/cache locations from section 4.5 so large
    downloads do not land on the system drive.

.PARAMETER PythonVersion
    Python version for the venv. Defaults to the contents of .python-version.

.PARAMETER CacheRoot
    If supplied, sets GENIEX_DATADIR and HF_HOME beneath this path for the
    current session and prints the lines to persist in your profile.

.PARAMETER Recreate
    Delete an existing .venv first.

.EXAMPLE
    .\Scripts\Initialize-Workspace.ps1

.EXAMPLE
    .\Scripts\Initialize-Workspace.ps1 -CacheRoot D:\atlas -Recreate
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$PythonVersion,
    [string]$CacheRoot,
    [switch]$Recreate
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root

try {
    if (-not (Get-Command uv -ErrorAction SilentlyContinue)) {
        Write-Error 'uv not found. Run .\Scripts\Install-Prerequisites.ps1 -Install first.'
        exit 1
    }

    if (-not $PythonVersion) {
        $pinFile = Join-Path $root '.python-version'
        $PythonVersion = if (Test-Path $pinFile) {
            (Get-Content $pinFile -Raw).Trim()
        }
        else { '3.14' }
    }
    Write-Host "Target Python: $PythonVersion"

    $venv = Join-Path $root '.venv'
    if ($Recreate -and (Test-Path $venv)) {
        if ($PSCmdlet.ShouldProcess($venv, 'Remove existing virtual environment')) {
            Write-Host 'Removing existing .venv...' -ForegroundColor Yellow
            Remove-Item $venv -Recurse -Force
        }
    }

    if (-not (Test-Path $venv)) {
        Write-Host 'Creating virtual environment...' -ForegroundColor Cyan
        uv venv --python $PythonVersion
    }
    else {
        Write-Host '.venv already present (use -Recreate to rebuild).'
    }

    Write-Host 'Syncing dependencies from pyproject.toml...' -ForegroundColor Cyan
    uv sync

    # ---------------------------------------------------------- verification
    $python = Join-Path $venv 'Scripts\python.exe'
    $info = & $python -c "import platform,struct,sys;print(f'{sys.version.split()[0]}|{platform.machine()}|{struct.calcsize(chr(80))*8}')"
    $parts = $info.Trim() -split '\|'

    Write-Host ''
    Write-Host "Python      : $($parts[0])"
    Write-Host "Architecture: $($parts[1])"
    Write-Host "Pointer size: $($parts[2])-bit"

    if ($parts[1] -notmatch 'ARM64|aarch64') {
        Write-Warning "Interpreter reports $($parts[1]), not ARM64."
        Write-Warning 'An emulated interpreter cannot reach the Hexagon NPU.'
    }
    else {
        Write-Host 'Native ARM64 interpreter confirmed.' -ForegroundColor Green
    }

    # --------------------------------------------------------- cache locations
    if ($CacheRoot) {
        $geniexDir = Join-Path $CacheRoot 'geniex'
        $hfDir = Join-Path $CacheRoot 'cache\huggingface'
        New-Item -ItemType Directory -Force -Path $geniexDir, $hfDir | Out-Null

        $env:GENIEX_DATADIR = $geniexDir
        $env:HF_HOME = $hfDir

        Write-Host ''
        Write-Host 'Cache locations set for THIS session only.' -ForegroundColor Yellow
        Write-Host 'Add these to your PowerShell profile to persist them:'
        Write-Host "  `$env:GENIEX_DATADIR = '$geniexDir'"
        Write-Host "  `$env:HF_HOME        = '$hfDir'"
        Write-Host ''
        Write-Host 'Set these BEFORE the first model download, or you will fill C:'
        Write-Host 'and have to move gigabytes later.' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host 'Next steps:' -ForegroundColor Cyan
    Write-Host '  .\Scripts\Test-Environment.ps1      # verify the stack'
    Write-Host '  geniex pull ai-hub-models/Qwen3-4B  # get a model'
    Write-Host '  .\Scripts\Test-ComputeUnits.ps1     # compare CPU/GPU/NPU'
}
finally {
    Pop-Location
}
