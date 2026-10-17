<#
.SYNOPSIS
    Check the rules that decide which benchmark figures are published, and the export script.

.DESCRIPTION
    Over synthetic records: what qualifies (AC, valid, benchmark or control only), what a cell is, how a
    session is cut, that the figure is the median of the latest session, that a cell whose AC records
    disagree is marked unstable, pins, the table text, and replacing a generated block in a document
    (line endings kept, a check that writes nothing, missing markers refused). Then the script itself, against
    a temporary history and copy of the document, and the committed export against the committed tables.
    Exit code is the number of failures.

.EXAMPLE
    .\Scripts\Test-BenchExport.ps1
#>
#requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'BenchCompare.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BenchExport.psm1') -Force
$root = Split-Path $PSScriptRoot -Parent
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if (-not $Ok) { $script:fail++ }
    '  {0}  {1}{2}' -f $(if ($Ok) { 'ok  ' } else { 'FAIL' }), $Name, $(if (-not $Ok -and $Detail) { "   $Detail" } else { '' })
}
$n = 0
$t0 = Get-Date '2026-10-17 09:00:00'
function Rec([double]$Decode, [int]$Minute = 0, $Ac = $true, $Valid = $true, [string]$Kind = 'benchmark', [string]$Model = 'm', [string]$Compute = 'llama_cpp/gpu',
             [Nullable[int]]$Prompt = 512, [string]$Source = 'Invoke-BenchPrefill.ps1', [string]$Stack = 'aaaaaaaaaaaa', $Ctx = $null, $Packages = $null, [Nullable[double]]$Prefill = $null) {
    $script:n++
    $r = [ordered]@{
        id = ('r{0:D3}' -f $script:n); ts = $t0.AddMinutes($Minute).ToString('o'); stateId = $Stack; source = $Source; kind = $Kind; model = $Model
        compute = $Compute; promptTokens = $Prompt; tokPerSec = $Decode; prefillTps = $Prefill; onAcPower = $Ac; valid = $Valid; n = 3
        csv = 'D:\private\path\x.csv'
        state = [pscustomobject]@{ geniex = [pscustomobject]@{ version = 'v0.9.0'; llamacpp = 'e467e5b' }; foundry = '0.10.3'; drivers = [pscustomobject]@{ adreno = '1'; npu = '2' }; os = '28120'; packages = [pscustomobject]@{ onnxruntime_qnn = '2.7.0' } }
        conditions = [pscustomobject]@{ powerScheme = 'Balanced' }
    }
    if ($null -ne $Ctx) { $r.ctxSize = $Ctx }
    if ($Packages) { $r.packages = [pscustomobject]$Packages }
    [pscustomobject]$r
}
function Cell($cells, [string]$Model = 'm') { @($cells) | Where-Object { $_.model -eq $Model } | Select-Object -First 1 }

Write-Host 'What qualifies' -ForegroundColor Cyan
$all = @(
    (Rec 10), (Rec 11 -Ac $false -Model 'battery'), (Rec 12 -Ac $null -Model 'unknown'), (Rec 13 -Valid $false -Model 'invalid'),
    (Rec 14 -Kind smoke -Model 'smoke'), (Rec 15 -Kind canary -Model 'canary'), (Rec 16 -Kind control -Model 'ctl')
)
$cells = @(Get-AtlasPublishedCells -Records $all -CurrentStack 'aaaaaaaaaaaa')
Check 'only AC, valid benchmarks and controls: the others are not published' ((($cells.model | Sort-Object) -join ',') -eq 'ctl,m') (($cells.model | Sort-Object) -join ',')
Check 'a record with no figure at all does not qualify' (-not (Test-AtlasPublishable ([pscustomobject]@{ kind = 'benchmark'; valid = $true; onAcPower = $true; tokPerSec = $null; prefillTps = $null; firstTokenS = $null })))
Check 'an empty history publishes nothing, and says so' ((@(Get-AtlasPublishedCells -Records @()).Count -eq 0) -and ((Format-AtlasResultTables -Export (New-AtlasExport -Cells @())) -match 'No figure qualifies'))

Write-Host ''
Write-Host 'What a cell is' -ForegroundColor Cyan
$cells = @(Get-AtlasPublishedCells -Records @((Rec 10 -Ctx 8192), (Rec 20 -Ctx 4096)))
Check 'different context sizes are different cells' ($cells.Count -eq 2)
$cells = @(Get-AtlasPublishedCells -Records @((Rec 10 -Packages @{ 'onnxruntime_providers_qnn.dll' = '2.6.0' }), (Rec 20 -Packages @{ 'onnxruntime_providers_qnn.dll' = '2.7.0' })))
Check 'the QNN package a run carries makes a different cell, and the table says which' (($cells.Count -eq 2) -and ((Format-AtlasResultTables -Export (New-AtlasExport -Cells $cells)) -match 'QNN 2\.7\.0'))
$cells = @(Get-AtlasPublishedCells -Records @((Rec 10 -Source 'Invoke-PrefillBench.ps1'), (Rec 12 -Minute 5 -Source 'Invoke-BenchPrefill.ps1')))
Check 'a former script name and its current one are the same cell' ($cells.Count -eq 1)

Write-Host ''
Write-Host 'Sessions, and the figure' -ForegroundColor Cyan
$recs = @((Rec 10 -Minute 0), (Rec 12 -Minute 10), (Rec 14 -Minute 20), (Rec 99 -Minute 200), (Rec 50 -Minute 210))
$sess = @(Split-AtlasSessions -Records $recs)
Check 'a gap of more than 30 minutes starts a new session' (($sess.Count -eq 2) -and ($sess[0].Records.Count -eq 3) -and ($sess[1].Records.Count -eq 2))
$sess = @(Split-AtlasSessions -Records @((Rec 10 -Minute 0), (Rec 10 -Minute 5 -Stack 'bbbbbbbbbbbb')))
Check 'a change of stack starts a new session even inside the gap' ($sess.Count -eq 2)
$sess = @(Split-AtlasSessions -Records @((Rec 10 -Minute 0)))
Check 'one record is one session' (($sess.Count -eq 1) -and ($sess[0].Records.Count -eq 1))
$c = Cell @(Get-AtlasPublishedCells -Records $recs)
Check 'the figure is the median of the latest session only' (($c.decodeTps -eq 74.5) -and ($c.sessionRecords -eq 2) -and ($c.acRecords -eq 5) -and ($c.acSessions -eq 2)) "$($c.decodeTps) $($c.sessionRecords)"
$c = Cell @(Get-AtlasPublishedCells -Records @((Rec 10 -Minute 0), (Rec 20 -Minute 5), (Rec 30 -Minute 10)))
Check 'an odd session gives its middle value' ($c.decodeTps -eq 20)
Check 'n adds up over the session' ($c.n -eq 9)
$c = Cell @(Get-AtlasPublishedCells -Records @((Rec 10 -Minute 0 -Prefill 1000), (Rec 20 -Minute 5 -Prefill 2000), (Rec 30 -Minute 10 -Prefill 3000)))
Check 'each metric has its own median' (($c.prefillTps -eq 2000) -and ($c.decodeTps -eq 20))

Write-Host ''
Write-Host 'Unstable cells' -ForegroundColor Cyan
$c = Cell @(Get-AtlasPublishedCells -Records @((Rec 8 -Minute 0), (Rec 18 -Minute 300), (Rec 19 -Minute 305), (Rec 18.5 -Minute 310)))
Check 'a slow AC session earlier makes the cell unstable even when the latest is healthy' (($c.unstable) -and ($c.decodeTps -eq 18.5) -and ($c.acRange[0] -eq 8) -and ($c.acRange[1] -eq 19)) "$($c.unstable) $($c.decodeTps)"
$c = Cell @(Get-AtlasPublishedCells -Records @((Rec 18 -Minute 0), (Rec 19 -Minute 300), (Rec 18.5 -Minute 600)))
Check 'a cell whose AC records agree is not' (-not $c.unstable)
$c = Cell @(Get-AtlasPublishedCells -Records @((Rec 18 -Minute 0)))
Check 'a single record has no range and is not unstable' ((-not $c.unstable) -and ($null -eq $c.acRange))
Check 'the table marks an unstable cell and explains the mark' ((Format-AtlasResultTables -Export (New-AtlasExport -Cells @(Get-AtlasPublishedCells -Records @((Rec 8 -Minute 0), (Rec 18 -Minute 300))))) -match [string][char]0x2020)

Write-Host ''
Write-Host 'Pins, current stack, privacy' -ForegroundColor Cyan
$recs = @((Rec 10 -Minute 0), (Rec 99 -Minute 300))
$key = (@(Get-AtlasPublishedCells -Records $recs)[0]).key
$c = Cell @(Get-AtlasPublishedCells -Records $recs -Pins @([pscustomobject]@{ cell = $key; id = $recs[0].id }))
Check 'a pin makes one record stand alone' (($c.decodeTps -eq 10) -and $c.pinned -and ($c.recordIds.Count -eq 1))
$c = Cell @(Get-AtlasPublishedCells -Records $recs -Pins @([pscustomobject]@{ cell = $key; id = 'nope' }))
Check 'a pin naming a record that does not qualify is ignored' ((-not $c.pinned) -and ($c.decodeTps -eq 99))
$c = Cell @(Get-AtlasPublishedCells -Records @((Rec 10 -Stack 'oldoldoldold')) -CurrentStack 'newnewnewnew')
Check 'a cell on an older stack is marked not current, and the table marks it' ((-not $c.current) -and ((Format-AtlasResultTables -Export (New-AtlasExport -Cells @($c))) -match 'oldolda? ?\(v0\.9\.0\) \*|oldoldo \(v0\.9\.0\) \*'))
$json = (New-AtlasExport -Cells @(Get-AtlasPublishedCells -Records @((Rec 10))) | ConvertTo-Json -Depth 8)
Check 'no local path is copied (the record carried one)' (($json -notmatch 'private') -and ($json -notmatch '[A-Z]:\\\\'))
Check 'the export has no timestamp, so an unchanged history gives an unchanged file' ($json -notmatch 'generated')

Write-Host ''
Write-Host 'Replacing a generated block' -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("atlas-export-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    $doc = Join-Path $tmp 'doc.md'
    [System.IO.File]::WriteAllText($doc, "# T`r`n`r`nkeep this`r`n`r`n<!-- BEGIN GENERATED: x (note) -->`r`nold`r`n<!-- END GENERATED: x -->`r`n`r`nand this`r`n", [System.Text.UTF8Encoding]::new($false))
    $changed = Set-AtlasDocBlock -Path $doc -Name x -Content "line one`nline two"
    $text = [System.IO.File]::ReadAllText($doc)
    Check 'the block is replaced, the rest kept, CRLF kept, the marker line kept' ($changed -and $text.Contains("<!-- BEGIN GENERATED: x (note) -->`r`nline one`r`nline two`r`n<!-- END GENERATED: x -->") -and $text.Contains("keep this") -and $text.Contains("and this") -and ($text -notmatch "(?<!`r)`n"))
    Check 'the same content again changes nothing' (-not (Set-AtlasDocBlock -Path $doc -Name x -Content "line one`nline two"))
    $before = [System.IO.File]::ReadAllText($doc)
    $stale = Set-AtlasDocBlock -Path $doc -Name x -Content 'different' -CheckOnly
    Check '-CheckOnly reports a difference and writes nothing' ($stale -and ([System.IO.File]::ReadAllText($doc) -eq $before))
    $threw = $false
    try { $null = Set-AtlasDocBlock -Path $doc -Name nosuch -Content 'x' } catch { $threw = $true }
    Check 'a document without the markers is refused, not appended to' $threw

    Write-Host ''
    Write-Host 'The script, over a temporary history and document' -ForegroundColor Cyan
    $history = Join-Path $tmp 'history.jsonl'
    $out = Join-Path $tmp 'benchmarks.json'
    $pins = Join-Path $tmp 'pins.json'
    '{"pins":[]}' | Set-Content $pins
    $scriptRecs = @((Rec 20 -Minute 0 -Model 'real'), (Rec 22 -Minute 5 -Model 'real'), (Rec 5 -Minute 9 -Model 'battery' -Ac $false))
    foreach ($r in $scriptRecs) { Add-Content $history ($r | ConvertTo-Json -Compress -Depth 6) }
    [System.IO.File]::WriteAllText($doc, "intro`r`n<!-- BEGIN GENERATED: current-figures -->`r`nstale`r`n<!-- END GENERATED: current-figures -->`r`noutro`r`n", [System.Text.UTF8Encoding]::new($false))
    $env:ATLAS_HISTORY_PATH = $history
    $exp = Join-Path $PSScriptRoot 'Export-BenchResults.ps1'
    $o = (& pwsh -NoProfile -File $exp -OutFile $out -PinFile $pins -Docs $doc 2>&1 | Out-String)
    $j = [System.IO.File]::ReadAllText($out) | ConvertFrom-Json
    Check 'writes the export with the one qualifying cell, and regenerates the table' (($j.cellCount -eq 1) -and ($j.cells[0].model -eq 'real') -and ($j.cells[0].decodeTps -eq 21) -and ([System.IO.File]::ReadAllText($doc) -match '\| real \|')) $o
    $o = (& pwsh -NoProfile -File $exp -OutFile $out -PinFile $pins -Docs $doc 2>&1 | Out-String)
    Check 'a second run changes nothing' (($o -match 'unchanged') -and ($o -match 'up to date')) $o
    $o = (& pwsh -NoProfile -File $exp -OutFile $out -Docs $doc -Check 2>&1 | Out-String); $code = $LASTEXITCODE
    Check '-Check passes when the tables match the export' (($code -eq 0) -and ($o -match 'match')) $o
    $env:ATLAS_HISTORY_PATH = (Join-Path $tmp 'none.jsonl')
    $o = (& pwsh -NoProfile -File $exp -OutFile $out -Docs $doc -Check 2>&1 | Out-String); $code = $LASTEXITCODE
    Check '-Check needs no history' ($code -eq 0)
    [System.IO.File]::WriteAllText($doc, ([System.IO.File]::ReadAllText($doc) -replace '\| real \|', '| hand-edited |'), [System.Text.UTF8Encoding]::new($false))
    $o = (& pwsh -NoProfile -File $exp -OutFile $out -Docs $doc -Check 2>&1 | Out-String); $code = $LASTEXITCODE
    Check '-Check fails when someone edits the generated table by hand' (($code -eq 1) -and ($o -match 'do not match')) $o
    '{"pins":[{"cell":"nosuch","id":"nope"}]}' | Set-Content $pins
    $env:ATLAS_HISTORY_PATH = $history
    $o = (& pwsh -NoProfile -File $exp -OutFile $out -PinFile $pins -Docs $doc 2>&1 | Out-String)
    Check 'a pin that matches nothing is reported' ($o -match 'pin not applied') $o
}
finally {
    Remove-Item Env:ATLAS_HISTORY_PATH -ErrorAction SilentlyContinue
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ''
Write-Host 'The committed files' -ForegroundColor Cyan
$o = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Export-BenchResults.ps1') -Check 2>&1 | Out-String)
Check 'docs/BENCHMARKS.md matches docs/data/benchmarks.json' ($LASTEXITCODE -eq 0) $o
$real = [System.IO.File]::ReadAllText((Join-Path $root 'docs/data/benchmarks.json'))
Check 'the committed export carries no local path' (($real -notmatch '[A-Za-z]:\\\\') -and ($real -notmatch '\\\\Users\\\\'))
Check 'every committed cell is AC-measured and has a stack and a date' ((($real | ConvertFrom-Json).cells | Where-Object { -not $_.stack.id -or -not $_.date }).Count -eq 0)

Write-Host ''
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red } else { Write-Host 'all checks passed' -ForegroundColor Green }
exit $fail
