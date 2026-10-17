<#
.SYNOPSIS
    Lint the PowerShell scripts with PSScriptAnalyzer.

.DESCRIPTION
    Runs PSScriptAnalyzer over Scripts/ with PSScriptAnalyzerSettings.psd1 at the repository
    root (errors and warnings, with each excluded rule explained there) and prints every
    finding. A linter does not replace running the scripts or the Test-Bench* checks: it
    caught a dead variable here, and would not have caught a variable that silently shadowed
    a parameter. It is cheap, so run it before committing a script.

    Exit code is the number of findings.

    PSScriptAnalyzer is not part of PowerShell. Install it once with:
        Install-Module PSScriptAnalyzer -Scope CurrentUser

.PARAMETER Path
    What to lint. Default: the Scripts folder.

.EXAMPLE
    .\Scripts\Test-BenchLint.ps1
#>
#requires -Version 7
[CmdletBinding()]
param([string]$Path)

$root = Split-Path $PSScriptRoot -Parent
if (-not $Path) { $Path = $PSScriptRoot }
if (-not (Get-Module -ListAvailable PSScriptAnalyzer)) {
    Write-Host 'PSScriptAnalyzer is not installed. Run: Install-Module PSScriptAnalyzer -Scope CurrentUser' -ForegroundColor Yellow
    exit 1
}
Import-Module PSScriptAnalyzer

$findings = @(Invoke-ScriptAnalyzer -Path $Path -Recurse -Settings (Join-Path $root 'PSScriptAnalyzerSettings.psd1'))
foreach ($f in $findings) {
    Write-Host ('{0}:{1}  [{2}] {3}' -f (Resolve-Path -Relative $f.ScriptPath), $f.Line, $f.RuleName, ($f.Message -replace '\s+', ' ')) -ForegroundColor Yellow
}
Write-Host ''
if ($findings.Count) { Write-Host "$($findings.Count) finding(s)" -ForegroundColor Red }
else { Write-Host 'no findings' -ForegroundColor Green }
exit $findings.Count
