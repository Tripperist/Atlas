<#
.SYNOPSIS
    Compare CPU / GPU / NPU inference on the same prompt to find what is real.

.DESCRIPTION
    Automates README section 7. This is the script that answers "is the NPU
    actually doing anything?"

    The method is comparative, because no single run is self-evident. If
    -Compute cpu and -Compute npu produce the same throughput, the placement
    flag is not changing where the work happens.

    Conditions are pinned so runs are comparable: identical prompt, identical
    token budget, fixed seed, and an explicit power mode (GenieX defaults to
    'burst', which will skew any comparison against a machine on battery).

    Note: --compute mainly steers the llama.cpp engine. QAIRT bundles are
    NPU-targeted by construction, so CPU/GPU placement may be ignored for
    them -- which is itself a useful thing to observe.

.PARAMETER Model
    Cached model name. Defaults to the first entry from 'geniex list'.

.PARAMETER Prompt
    Prompt text sent to every run.

.PARAMETER MaxTokens
    Token budget per run. Keep small for quick comparisons.

.PARAMETER Compute
    Compute units to test. Defaults to cpu, gpu, npu.

.PARAMETER Repeat
    Runs per compute unit. More runs expose thermal variance.

.PARAMETER PowerMode
    HTP power mode. Pin this when benchmarking.

.EXAMPLE
    .\Scripts\Test-ComputeUnits.ps1

.EXAMPLE
    .\Scripts\Test-ComputeUnits.ps1 -Model qualcomm/Qwen3-4B:W4A16 -Repeat 3
#>
[CmdletBinding()]
param(
    [string]$Model,
    [string]$Prompt = 'Explain Rayleigh scattering in two sentences.',
    [int]$MaxTokens = 128,
    [ValidateSet('cpu', 'gpu', 'npu', 'hybrid')]
    [string[]]$Compute = @('cpu', 'gpu', 'npu'),
    [int]$Repeat = 1,
    [string]$PowerMode = 'burst'
)

$ErrorActionPreference = 'Continue'

if (-not (Get-Command geniex -ErrorAction SilentlyContinue)) {
    Write-Error 'geniex not found on PATH. See README section 4.2.'
    exit 1
}

# Resolve a model if none was supplied: first owner/name cell in 'geniex list'.
if (-not $Model) {
    $listing = geniex list 2>&1 | Out-String
    $match = [regex]::Match($listing, '[\w.-]+/[\w.-]+')
    if (-not $match.Success) {
        Write-Error "No cached models. Run: geniex pull ai-hub-models/Qwen3-4B"
        exit 1
    }
    $Model = $match.Value
}

Write-Host "Model      : $Model"
Write-Host "Prompt     : $Prompt"
Write-Host "Max tokens : $MaxTokens"
Write-Host "Power mode : $PowerMode"
Write-Host "Repeats    : $Repeat"
Write-Host ''

# Warm-up: first run pays cold-load cost that would distort the comparison.
Write-Host 'Warming up (excluded from results)...' -ForegroundColor DarkGray
& geniex infer $Model -p 'hi' --max-tokens 8 --think=false *> $null

$rows = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($unit in $Compute) {
    for ($i = 1; $i -le $Repeat; $i++) {
        Write-Host ("Running {0} (run {1}/{2})..." -f $unit, $i, $Repeat) -ForegroundColor Cyan

        $outFile = [System.IO.Path]::GetTempFileName()
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            & geniex infer $Model `
                -p $Prompt `
                --max-tokens $MaxTokens `
                --compute $unit `
                --power-mode $PowerMode `
                --seed 42 `
                --think=false 1> $outFile 2>&1
            $exit = $LASTEXITCODE
        }
        catch {
            $exit = 1
        }
        $sw.Stop()

        $text = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
        Remove-Item $outFile -ErrorAction SilentlyContinue

        $seconds = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        $ok = ($exit -eq 0)

        # GenieX reports its own stats, e.g.
        #   -- 32.4 tok/s * 12 tok * 0.1 s first token --
        # Prefer those over wall-clock: wall-clock includes per-backend startup
        # (GPU shader compilation, NPU graph preparation), which is a one-time
        # cost and would otherwise be mistaken for slow generation.
        $tokPerSec = if ($text -match '(\d+(?:\.\d+)?)\s*tok/s') { [double]$Matches[1] } else { $null }
        $tokCount = if ($text -match '(\d+)\s*tok\b') { [int]$Matches[1] } else { $null }
        $firstTok = if ($text -match '(\d+(?:\.\d+)?)\s*s first token') { [double]$Matches[1] } else { $null }

        if (-not $tokPerSec -and $ok -and $seconds -gt 0) {
            $tokPerSec = [math]::Round($MaxTokens / $seconds, 1)
        }

        # Wall-clock minus time actually spent generating ~= startup overhead.
        $startup = if ($tokPerSec -and $tokCount -and $tokPerSec -gt 0) {
            [math]::Round($seconds - ($tokCount / $tokPerSec), 2)
        }
        else { $null }

        $rows.Add([pscustomobject]@{
                Compute    = $unit
                Run        = $i
                OK         = $ok
                'Tok/s'    = $tokPerSec
                'FirstTok' = $firstTok
                'Startup'  = $startup
                'Wall'     = $seconds
                Note       = if (-not $ok) { 'failed - see --log debug' } else { '' }
            })
    }
}

Write-Host ''
$rows | Format-Table -AutoSize

# ------------------------------------------------------------- interpretation
Write-Host ''
Write-Host 'Interpretation' -ForegroundColor Cyan
Write-Host '--------------'

# Compare on generation rate, not wall-clock. Startup is reported separately
# because it is a one-time cost that says nothing about sustained throughput.
$byUnit = $rows | Where-Object { $_.OK -and $_.'Tok/s' } | Group-Object Compute | ForEach-Object {
    [pscustomobject]@{
        Compute     = $_.Name
        AvgTokPerSec = [math]::Round(($_.Group | Measure-Object -Property 'Tok/s' -Average).Average, 1)
        AvgStartup  = [math]::Round(($_.Group | Measure-Object -Property 'Startup' -Average).Average, 2)
    }
}

if ($byUnit.Count -lt 2) {
    Write-Host 'Not enough successful runs to compare.' -ForegroundColor Yellow
}
else {
    $byUnit | Sort-Object AvgTokPerSec -Descending | Format-Table -AutoSize
    $fastest = ($byUnit | Sort-Object AvgTokPerSec -Descending | Select-Object -First 1)
    $slowest = ($byUnit | Sort-Object AvgTokPerSec -Descending | Select-Object -Last 1)
    $spread = if ($fastest.AvgTokPerSec -gt 0) {
        [math]::Round((($fastest.AvgTokPerSec - $slowest.AvgTokPerSec) / $fastest.AvgTokPerSec) * 100, 1)
    }
    else { 0 }

    Write-Host "Fastest generation: $($fastest.Compute) at $($fastest.AvgTokPerSec) tok/s"
    Write-Host "Spread            : $spread% in tok/s between fastest and slowest"
    Write-Host ''
    if ($spread -lt 10) {
        Write-Host 'Under 10% spread means --compute is probably NOT changing' -ForegroundColor Yellow
        Write-Host 'where the work runs. Likely causes:' -ForegroundColor Yellow
        Write-Host '  - a QAIRT bundle, which ignores CPU/GPU placement (llama_cpp only)'
        Write-Host '  - the flag is accepted but silently falls back'
        Write-Host 'Confirm with: geniex infer <model> --log debug --verbose'
    }
    else {
        Write-Host 'Placement is taking effect: the backends differ measurably.' -ForegroundColor Green
        Write-Host 'Confirm against Task Manager > Performance (NPU and GPU graphs).'
    }

    if ($fastest.Compute -eq 'cpu') {
        Write-Host ''
        Write-Host 'Note: CPU came out fastest. Before trusting that, check whether' -ForegroundColor Yellow
        Write-Host 'the machine was cold and the run was short. Measured on this' -ForegroundColor Yellow
        Write-Host 'hardware, CPU throughput drops ~19% as it warms while the NPU' -ForegroundColor Yellow
        Write-Host 'holds steady, which reverses the ranking. Re-check with:' -ForegroundColor Yellow
        Write-Host '  .\Scripts\Invoke-Benchmark.ps1 -MaxTokens 400 -Repeat 3' -ForegroundColor Yellow
    }
}

Write-Host ''
Write-Host 'Reminder: throughput alone is indirect evidence. For ONNX models,' -ForegroundColor DarkGray
Write-Host 'prove it directly with:' -ForegroundColor DarkGray
Write-Host '  .\.venv\Scripts\python.exe src\setup\check_qnn.py --prove-npu' -ForegroundColor DarkGray
