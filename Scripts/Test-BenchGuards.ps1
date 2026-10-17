<#
.SYNOPSIS
    Check that every benchmark harness refuses to run on battery, and records it when
    told to run anyway.

.DESCRIPTION
    Uses ATLAS_TEST_ON_BATTERY, a test hook that makes the conditions check report
    battery on any machine, and a temporary history (ATLAS_HISTORY_PATH), so it gives
    the same answer plugged in or not and never touches the real history.

    Default (fast, no models are loaded):
      * each PowerShell and Python harness exits non-zero with "refusing: on battery"
        and writes no record;
      * a harness launched from Windows PowerShell 5.1 stops with a #requires message
        instead of a parse error.

    With -IncludeRuns (a few minutes, loads small models; the machine must be otherwise idle):
      * each harness is run with -AllowBattery on a tiny workload, and the record it wrote
        has schemaVersion 2, onAcPower = false, the allowBattery override, n and a codeRev.

    Exit code is the number of failures.

.EXAMPLE
    .\Scripts\Test-BenchGuards.ps1

.EXAMPLE
    .\Scripts\Test-BenchGuards.ps1 -IncludeRuns
#>
#requires -Version 7
[CmdletBinding()]
param([switch]$IncludeRuns)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent
$py = Join-Path $root '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) { $py = 'python' }
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ("atlas-guards-" + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.jsonl')
$env:ATLAS_HISTORY_PATH = $tmp
$env:ATLAS_TEST_ON_BATTERY = '1'
$fail = 0

function Check([string]$Name, [bool]$Ok, [string]$Detail = '') {
    if (-not $Ok) { $script:fail++ }
    '  {0}  {1}{2}' -f $(if ($Ok) { 'ok  ' } else { 'FAIL' }), $Name, $(if (-not $Ok -and $Detail) { "`n        $Detail" } else { '' })
}
function Invoke-Tool([string]$Exe, [string[]]$Arguments) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $out = (& $Exe @Arguments 2>&1 | Out-String) -replace '\x1b\[[0-9;]*[a-zA-Z]', ''
    [pscustomobject]@{ Output = $out; Exit = $LASTEXITCODE; Seconds = $sw.Elapsed.TotalSeconds }
}
function Tail([string]$Text, [int]$N) { (($Text.Trim() -split "`r?`n" | Select-Object -Last $N) -join ' | ') }
function LastRecord { if (Test-Path $tmp) { Get-Content $tmp | Select-Object -Last 1 | ConvertFrom-Json } }

try {
    $ort = 'models/Phi-4-mini-reasoning-onnx/npu/qnn-int4'
    $guards = @(
        @('Invoke-BenchDecode.ps1',     'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchDecode.ps1", '-Model', 'unsloth/Qwen3-0.6B-GGUF:Q4_0', '-Compute', 'cpu')),
        @('Invoke-BenchPrefill.ps1',  'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchPrefill.ps1", '-Device', 'cpu')),
        @('Invoke-BenchFoundry.ps1',  'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchFoundry.ps1", '-Model', 'qwen2.5-0.5b')),
        @('Invoke-BenchFoundryContext.ps1', 'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchFoundryContext.ps1", '-Model', 'qwen2.5-0.5b', '-PromptTokens', '256')),
        @('  ... -InProcess',         'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchFoundryContext.ps1", '-Model', 'qwen2.5-0.5b', '-PromptTokens', '256', '-InProcess')),
        @('Invoke-BenchControl.ps1', 'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchControl.ps1", '-Model', 'unsloth/Qwen3-0.6B-GGUF')),
        @('Invoke-BenchOrtGenAi.ps1', 'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchOrtGenAi.ps1")),
        @('Invoke-BenchToolCalling.ps1',     'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchToolCalling.ps1")),
        @('Invoke-BenchPlacement.ps1',    'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchPlacement.ps1", '-Model', 'x', '-Compute', 'cpu')),
        @('bench_foundry_sdk.py',     $py,    @("$root\src\setup\bench_foundry_sdk.py", '--model', 'qwen2.5-0.5b')),
        @('bench_ort_genai.py',       $py,    @("$root\src\setup\bench_ort_genai.py", '--model-dir', "$root\$ort"))
    )

    Write-Host 'On battery, every harness refuses before loading anything' -ForegroundColor Cyan
    foreach ($g in $guards) {
        $r = Invoke-Tool $g[1] $g[2]
        $ok = ($r.Exit -ne 0) -and ($r.Output -match 'refusing: on battery') -and ($r.Seconds -lt 45) -and (-not (Test-Path $tmp))
        Check ("{0,-24} refuses in {1,4:N1} s, exit {2}, no record" -f $g[0], $r.Seconds, $r.Exit) $ok (Tail $r.Output 3)
    }

    Write-Host ''
    Write-Host 'Windows PowerShell 5.1 stops with a clear message' -ForegroundColor Cyan
    $r = Invoke-Tool 'powershell' @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchDecode.ps1", '-Model', 'x')
    Check 'Invoke-BenchDecode.ps1 under 5.1 mentions #requires' ($r.Output -match 'requires') ($r.Output.Trim().Substring(0, [Math]::Min(200, $r.Output.Trim().Length)))
    Check 'and ran nothing' (-not (Test-Path $tmp))

    if ($IncludeRuns) {
        Write-Host ''
        Write-Host 'With -AllowBattery, tiny runs record the override' -ForegroundColor Cyan
        $runs = @(
            @('Invoke-BenchDecode.ps1',    'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchDecode.ps1", '-Model', 'unsloth/Qwen3-0.6B-GGUF:Q4_0', '-Compute', 'cpu', '-Repeat', '1', '-MaxTokens', '16', '-NoUtilization', '-AllowBattery')),
            @('Invoke-BenchPrefill.ps1', 'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchPrefill.ps1", '-Model', 'unsloth/Qwen3-0.6B-GGUF:Q4_0', '-Device', 'cpu', '-PromptTokens', '128', '-GenTokens', '16', '-Repeat', '1', '-AllowBattery')),
            @('Invoke-BenchFoundryContext.ps1', 'pwsh', @('-NoProfile', '-File', "$PSScriptRoot\Invoke-BenchFoundryContext.ps1", '-Model', 'qwen2.5-0.5b', '-PromptTokens', '256', '-MaxTokens', '64', '-Repeat', '1', '-AllowBattery')),
            @('bench_foundry_sdk.py',    $py,    @("$root\src\setup\bench_foundry_sdk.py", '--model', 'qwen2.5-0.5b', '--repeat', '1', '--max-tokens', '16', '--allow-battery')),
            @('bench_ort_genai.py',      $py,    @("$root\src\setup\bench_ort_genai.py", '--model-dir', "$root\$ort", '--repetitions', '1', '--n-gen', '8', '--n-prompt', '64', '--allow-battery'))
        )
        foreach ($g in $runs) {
            if (Test-Path $tmp) { Remove-Item $tmp -Force }
            $r = Invoke-Tool $g[1] $g[2]
            $rec = LastRecord
            $ok = $rec -and ($rec.schemaVersion -eq 2) -and ($rec.onAcPower -eq $false) -and ($rec.conditions.overrides -contains 'allowBattery') -and ($null -ne $rec.n) -and ($rec.PSObject.Properties.Name -contains 'codeRev')
            Check ("{0,-24} ran in {1,5:N1} s and recorded schemaVersion 2, onAcPower=false, override, n={2}" -f $g[0], $r.Seconds, $(if ($rec) { $rec.n } else { '?' })) $ok (Tail $r.Output 4)
        }
    }

    Write-Host ''
    if ($fail) { Write-Host "$fail FAILED" -ForegroundColor Red } else { Write-Host 'all checks passed' -ForegroundColor Green }
    exit $fail
}
finally {
    Remove-Item Env:ATLAS_HISTORY_PATH, Env:ATLAS_TEST_ON_BATTERY -ErrorAction SilentlyContinue
    Remove-Item $tmp -Force -ErrorAction SilentlyContinue
}
