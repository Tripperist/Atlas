<#
.SYNOPSIS
    Measure prefill and decode separately with geniex-bench, and record the
    results in the Atlas benchmark history.

.DESCRIPTION
    Automates docs/BENCHMARKS.md "Prefill vs decode".

    Invoke-Benchmark.ps1 drives `geniex infer` from a short prompt, where
    prefill is negligible and decode dominates. That understates the NPU
    badly: with a realistic 512-token prompt the NPU leads prefill by 5.8x on
    llama.cpp and 8.7x on QAIRT, while the short-prompt decode figures show it
    only marginally ahead. Scout's retrieval-augmented prompts are long, so
    prefill is the axis that matters, and it needs its own harness.

    `geniex-bench` is llama-bench style: fixed prompt length, fixed generation
    length, repeated, reporting time-to-first-token, prefill tok/s and decode
    tok/s as separate numbers.

    It ships as a per-release archive rather than with the CLI, so this script
    fetches the build matching the INSTALLED GenieX version and verifies its
    published SHA256. Benchmarking a v0.7.0 harness against a v0.8.0 runtime
    would quietly compare two different things.

.PARAMETER Model
    Model to benchmark. Must suit the plugin: a GGUF for llama_cpp, an AI Hub
    bundle for qairt.

.PARAMETER Plugin
    GenieX engine. Selected by model format in normal use; here it is explicit
    so the two can be compared on the same axes.

.PARAMETER Device
    Compute units to measure. Note `--compute` has no effect on qairt bundles,
    which are NPU-targeted by construction.

.PARAMETER Matrix
    Run the full prefill matrix instead of a single model, ignoring
    -Model, -Plugin and -Device.

.PARAMETER PromptTokens
    Prompt length. 512 approximates a retrieval-augmented turn.

.PARAMETER NoRecord
    Print results without appending them to the benchmark history.

.EXAMPLE
    .\Scripts\Invoke-PrefillBench.ps1 -Matrix

.EXAMPLE
    .\Scripts\Invoke-PrefillBench.ps1 -Model 'unsloth/Qwen3-4B-GGUF:Q4_0' -Device npu
#>
[CmdletBinding()]
param(
    [string]$Model = 'unsloth/Qwen3-4B-GGUF:Q4_0',
    [ValidateSet('llama_cpp', 'qairt')]
    [string]$Plugin = 'llama_cpp',
    [ValidateSet('cpu', 'gpu', 'npu')]
    [string[]]$Device = @('npu', 'gpu', 'cpu'),
    [switch]$Matrix,
    [int]$PromptTokens = 512,
    [int]$GenTokens = 128,
    [int]$Repeat = 3,
    [switch]$NoRecord
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force

# The prefill matrix from docs/BENCHMARKS.md: GenieX's two plugins on Qwen3-4B, plus
# Phi-4-mini-reasoning, which is the one model that also exists as an ORT
# GenAI bundle and so puts all three runtimes on common ground.
$Section93Cells = @(
    @{ Plugin = 'qairt';     Device = 'npu'; Model = 'qualcomm/Qwen3-4B:W4A16' }
    @{ Plugin = 'llama_cpp'; Device = 'npu'; Model = 'unsloth/Qwen3-4B-GGUF:Q4_0' }
    @{ Plugin = 'llama_cpp'; Device = 'gpu'; Model = 'unsloth/Qwen3-4B-GGUF:Q4_0' }
    @{ Plugin = 'llama_cpp'; Device = 'cpu'; Model = 'unsloth/Qwen3-4B-GGUF:Q4_0' }
    @{ Plugin = 'llama_cpp'; Device = 'npu'; Model = 'unsloth/Phi-4-mini-reasoning-GGUF:Q4_0' }
    @{ Plugin = 'llama_cpp'; Device = 'cpu'; Model = 'unsloth/Phi-4-mini-reasoning-GGUF:Q4_0' }
)

<#
.SYNOPSIS
    Resolve geniex-bench for the installed GenieX version, fetching if needed.
#>
function Resolve-GeniexBench {
    param([Parameter(Mandatory)][string]$Tag)

    $home_ = Join-Path ([System.IO.Path]::GetTempPath()) "atlas-geniex-bench-$Tag"
    $found = Get-ChildItem -Path $home_ -Filter 'geniex-bench.exe' -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { return $found.FullName }

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host "gh not available; cannot fetch geniex-bench $Tag." -ForegroundColor Red
        return $null
    }
    $asset = "geniex-bench-windows-arm64-$Tag.zip"
    New-Item -ItemType Directory -Force -Path $home_ | Out-Null
    Write-Host "Fetching $asset ..."
    gh release download $Tag --repo qualcomm/GenieX `
        --pattern $asset --pattern "$asset.sha256" --dir $home_ --clobber 2>&1 |
        ForEach-Object { Write-Host "  $_" }

    $zip = Join-Path $home_ $asset
    if (-not (Test-Path $zip)) {
        Write-Host "  download failed: $asset" -ForegroundColor Red
        return $null
    }
    $shaFile = "$zip.sha256"
    if (Test-Path $shaFile) {
        $expected = ((Get-Content $shaFile -Raw).Trim() -split '\s+')[0].ToLower()
        $actual   = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            Write-Host '  SHA256 MISMATCH -- refusing to use this archive.' -ForegroundColor Red
            return $null
        }
        Write-Host '  sha256 verified'
    }
    Expand-Archive -Path $zip -DestinationPath (Join-Path $home_ 'x') -Force
    $found = Get-ChildItem -Path $home_ -Filter 'geniex-bench.exe' -Recurse -ErrorAction SilentlyContinue |
             Select-Object -First 1
    if ($found) { return $found.FullName }
    Write-Host '  geniex-bench.exe not found in the archive.' -ForegroundColor Red
    $null
}

<#
.SYNOPSIS
    Run one cell and parse its result line.
#>
function Invoke-Cell {
    param([string]$Exe, [string]$Plugin, [string]$Device, [string]$Model,
          [int]$Prompt, [int]$Gen, [int]$Reps)

    $raw = (& $Exe --plugin $Plugin --device $Device -m $Model -p $Prompt -n $Gen -r $Reps 2>&1 | Out-String) `
           -replace '\x1b\[[0-9;]*m', ''

    # geniex-bench prints a great deal of plugin teardown trace around the one
    # line that matters, so match that line specifically rather than tailing.
    $ok = [regex]::Match($raw,
        'ttft=([\d.]+)ms\s+prefill=([\d.]+)tps\s+decode=([\d.]+)tps\s+gen=(\d+)')
    if (-not $ok.Success) {
        return [pscustomobject]@{
            Plugin = $Plugin; Device = $Device; Model = $Model; Ok = $false
            Tail = (($raw -split "`r?`n" | Where-Object { $_.Trim() } | Select-Object -Last 3) -join ' | ')
        }
    }
    [pscustomobject]@{
        Plugin     = $Plugin
        Device     = $Device
        Model      = $Model
        Ok         = $true
        TtftMs     = [double]$ok.Groups[1].Value
        PrefillTps = [double]$ok.Groups[2].Value
        DecodeTps  = [double]$ok.Groups[3].Value
        GenTokens  = [int]$ok.Groups[4].Value
    }
}

# --------------------------------------------------------------------- main

$state = Get-AtlasState
Write-Host 'geniex-bench: prefill vs decode' -ForegroundColor Cyan
Write-Host ("stack {0} | geniex {1} | llama.cpp {2}" -f `
    (Get-AtlasShortId $state.id), $state.geniex.version, $state.geniex.llamacpp)
Write-Host ''

if ($state.geniex.version -notmatch '^v\d') {
    Write-Host "GenieX not installed or not reporting a version ($($state.geniex.version))." -ForegroundColor Red
    exit 1
}
$exe = Resolve-GeniexBench -Tag $state.geniex.version
if (-not $exe) { exit 1 }
Write-Host "harness: $exe"
Write-Host ''

$cells = if ($Matrix) { $Section93Cells }
         else { $Device | ForEach-Object { @{ Plugin = $Plugin; Device = $_; Model = $Model } } }

$results = [System.Collections.Generic.List[object]]::new()
foreach ($c in $cells) {
    Write-Host ("  {0,-34} {1,-10} {2} ..." -f $c.Model, $c.Plugin, $c.Device)
    $r = Invoke-Cell -Exe $exe -Plugin $c.Plugin -Device $c.Device -Model $c.Model `
                     -Prompt $PromptTokens -Gen $GenTokens -Reps $Repeat
    $results.Add($r)
    if (-not $r.Ok) { Write-Host ("    FAILED: {0}" -f $r.Tail) -ForegroundColor Red }
}

Write-Host ''
$good = @($results | Where-Object Ok)
if ($good.Count -eq 0) { Write-Host 'No cell produced a result.' -ForegroundColor Red; exit 1 }

$good |
    Sort-Object PrefillTps -Descending |
    Format-Table -AutoSize -Property Model, Plugin, Device,
        @{n = 'TTFT(ms)'; e = { $_.TtftMs } },
        @{n = 'Prefill tok/s'; e = { $_.PrefillTps } },
        @{n = 'Decode tok/s'; e = { $_.DecodeTps } } |
    Out-String | Write-Host

if (-not $NoRecord) {
    foreach ($r in $good) {
        Add-AtlasBenchmarkRecord -State $state -Source 'Invoke-PrefillBench.ps1' `
            -Model $r.Model -Compute "$($r.Plugin)/$($r.Device)" `
            -TokPerSec $r.DecodeTps -FirstTokenS ([math]::Round($r.TtftMs / 1000, 3)) `
            -Tokens $r.GenTokens -PrefillTps $r.PrefillTps -PromptTokens $PromptTokens `
            -Extra @{ repetitions = $Repeat; harness = 'geniex-bench' } | Out-Null
    }
    Write-Host ("Recorded {0} measurement(s) under stack {1}" -f $good.Count, (Get-AtlasShortId $state.id)) -ForegroundColor Green
    Write-Host 'View with: .\Scripts\Update-Workspace.ps1 -History' -ForegroundColor DarkGray
}

$failed = @($results | Where-Object { -not $_.Ok })
if ($failed.Count -gt 0) { exit 1 }
