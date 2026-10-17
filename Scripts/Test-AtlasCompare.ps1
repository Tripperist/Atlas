<#
.SYNOPSIS
    Check the stack comparison rules over synthetic records.

.DESCRIPTION
    Covers the rules Compare-AtlasBenchmarks.ps1 depends on: which record stands for a
    cell (never battery, never invalid, AC over "not recorded", latest of a tier), the
    noise among a stack's records, the verdicts (same, better, worse, within noise, noisy),
    lower-is-better for first-token time, controls pairing across recorders, cells present
    on only one stack being left out, and the state diff. Then runs the script itself
    against a temporary history and checks its headline.
    Exit code is the number of failures.

.EXAMPLE
    .\Scripts\Test-AtlasCompare.ps1
#>
#requires -Version 7
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'AtlasCompare.psm1') -Force
$fail = 0
function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if (-not $Ok) { $script:fail++ }
    '  {0}  {1}{2}' -f $(if ($Ok) { 'ok  ' } else { 'FAIL' }), $Name, $(if (-not $Ok -and $Detail) { "   $Detail" } else { '' })
}
$n = 0
function Rec([string]$Stack, [double]$Decode, [Nullable[double]]$Prefill = $null, [Nullable[double]]$First = $null, $Ac = $null, $Valid = $true,
             [string]$Model = 'm', [string]$Compute = 'llama_cpp/gpu', [Nullable[int]]$Prompt = 512, [string]$Source = 'Invoke-PrefillBench.ps1', [string]$Kind = 'benchmark') {
    $script:n++
    [pscustomobject]@{
        ts = (Get-Date '2026-10-01').AddMinutes($script:n).ToString('o'); stateId = $Stack; source = $Source; kind = $Kind
        model = $Model; compute = $Compute; promptTokens = $Prompt; tokPerSec = $Decode; prefillTps = $Prefill; firstTokenS = $First
        onAcPower = $Ac; valid = $Valid
    }
}
function Row($rows, [string]$Metric, [string]$Model = 'm') { $rows | Where-Object { $_.Metric -eq $Metric -and $_.Model -eq $Model } | Select-Object -First 1 }

Write-Host 'Which record stands for a cell' -ForegroundColor Cyan
$recs = @(
    (Rec 'a' 10 -Ac $true), (Rec 'a' 99 -Ac $false), (Rec 'a' 50 -Valid $false), (Rec 'a' 11 -Ac $null)
)
$rep = Select-AtlasRepresentative -Records $recs -Property tokPerSec
Check 'battery and invalid records are never used; AC beats not recorded' (($rep.Value -eq 10) -and ($rep.Power -eq 'AC')) "$($rep.Value) $($rep.Power)"
$rep = Select-AtlasRepresentative -Records @($recs[1], $recs[2]) -Property tokPerSec
Check 'nothing usable gives nothing' ($null -eq $rep)
$rep = Select-AtlasRepresentative -Records @($recs[1]) -Property tokPerSec -IncludeBattery
Check '-IncludeBattery admits a battery record, labelled' (($rep.Value -eq 99) -and ($rep.Power -eq 'battery'))
$rep = Select-AtlasRepresentative -Records @((Rec 'a' 10 -Ac $null), (Rec 'a' 12 -Ac $null)) -Property tokPerSec
Check 'the latest record of a tier stands, and the range is the noise' (($rep.Value -eq 12) -and ([math]::Abs($rep.Noise - 2 / 11) -lt 1e-9) -and ($rep.Count -eq 2)) "$($rep.Value) $($rep.Noise)"
$rep = Select-AtlasRepresentative -Records @((Rec 'a' 10)) -Property tokPerSec
Check 'a single record has no noise estimate' ($null -eq $rep.Noise)

Write-Host ''
Write-Host 'Verdicts' -ForegroundColor Cyan
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 100 1.0 -Ac $true), (Rec 'b' 21 100 1.0 -Ac $true)) -From a -To b
Check 'a 5 % change is the same' ((Row $r 'decode').Verdict -eq 'same')
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -Ac $true), (Rec 'b' 14 -Ac $true)) -From a -To b
Check 'a 30 % fall in decode is worse' (((Row $r 'decode').Verdict -eq 'worse') -and ([math]::Round((Row $r 'decode').ChangePercent) -eq -30))
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -Ac $true), (Rec 'b' 26 -Ac $true)) -From a -To b
Check 'a 30 % rise in decode is better' ((Row $r 'decode').Verdict -eq 'better')
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -First 10 -Ac $true), (Rec 'b' 20 -First 1 -Ac $true)) -From a -To b
Check 'first-token time falling 90 % is better (lower is better)' ((Row $r 'first').Verdict -eq 'better')
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -First 1 -Ac $true), (Rec 'b' 20 -First 2 -Ac $true)) -From a -To b
Check 'first-token time doubling is worse' ((Row $r 'first').Verdict -eq 'worse')
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -Ac $true), (Rec 'a' 22 -Ac $true), (Rec 'a' 18 -Ac $true), (Rec 'b' 20 -Ac $true), (Rec 'b' 21 -Ac $true)) -From a -To b
Check 'a change inside a stack''s own range is within noise, not a change' (((Row $r 'decode').Verdict -eq 'within noise')) "$((Row $r 'decode').Verdict) noise $((Row $r 'decode').NoisePercent)"
$r = Compare-AtlasStacks -Records @((Rec 'a' 5 -Ac $true), (Rec 'a' 50 -Ac $true), (Rec 'b' 20 -Ac $true)) -From a -To b
Check 'records that disagree by half the mean or more make the cell noisy' ((Row $r 'decode').Verdict -eq 'noisy')
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -Ac $true), (Rec 'b' 21 -Ac $true)) -From a -To b -Threshold 3
Check '-Threshold moves the line (5 % is a change at 3)' ((Row $r 'decode').Verdict -eq 'better')

Write-Host ''
Write-Host 'Pairing' -ForegroundColor Cyan
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -Ac $true), (Rec 'b' 20 -Ac $true), (Rec 'a' 5 -Model 'only-a' -Ac $true), (Rec 'b' 5 -Model 'only-b' -Ac $true)) -From a -To b
Check 'a cell on one stack only is not compared' ((@($r | Where-Object Model -In 'only-a', 'only-b').Count -eq 0) -and (@($r).Count -ge 1))
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -Prompt 512 -Ac $true), (Rec 'b' 20 -Prompt 2048 -Ac $true)) -From a -To b
Check 'different prompt lengths are different cells' (@($r).Count -eq 0)
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -Source 'llama-bench (stock llama.cpp b10566)' -Kind control -Ac $null), (Rec 'b' 21 -Source 'Invoke-LlamaCppControl.ps1' -Kind control -Ac $true)) -From a -To b
Check 'a control pairs across recorders, and is marked' ((@($r).Count -ge 1) -and (Row $r 'decode').Control)
$r = Compare-AtlasStacks -Records @((Rec 'abc123' 20 -Ac $true), (Rec 'def456' 20 -Ac $true)) -From abc -To def
Check 'stack ids match by prefix' (@($r).Count -eq 1)
$r = Compare-AtlasStacks -Records @((Rec 'a' 20 -Ac $null), (Rec 'b' 20 -Ac $true)) -From a -To b
Check 'the power state of each side is reported' (((Row $r 'decode').FromPower -eq '?') -and ((Row $r 'decode').ToPower -eq 'AC'))

Write-Host ''
Write-Host 'State diff and summary' -ForegroundColor Cyan
$s1 = '{"geniex":{"version":"v0.8.0","llamacpp":"abc"},"foundry":"0.10.3","packages":{"onnxruntime_qnn":"2.6.0"},"id":"x","recorded":"t1"}' | ConvertFrom-Json
$s2 = '{"geniex":{"version":"v0.9.0","llamacpp":"abc"},"foundry":"0.10.3","packages":{"onnxruntime_qnn":"2.7.0","new":"1"},"id":"y","recorded":"t2"}' | ConvertFrom-Json
$d = @(Get-AtlasStateDiff -From $s1 -To $s2)
Check 'only what differs is listed; id and recorded are ignored' ((($d.Name) -join ',') -eq 'geniex.version,packages.new,packages.onnxruntime_qnn') (($d.Name) -join ',')
Check 'a field on one side only reads (absent)' ((($d | Where-Object Name -EQ 'packages.new').From) -eq '(absent)')
$withState = @((Rec 'a' 1 -Ac $true), (Rec 'a' 2 -Ac $false), (Rec 'b' 3 -Ac $null)) | ForEach-Object { $_ | Add-Member -NotePropertyName state -NotePropertyValue $s1 -PassThru }
$sum = @(Get-AtlasStackSummary -Records $withState)
Check 'summary: a row per stack with record, AC and battery counts' (($sum.Count -eq 2) -and ($sum[0].Records -eq 2) -and ($sum[0].AC -eq 1) -and ($sum[0].Battery -eq 1) -and ($sum[1].AC -eq 0))

Write-Host ''
Write-Host 'The script, over a temporary history' -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("atlas-compare-test-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
$env:ATLAS_HISTORY_PATH = $tmp
try {
    $all = @(
        (Rec 'aaaaaaaaaaaa' 30 -Ac $true -Source 'x' -Kind control -Model 'ctl' -Compute 'c/gpu'),
        (Rec 'bbbbbbbbbbbb' 30.5 -Ac $true -Source 'x' -Kind control -Model 'ctl' -Compute 'c/gpu'),
        (Rec 'aaaaaaaaaaaa' 30 -Ac $true -Model 'real'), (Rec 'bbbbbbbbbbbb' 15 -Ac $true -Model 'real')
    ) | ForEach-Object { $_ | Add-Member -NotePropertyName state -NotePropertyValue $s1 -PassThru }
    $all | ForEach-Object { Add-Content $tmp ($_ | ConvertTo-Json -Compress -Depth 6) }
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Compare-AtlasBenchmarks.ps1') -From aaaa -To bbbb 2>&1 | Out-String)
    Check 'names the stacks, says the control held, lists the real change as worse' (($out -match 'aaaaaaaaaaaa -> bbbbbbbbbbbb') -and ($out -match 'The control held') -and ($out -match 'real .* worse')) $out
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Compare-AtlasBenchmarks.ps1') -List 2>&1 | Out-String)
    Check '-List shows both stacks' (($out -match 'aaaaaaaaaaaa') -and ($out -match 'bbbbbbbbbbbb'))
    Add-Content $tmp (Rec 'cccccccccccc' 5 -Ac $true -Source 'x' -Kind control -Model 'ctl' -Compute 'c/gpu' | Add-Member -NotePropertyName state -NotePropertyValue $s1 -PassThru | ConvertTo-Json -Compress -Depth 6)
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Compare-AtlasBenchmarks.ps1') -From aaaa -To cccc 2>&1 | Out-String)
    Check 'a control that moved is called out' ($out -match 'A CONTROL MOVED') $out
    $out = (& pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Compare-AtlasBenchmarks.ps1') -From zzzz -To bbbb 2>&1 | Out-String)
    Check 'an unknown stack is refused' ($out -match "matches 0 stacks")
}
finally { Remove-Item Env:ATLAS_HISTORY_PATH -ErrorAction SilentlyContinue; Remove-Item $tmp -Force -ErrorAction SilentlyContinue }

Write-Host ''
if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red } else { Write-Host 'all checks passed' -ForegroundColor Green }
exit $fail
