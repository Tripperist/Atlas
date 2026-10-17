<#
.SYNOPSIS
    Benchmark ONNX Runtime GenAI from Python and from C#, interleaved, on the same model
    and the same method, and record both.

.DESCRIPTION
    Replaces the inline Python / C# / Python sequence used on 2026-10-16 to ask whether an
    onnxruntime-qnn upgrade (2.6.0 to 2.7.0) had slowed the NPU path. That sequence is the
    reason this exists: on battery, both runtimes were slow, and the C# control on the
    unchanged package fell by the same factor, which is how the cause was found. Run on AC
    power, with the conditions check, and with the two runtimes alternating.

    Both sides use src/setup/bench_ort_genai.py's method: a fixed-length prompt of random
    token ids (default 512), a fixed generation length (default 128), prefill and decode
    timed separately. The Python side is bench_ort_genai.py; the C# side is the OrtBench
    project (src/csharp/OrtBench), a benchmark of its own so that GenAiProbe stays a
    smoke probe.

    Each round runs both runtimes, and the order alternates by round (python first, then C#
    first, ...), so a drift in machine state does not line up with one runtime. Every run
    of each runtime is a history record, with the package versions that ran.

    -QnnVersion builds the C# project against a different Qualcomm.ML.OnnxRuntime.QNN
    version (the csproj pins 2.6.0). NuGet downloads that package if it is not already in
    the local cache. The Python side uses whatever onnxruntime-qnn the virtual environment
    has, so a package comparison needs the two sides to be changed on purpose and the record
    says which was which.

.PARAMETER ModelDir
    An ORT GenAI model directory (genai_config.json with a QNN EPContext graph for the NPU).

.PARAMETER Runtime
    python and/or csharp.

.PARAMETER Rounds
    Interleaved rounds. Each round is a separate process per runtime, so a model load is
    paid every time; that is a minute or so on the Phi-4 bundle.

.NOTES
    By default the two sides do NOT run the same onnxruntime-qnn: the Python side uses the
    virtual environment's package, the C# side the csproj's pin (2.6.0), which makes the C#
    run the unchanged control while the Python package is upgraded. The package versions
    each run used are recorded with it, so a comparison can see which was which.

.PARAMETER QnnVersion
    Build the C# side against this Qualcomm.ML.OnnxRuntime.QNN version.

.PARAMETER CpuOnly
    Skip QNN on both sides, for a CPU baseline on the same model.

.EXAMPLE
    .\Scripts\Invoke-BenchOrtGenAi.ps1

.EXAMPLE
    pwsh -Command "& .\Scripts\Invoke-BenchOrtGenAi.ps1 -Runtime csharp -Rounds 2 -QnnVersion 2.7.0"
#>
#requires -Version 7
[CmdletBinding()]
param(
    [string]$ModelDir = 'models/Phi-4-mini-reasoning-onnx/npu/qnn-int4',
    [ValidateSet('python', 'csharp')][string[]]$Runtime = @('python', 'csharp'),
    [int]$Rounds = 3,
    [int]$NPrompt = 512,
    [int]$NGen = 128,
    [int]$Repetitions = 3,
    [int]$Seed = 42,
    [string]$QnnVersion,
    [switch]$CpuOnly,
    [switch]$NoRecord,
    # Run on battery anyway; the result is recorded as onAcPower = false
    [switch]$AllowBattery
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'BenchConditions.psm1') -Force

$null = Assert-AtlasConditions -Needs $(if ($CpuOnly) { @() } else { 'npu' }) -AllowBattery:$AllowBattery

$model = if ([System.IO.Path]::IsPathRooted($ModelDir)) { $ModelDir } else { Join-Path $root $ModelDir }
if (-not (Test-Path $model)) {
    Write-Host "Model not found: $model" -ForegroundColor Red
    Write-Host 'Download it with: hf download microsoft/Phi-4-mini-reasoning-onnx --include "npu/*" --local-dir models\Phi-4-mini-reasoning-onnx' -ForegroundColor DarkGray
    exit 1
}
$label = $model -replace '\\', '/'
$label = if ($label -match '/models/([^/]+)/') { $Matches[1] } else { Split-Path $model -Leaf }

$py = Join-Path $root '.venv\Scripts\python.exe'
if (-not (Test-Path $py)) { $py = 'python' }

$exe = $null
if ('csharp' -in $Runtime) {
    $project = Join-Path $root 'src/csharp/OrtBench'
    $out = Join-Path $root ".atlas-local/tools/OrtBench-$(if ($QnnVersion) { $QnnVersion } else { 'default' })"
    $buildArgs = @('build', $project, '-c', 'Release', '-o', $out, '--nologo', '-v', 'q')
    if ($QnnVersion) { $buildArgs += "-p:QnnVersion=$QnnVersion" }
    Write-Host "building OrtBench$(if ($QnnVersion) { " (QNN $QnnVersion)" }) ..."
    $built = & dotnet @buildArgs 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { Write-Host $built -ForegroundColor Red; exit 1 }
    $exe = Join-Path $out 'OrtBench.exe'
}

$state = Get-AtlasState
Write-Host 'ONNX Runtime GenAI: Python and C#' -ForegroundColor Cyan
Write-Host ("stack {0} | model {1} | {2} / {3} tokens | {4} round(s) x {5} repetition(s)" -f `
    (Get-AtlasShortId $state.id), $label, $NPrompt, $NGen, $Rounds, $Repetitions)
Write-Host ''

function Invoke-Python([string]$Json) {
    $argv = @((Join-Path $root 'src/setup/bench_ort_genai.py'), '--model-dir', $model, '--n-prompt', $NPrompt,
              '--n-gen', $NGen, '--repetitions', $Repetitions, '--seed', $Seed, '--json-out', $Json, '--no-record')
    if ($CpuOnly) { $argv += '--cpu-only' }
    if ($AllowBattery) { $argv += '--allow-battery' }
    & $py @argv 2>&1 | Out-Null
}
function Invoke-CSharp([string]$Json) {
    $argv = @($model, '--n-prompt', $NPrompt, '--n-gen', $NGen, '--repetitions', $Repetitions, '--seed', $Seed, '--json-out', $Json)
    if ($CpuOnly) { $argv += '--cpu-only' }
    & $exe @argv 2>&1 | Out-Null
}

$results = [System.Collections.Generic.List[object]]::new()
for ($round = 1; $round -le $Rounds; $round++) {
    $ordered = if ($round % 2 -eq 0) { @($Runtime)[($Runtime.Count - 1)..0] } else { @($Runtime) }
    $orderLabel = $ordered -join '>'
    foreach ($rt in $ordered) {
        $json = [System.IO.Path]::GetTempFileName()
        Write-Host ("  round {0} {1,-6} ..." -f $round, $rt) -NoNewline
        if ($rt -eq 'python') { Invoke-Python $json } else { Invoke-CSharp $json }
        $r = try { Get-Content $json -Raw | ConvertFrom-Json } catch { $null }
        Remove-Item $json -Force -ErrorAction SilentlyContinue
        if (-not $r -or -not $r.decodeTps) { Write-Host ' FAILED' -ForegroundColor Red; continue }
        Write-Host (" prefill {0,7:N1} tok/s | decode {1,6:N1} tok/s | first token {2,5:N2} s" -f $r.prefillTps, $r.decodeTps, $r.ttftSeconds)
        $results.Add([pscustomobject]@{ Round = $round; Runtime = $rt; Order = $orderLabel; R = $r })
    }
}

if ($results.Count -eq 0) { Write-Host 'No run produced a result.' -ForegroundColor Red; exit 1 }

Write-Host ''
$results | Group-Object Runtime | ForEach-Object {
    $d = $_.Group | ForEach-Object { $_.R.decodeTps } | Measure-Object -Average -Minimum -Maximum
    $p = $_.Group | ForEach-Object { $_.R.prefillTps } | Measure-Object -Average
    Write-Host ("{0,-6}: decode {1:N1} ({2:N1}-{3:N1}) | prefill {4:N1} over {5} round(s)" -f $_.Name, $d.Average, $d.Minimum, $d.Maximum, $p.Average, $_.Count)
}

if (-not $NoRecord) {
    foreach ($x in $results) {
        $r = $x.R
        $isPy = $x.Runtime -eq 'python'
        $extra = @{ statistic = 'mean'; round = $x.Round; loadSeconds = $r.loadSeconds; packages = $r.versions }
        if (-not $isPy -and $QnnVersion) { $extra.qnnVersionRequested = $QnnVersion }
        Add-AtlasBenchmarkRecord -State $state -Source 'Invoke-BenchOrtGenAi.ps1' `
            -Model $label -Compute "$(if ($isPy) { 'ort_genai' } else { 'ort_genai-csharp' })/$(if ($CpuOnly) { 'cpu' } else { 'npu' })" `
            -TokPerSec ([math]::Round($r.decodeTps, 2)) -FirstTokenS ([math]::Round($r.ttftSeconds, 3)) -Tokens $NGen `
            -PrefillTps ([math]::Round($r.prefillTps, 1)) -PromptTokens $NPrompt `
            -N $r.n -Stdev ([math]::Round($r.decodeStdev, 2)) -Reps @($r.decodeReps | ForEach-Object { [math]::Round($_, 2) }) `
            -Order $x.Order -PromptKind 'random token ids (seeded)' -Seed $Seed `
            -Harness $(if ($isPy) { 'bench_ort_genai.py' } else { 'OrtBench (C#)' }) `
            -Extra $extra | Out-Null
    }
    Write-Host ("Recorded {0} run(s) under stack {1}" -f $results.Count, (Get-AtlasShortId $state.id)) -ForegroundColor Green
}
