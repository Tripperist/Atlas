<#
.SYNOPSIS
    Check that New-BenchPrompt.ps1 builds the same prompt every time.

.DESCRIPTION
    A context-length figure is only reproducible if the prompt behind it is. Checks
    that a rebuild is byte-identical, that the cache returns the same prompt, that the
    size tracks the target, that line endings are LF with no BOM, that -AsciiOnly leaves
    no other characters, and that an impossible size is refused rather than short.
    Exit code is the number of failures.

.EXAMPLE
    .\Scripts\Test-BenchPrompt.ps1
#>
#requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$new = Join-Path $PSScriptRoot 'New-BenchPrompt.ps1'
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if (-not $Ok) { $script:fail++ }
    '  {0}  {1}{2}' -f $(if ($Ok) { 'ok  ' } else { 'FAIL' }), $Name, $(if (-not $Ok -and $Detail) { "   $Detail" } else { '' })
}

Write-Host 'New-BenchPrompt' -ForegroundColor Cyan
$a = & $new -Tokens 2048 -Force
$b = & $new -Tokens 2048 -Force
Check 'a forced rebuild is byte-identical' ($a.Sha256 -eq $b.Sha256)
$c = & $new -Tokens 2048
Check 'the cached prompt is the same prompt' ($c.Sha256 -eq $a.Sha256)
Check 'the file on disk matches the recorded SHA256' ((Get-FileHash $a.Path -Algorithm SHA256).Hash.ToLower() -eq $a.Sha256)

$bytes = [System.IO.File]::ReadAllBytes($a.Path)
Check 'LF line endings, no BOM' (($bytes -notcontains 13) -and -not ($bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB))
$want = 2048 * $a.CharsPerToken
Check 'length is within 2 % of the target' ([math]::Abs($a.Chars - $want) / $want -lt 0.02) "$($a.Chars) chars, wanted about $([int]$want)"
Check 'the instruction is last, so the whole text must be read' ([System.IO.File]::ReadAllText($a.Path).TrimEnd().EndsWith('which parts matter most.'))

$big = & $new -Tokens 16384 -Force
Check 'a larger target gives a longer prompt' ($big.Chars -gt 3 * $a.Chars -and ($big.Files.Count -ge 1))

$ascii = & $new -Tokens 16384 -AsciiOnly -Force
$text = [System.IO.File]::ReadAllText($ascii.Path)
Check '-AsciiOnly leaves only ASCII' (-not [regex]::IsMatch($text, '[^\x00-\x7F]'))
$utf = [System.IO.File]::ReadAllText($big.Path)
Check 'the default prompt does carry non-ASCII, which is the point' ([regex]::IsMatch($utf, '[^\x00-\x7F]'))

Check 'UTF-8 survives the read from git (the em dash is intact, not three code-page characters)' ($utf.Contains([string][char]0x2014) -and -not $utf.Contains([string][char]0x0393))

$threw = $false
try { $null = & $new -Tokens 190000 -Force } catch { $threw = $true }
Check 'a size the corpus cannot reach is refused, not silently short' $threw

Write-Host ''
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red } else { Write-Host 'all checks passed' -ForegroundColor Green }
exit $fail
