<#
.SYNOPSIS
    Run the stock llama.cpp control: the same GGUF through an unmodified upstream
    llama-bench, on the GPU and CPU, interleaved, recorded as kind = control.

.DESCRIPTION
    A control separates "the machine changed" from "the software changed". When a GenieX
    release moves a figure, an upstream build that did not change tells you which it was:
    on 2026-10-16 the GenieX v0.9.0 GPU decode on the 30B model fell about 40 %, and the
    control showed the machine in its normal state.

    The build is PINNED in Scripts/llamacpp-control.json (release tag, asset, SHA256).
    Nothing is installed: the release zip is unpacked under .atlas-local/tools/. It is
    downloaded only when -Download is given, after which its SHA256 is checked against the
    manifest and a mismatch is refused. -LlamaBenchPath uses an existing extracted build
    instead (the hash of its llama-bench.exe is recorded, and the record says it was
    supplied, not fetched).

    Rounds alternate the order (gpu first, then cpu first, ...), so a drift in machine
    state does not line up with one configuration. Each round of each configuration is its
    own history record, with prefill (pp) and decode (tg) tok/s from llama-bench's own
    JSON output.

    llama-bench labels both configurations "OpenCL", because that is the backend it
    loaded; that -ngl 0 ran on the CPU is inferred from the numbers. This script does not
    sample utilization.

.PARAMETER Model
    A GenieX-cached GGUF repository, found under %USERPROFILE%\.cache\geniex\models.

.PARAMETER ModelPath
    A GGUF file, instead of -Model.

.PARAMETER Config
    gpu (-ngl 99, Adreno OpenCL) and/or cpu (-ngl 0).

.PARAMETER Rounds
    Interleaved rounds. Three is what the published control used.

.PARAMETER Download
    Fetch the pinned release if it is not already unpacked. Prints what it will fetch first.

.PARAMETER HashModel
    Record the model file's SHA256 (a 16 GiB file takes a minute or two).

.EXAMPLE
    .\Scripts\Invoke-LlamaCppControl.ps1 -Download

.EXAMPLE
    .\Scripts\Invoke-LlamaCppControl.ps1 -Model unsloth/Qwen3-4B-GGUF -Rounds 3 -LlamaBenchPath D:\tools\llama\llama-bench.exe
#>
#requires -Version 7
[CmdletBinding()]
param(
    [string]$Model = 'unsloth/Qwen3-Coder-30B-A3B-Instruct-GGUF',
    [string]$ModelPath,
    [ValidateSet('gpu', 'cpu')][string[]]$Config = @('gpu', 'cpu'),
    [int]$PromptTokens = 512,
    [int]$GenTokens = 128,
    [int]$Rounds = 3,
    [int]$Repeat = 1,
    [string]$LlamaBenchPath,
    [switch]$Download,
    [switch]$HashModel,
    [switch]$NoRecord,
    # Run on battery anyway; the result is recorded as onAcPower = false
    [switch]$AllowBattery
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AtlasConditions.psm1') -Force

# A control compares engines on the CPU and GPU; the NPU is not involved.
$null = Assert-AtlasConditions -Needs @($Config) -AllowBattery:$AllowBattery

$manifest = Get-Content (Join-Path $PSScriptRoot 'llamacpp-control.json') -Raw | ConvertFrom-Json

# ----------------------------------------------------------------------- binary

$binarySource = $null
$archiveSha = $null
if ($LlamaBenchPath) {
    if (-not (Test-Path $LlamaBenchPath)) { Write-Host "llama-bench not found: $LlamaBenchPath" -ForegroundColor Red; exit 1 }
    $exe = (Resolve-Path $LlamaBenchPath).Path
    $binarySource = 'supplied'
}
else {
    $dir = Join-Path $root ".atlas-local/tools/llama.cpp-$($manifest.tag)"
    $exe = Get-ChildItem -Path $dir -Filter 'llama-bench.exe' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1 -ExpandProperty FullName
    if ($exe) {
        $binarySource = 'cached'
        # The zip is kept beside the unpacked build, so the hash can still be checked.
        $kept = Join-Path $dir $manifest.asset
        if (Test-Path $kept) { $archiveSha = (Get-FileHash $kept -Algorithm SHA256).Hash.ToLower() }
    }
    else {
        Write-Host "The pinned llama.cpp $($manifest.tag) is not unpacked under $dir." -ForegroundColor Yellow
        Write-Host "  asset : $($manifest.asset)"
        Write-Host "  from  : $($manifest.url)"
        Write-Host "  sha256: $($manifest.sha256)"
        if (-not $Download) {
            Write-Host 'Run again with -Download to fetch it (nothing is installed), or give -LlamaBenchPath.' -ForegroundColor Yellow
            exit 1
        }
        New-Item -ItemType Directory -Force -Path $dir | Out-Null
        $zip = Join-Path $dir $manifest.asset
        Write-Host 'downloading ...'
        Invoke-WebRequest -Uri $manifest.url -OutFile $zip -UseBasicParsing
        $archiveSha = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLower()
        if ($archiveSha -ne $manifest.sha256) {
            Remove-Item $zip -Force
            Write-Host "SHA256 MISMATCH: got $archiveSha, expected $($manifest.sha256). Refusing to use it." -ForegroundColor Red
            exit 1
        }
        Write-Host 'sha256 verified'
        Expand-Archive -Path $zip -DestinationPath (Join-Path $dir 'x') -Force
        $exe = Get-ChildItem -Path $dir -Filter 'llama-bench.exe' -Recurse | Select-Object -First 1 -ExpandProperty FullName
        $binarySource = 'downloaded'
    }
}
$exeSha = (Get-FileHash $exe -Algorithm SHA256).Hash.ToLower()

# ------------------------------------------------------------------------ model

if (-not $ModelPath) {
    $modelDir = Join-Path $env:USERPROFILE ".cache/geniex/models/$Model"
    $found = @(Get-ChildItem -Path $modelDir -Filter '*.gguf' -ErrorAction SilentlyContinue | Sort-Object Name)
    if (-not $found.Count) { Write-Host "No GGUF under $modelDir. Pull it with: geniex pull $Model" -ForegroundColor Red; exit 1 }
    $pick = $found | Where-Object Name -Match 'Q4_0' | Select-Object -First 1
    if (-not $pick) { $pick = $found[0] }
    $ModelPath = $pick.FullName
}
if (-not (Test-Path $ModelPath)) { Write-Host "Model file not found: $ModelPath" -ForegroundColor Red; exit 1 }
$modelFile = Get-Item $ModelPath
$quant = [regex]::Match($modelFile.BaseName, '(Q\d[A-Za-z0-9_]*|F16|BF16)$').Value
$modelLabel = if ($quant) { "${Model}:$quant" } else { $Model }
$artifact = @{ file = $modelFile.Name; sizeBytes = $modelFile.Length }
if ($HashModel) { $artifact.sha256 = (Get-FileHash $modelFile.FullName -Algorithm SHA256).Hash.ToLower() }

$state = Get-AtlasState
Write-Host 'Stock llama.cpp control' -ForegroundColor Cyan
Write-Host ("stack {0} | llama.cpp {1} ({2}) | {3}" -f (Get-AtlasShortId $state.id), $manifest.tag, $binarySource, $modelLabel)
Write-Host ''

# -------------------------------------------------------------------------- run

$ngl = @{ gpu = 99; cpu = 0 }
$results = [System.Collections.Generic.List[object]]::new()
for ($round = 1; $round -le $Rounds; $round++) {
    # gpu first, then cpu first, ... so a drift in machine state is not one configuration's.
    $ordered = if ($round % 2 -eq 0) { @($Config)[($Config.Count - 1)..0] } else { @($Config) }
    $orderLabel = $ordered -join '>'
    foreach ($cfg in $ordered) {
        $errFile = [System.IO.Path]::GetTempFileName()
        $json = & $exe -m $modelFile.FullName -ngl $ngl[$cfg] -p $PromptTokens -n $GenTokens -r $Repeat -o json 2> $errFile | Out-String
        $rows = try { $json | ConvertFrom-Json } catch { $null }
        $pp = $rows | Where-Object { $_.n_prompt -gt 0 -and $_.n_gen -eq 0 } | Select-Object -First 1
        $tg = $rows | Where-Object { $_.n_gen -gt 0 -and $_.n_prompt -eq 0 } | Select-Object -First 1
        if (-not $pp -or -not $tg) {
            Write-Host ("  round {0} {1}: FAILED - {2}" -f $round, $cfg, ((Get-Content $errFile -Tail 3) -join ' | ')) -ForegroundColor Red
            Remove-Item $errFile -Force -ErrorAction SilentlyContinue
            continue
        }
        Remove-Item $errFile -Force -ErrorAction SilentlyContinue
        $results.Add([pscustomobject]@{
            Round = $round; Config = $cfg; Order = $orderLabel; Ngl = $ngl[$cfg]
            Prefill = [double]$pp.avg_ts; PrefillStdev = [double]$pp.stddev_ts
            Decode = [double]$tg.avg_ts; DecodeStdev = [double]$tg.stddev_ts
            Backend = $pp.backends; BuildCommit = $pp.build_commit; Threads = $pp.n_threads
        })
        Write-Host ("  round {0} {1}: prefill {2,7:N1} tok/s | decode {3,6:N1} tok/s" -f $round, $cfg, $pp.avg_ts, $tg.avg_ts)
    }
}

if ($results.Count -eq 0) { Write-Host 'No run produced a result.' -ForegroundColor Red; exit 1 }

Write-Host ''
$results | Group-Object Config | ForEach-Object {
    $p = $_.Group | Measure-Object Prefill -Average -Minimum -Maximum
    $d = $_.Group | Measure-Object Decode -Average -Minimum -Maximum
    Write-Host ("{0}: prefill {1:N1} ({2:N1}-{3:N1}) | decode {4:N1} ({5:N1}-{6:N1}) over {7} round(s)" -f `
        $_.Name, $p.Average, $p.Minimum, $p.Maximum, $d.Average, $d.Minimum, $d.Maximum, $_.Count)
}

if (-not $NoRecord) {
    foreach ($r in $results) {
        Add-AtlasBenchmarkRecord -State $state -Source 'Invoke-LlamaCppControl.ps1' -Kind control `
            -Model $modelLabel -Compute "llama.cpp-$($manifest.tag)/$($r.Config)" `
            -TokPerSec ([math]::Round($r.Decode, 2)) -Tokens $GenTokens `
            -PrefillTps ([math]::Round($r.Prefill, 2)) -PromptTokens $PromptTokens `
            -N $Repeat -Stdev ([math]::Round($r.DecodeStdev, 2)) -Order $r.Order -PromptKind 'synthetic (llama-bench -p)' `
            -Harness 'llama-bench' -HarnessVersion "$($manifest.tag) ($($r.BuildCommit))" -ModelArtifact $artifact `
            -Extra @{ engine = 'llama.cpp stock'; round = $r.Round; ngl = $r.Ngl; statistic = 'mean'
                      backendReported = $r.Backend; threads = $r.Threads; binarySource = $binarySource
                      llamaBenchSha256 = $exeSha
                      archiveSha256 = $archiveSha } | Out-Null
    }
    Write-Host ("Recorded {0} control measurement(s) under stack {1}" -f $results.Count, (Get-AtlasShortId $state.id)) -ForegroundColor Green
}
