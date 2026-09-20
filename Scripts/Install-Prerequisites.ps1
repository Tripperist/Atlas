<#
.SYNOPSIS
    Report (and optionally install) the native ARM64 toolchain Atlas needs.

.DESCRIPTION
    Automates README section 4.1. Safe by default: with no switches it only
    REPORTS what is present or missing and installs nothing.

    Pass -Install to actually run winget. Each package is installed with
    --architecture arm64; an emulated x64 tool cannot demonstrate native
    inference performance.

    GenieX is deliberately excluded -- it ships as an unsigned installer from
    Qualcomm and is not in winget. See README section 4.2.

.PARAMETER Install
    Actually install missing packages. Without this, the script only reports.

.PARAMETER IncludeDotnet
    Also check/install the .NET SDK (only needed for Scout integration).

.EXAMPLE
    .\Scripts\Install-Prerequisites.ps1

.EXAMPLE
    .\Scripts\Install-Prerequisites.ps1 -Install
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [switch]$Install,
    [switch]$IncludeDotnet
)

$ErrorActionPreference = 'Continue'

$packages = @(
    [pscustomobject]@{ Name = 'Git';    Id = 'Git.Git';           Command = 'git' }
    [pscustomobject]@{ Name = 'Python'; Id = 'Python.Python.3.14'; Command = 'python' }
    [pscustomobject]@{ Name = 'uv';     Id = 'astral-sh.uv';       Command = 'uv' }
    [pscustomobject]@{ Name = 'VS Code'; Id = 'Microsoft.VisualStudioCode'; Command = 'code' }
)

if ($IncludeDotnet) {
    $packages += [pscustomobject]@{ Name = '.NET SDK'; Id = 'Microsoft.DotNet.SDK.9'; Command = 'dotnet' }
}

$arch = "$([System.Runtime.InteropServices.RuntimeInformation]::ProcessArchitecture)"
Write-Host "Shell architecture: $arch"
if ($arch -ne 'Arm64') {
    Write-Warning 'Not an ARM64 shell. Install native ARM64 tools from an ARM64 shell.'
}
Write-Host ''

$status = foreach ($pkg in $packages) {
    $cmd = Get-Command $pkg.Command -ErrorAction SilentlyContinue
    [pscustomobject]@{
        Name      = $pkg.Name
        Installed = [bool]$cmd
        Path      = if ($cmd) { $cmd.Source } else { '' }
        Id        = $pkg.Id
    }
}

$status | Format-Table -AutoSize -Property Name, Installed, Path

$missing = @($status | Where-Object { -not $_.Installed })

if (-not $missing) {
    Write-Host 'All prerequisites present.' -ForegroundColor Green
}
elseif (-not $Install) {
    Write-Host "$($missing.Count) package(s) missing. Re-run with -Install to install:" -ForegroundColor Yellow
    foreach ($m in $missing) {
        Write-Host "  winget install --id $($m.Id) -e --architecture arm64 --accept-package-agreements --accept-source-agreements"
    }
}
else {
    if (-not (Get-Command winget -ErrorAction SilentlyContinue)) {
        Write-Error 'winget not available. Install packages manually - see README section 4.1.'
        exit 1
    }
    foreach ($m in $missing) {
        if ($PSCmdlet.ShouldProcess($m.Name, 'winget install')) {
            Write-Host "Installing $($m.Name)..." -ForegroundColor Cyan
            winget install --id $m.Id -e --architecture arm64 `
                --accept-package-agreements --accept-source-agreements
        }
    }
    Write-Host ''
    Write-Host 'Open a NEW shell so PATH changes take effect, then run:' -ForegroundColor Yellow
    Write-Host '  .\Scripts\Initialize-Workspace.ps1'
}

Write-Host ''
Write-Host 'GenieX is not available via winget. Download the unsigned Windows' -ForegroundColor DarkGray
Write-Host 'ARM64 installer from https://geniex.aihub.qualcomm.com/en/run/cli/install' -ForegroundColor DarkGray
Write-Host 'SmartScreen will warn: More info > Run anyway. See README section 4.2.' -ForegroundColor DarkGray
