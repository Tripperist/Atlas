<#
.SYNOPSIS
    Benchmark a model across compute units, sampling CPU, GPU and NPU utilization.

.DESCRIPTION
    Automates README section 9. Where Test-ComputeUnits.ps1 is a quick three-way
    sanity check, this produces a recorded result set: generation rate, first-token
    latency, startup cost, per-core CPU utilization and per-accelerator engine
    utilization sampled DURING each run, written to CSV.

    MEASURING THE NPU
    The Hexagon NPU registers as an MCDM compute accelerator (device class GUID
    {F01A9D53-3FF6-48D2-9F97-C8A7004BE10C}, DirectX 12 FL 1.0: Compute), so
    Windows exposes it through the ordinary 'GPU Engine' counter set -- under its
    own adapter LUID with engtype_compute. Task Manager's NPU graph reads the
    same engine.

    The catch: 'GPU Engine' instances are per-process (pid_N_luid_..._engtype_X)
    and only exist while that process runs. Enumerating instance paths before
    launching the workload therefore finds nothing. This script queries with a
    wildcard that re-expands on every sample, which is what makes the NPU visible.

    LUIDs are labelled by self-calibration: whichever adapter is busiest during
    the '--compute npu' runs is the NPU, and likewise for gpu. No hardcoded IDs.

.PARAMETER Model
    Cached model name. Defaults to the first entry from 'geniex list'.

.PARAMETER Compute
    Compute units to benchmark. Default cpu, gpu, npu.

.PARAMETER Repeat
    Runs per compute unit. 3+ recommended; thermals move these numbers.

.PARAMETER MaxTokens
    Token budget per run. Use >=128 so sampling has time to settle.

.PARAMETER CsvPath
    Output CSV. Defaults to .atlas-local/benchmarks/<timestamp>-<model>.csv

.PARAMETER NoUtilization
    Skip counter sampling; timing only.

.EXAMPLE
    .\Scripts\Invoke-Benchmark.ps1 -Model "unsloth/Qwen3-4B-GGUF:Q4_0" -Repeat 3

.EXAMPLE
    .\Scripts\Invoke-Benchmark.ps1 -Compute cpu,npu -MaxTokens 256 -Repeat 5
#>
[CmdletBinding()]
param(
    [string]$Model,
    [string]$Prompt = 'Explain how a lithium-ion battery works, in detail.',
    [int]$MaxTokens = 160,
    [ValidateSet('cpu', 'gpu', 'npu', 'hybrid')]
    [string[]]$Compute = @('cpu', 'gpu', 'npu'),
    [int]$Repeat = 3,
    [string]$PowerMode = 'burst',
    [string]$CsvPath,
    [switch]$NoUtilization
)

$ErrorActionPreference = 'Continue'
$root = Split-Path $PSScriptRoot -Parent

if (-not (Get-Command geniex -ErrorAction SilentlyContinue)) {
    Write-Error 'geniex not found on PATH. See README section 4.2.'
    exit 1
}

if (-not $Model) {
    $listing = geniex list 2>&1 | Out-String
    $m = [regex]::Match($listing, '[\w.-]+/[\w.-]+')
    if (-not $m.Success) { Write-Error 'No cached models. Run: geniex pull <model>'; exit 1 }
    $Model = $m.Value
}

# ------------------------------------------------- discover CPU core tiers
$coreInfo = Get-ChildItem 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor' | ForEach-Object {
    [pscustomobject]@{ Index = [int]$_.PSChildName; MHz = (Get-ItemProperty $_.PSPath).'~MHz' }
}
$tiers = $coreInfo | Group-Object MHz | Sort-Object { [int]$_.Name } -Descending
$tierMap = @{}; $tierNames = @(); $rank = 0
foreach ($t in $tiers) {
    $rank++
    $label = if ($tiers.Count -eq 1) { 'AllCores' } elseif ($rank -eq 1) { "Fast_$($t.Name)MHz" } else { "Slow_$($t.Name)MHz" }
    $tierNames += $label
    foreach ($c in $t.Group) { $tierMap[$c.Index] = $label }
}
$corePaths = $coreInfo.Index | Sort-Object | ForEach-Object { "\Processor Information(0,$_)\% Processor Utility" }

# Every Get-Counter call costs ~1s, because utilization counters need two
# samples to compute a rate. Two separate calls per loop left short runs with
# only a couple of samples and missed the accelerator entirely. Collect cores
# and engines in ONE call, and narrow the engine wildcards to the two engine
# types that matter instead of enumerating all ~470 instances.
$enginePaths = @(
    '\GPU Engine(*engtype_compute)\Utilization Percentage'
    '\GPU Engine(*engtype_3d)\Utilization Percentage'
)
$samplePaths = @($corePaths) + $enginePaths

Write-Host "Model      : $Model"
Write-Host "Compute    : $($Compute -join ', ')"
Write-Host "Max tokens : $MaxTokens   Repeats: $Repeat   Power: $PowerMode"
Write-Host "Core tiers : $($tierNames -join ', ')"
Write-Host ''

Write-Host 'Warming up (excluded)...' -ForegroundColor DarkGray
& geniex infer $Model -p 'hi' --max-tokens 8 --think=false *> $null

$rows = [System.Collections.Generic.List[pscustomobject]]::new()

foreach ($unit in $Compute) {
    for ($i = 1; $i -le $Repeat; $i++) {
        Write-Host ("{0} run {1}/{2}..." -f $unit, $i, $Repeat) -ForegroundColor Cyan

        $out = [System.IO.Path]::GetTempFileName()
        $job = Start-Job {
            & geniex infer $using:Model -p $using:Prompt `
                --max-tokens $using:MaxTokens --compute $using:unit `
                --power-mode $using:PowerMode --seed 42 --think=false 2>&1 |
                Out-File -FilePath $using:out -Encoding UTF8
        }

        $coreSamples = [System.Collections.Generic.List[object]]::new()
        $enginePeak = @{}
        $sw = [System.Diagnostics.Stopwatch]::StartNew()

        while ($job.State -eq 'Running') {
            if (-not $NoUtilization) {
                # One call for cores AND engines. The wildcards re-expand on
                # every call, so instances belonging to the inference process
                # (which starts after we do) are captured.
                try {
                    $all = (Get-Counter -Counter $samplePaths -EA Stop).CounterSamples

                    $snap = @{}
                    $perKey = @{}
                    foreach ($c in $all) {
                        if ($c.Path -match 'processor information') {
                            if ($c.InstanceName -match '^0,(\d+)$') { $snap[[int]$Matches[1]] = $c.CookedValue }
                        }
                        elseif ($c.CookedValue -gt 0.5 -and
                                $c.Path -match 'luid_[0-9a-fx]+_(0x[0-9a-f]+)_phys_\d+_eng_\d+_engtype_(\w+)') {
                            $key = "$($Matches[1])/$($Matches[2])"
                            # The driver can report >100% when an adapter
                            # aggregates several sub-engines; clamp for sanity.
                            $val = [math]::Min($c.CookedValue, 100)
                            if (-not $perKey.ContainsKey($key) -or $perKey[$key] -lt $val) {
                                $perKey[$key] = $val
                            }
                        }
                    }
                    if ($snap.Count) { $coreSamples.Add($snap) }
                    foreach ($k in $perKey.Keys) {
                        if (-not $enginePeak.ContainsKey($k) -or $enginePeak[$k] -lt $perKey[$k]) {
                            $enginePeak[$k] = [math]::Round($perKey[$k], 1)
                        }
                    }
                }
                catch { }
            }
            else { Start-Sleep -Milliseconds 250 }
            if ($sw.Elapsed.TotalSeconds -gt 600) { break }
        }
        Wait-Job $job -Timeout 60 | Out-Null
        Remove-Job $job -Force
        $sw.Stop()

        $text = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
        Remove-Item $out -EA SilentlyContinue

        # GenieX prints: "<rate> tok/s * <count> tok * <t> s first token"
        # Parse all three together. A naive '(\d+)\s*tok\b' matches the DECIMAL
        # of the rate ("5 tok" out of "60.5 tok/s") and silently returns the
        # wrong token count, which corrupts the startup calculation.
        $tokPerSec = $null; $tokCount = $null; $firstTok = $null
        $stats = [regex]::Match($text, '([\d.]+)\s*tok/s\D+?(\d+)\s*tok\b\D+?([\d.]+)\s*s\s*first token')
        if ($stats.Success) {
            $tokPerSec = [double]$stats.Groups[1].Value
            $tokCount = [int]$stats.Groups[2].Value
            $firstTok = [double]$stats.Groups[3].Value
        }
        else {
            if ($text -match '([\d.]+)\s*tok/s') { $tokPerSec = [double]$Matches[1] }
            if ($text -match '(?:\D|^)(\d+)\s*tok\s*[^/]') { $tokCount = [int]$Matches[1] }
            if ($text -match '([\d.]+)\s*s\s*first token') { $firstTok = [double]$Matches[1] }
        }

        $wall = [math]::Round($sw.Elapsed.TotalSeconds, 2)
        $startup = if ($tokPerSec -and $tokCount -and $tokPerSec -gt 0) {
            [math]::Round($wall - ($tokCount / $tokPerSec), 2)
        } else { $null }

        $row = [ordered]@{
            Timestamp = (Get-Date -Format 's')
            Model     = $Model
            Compute   = $unit
            Run       = $i
            TokPerSec = $tokPerSec
            FirstTokS = $firstTok
            StartupS  = $startup
            WallS     = $wall
            Tokens    = $tokCount
            Samples   = $coreSamples.Count
        }

        if ($coreSamples.Count) {
            foreach ($label in $tierNames) {
                $idx = $tierMap.Keys | Where-Object { $tierMap[$_] -eq $label }
                $vals = foreach ($snap in $coreSamples) {
                    $sum = 0.0; $n = 0
                    foreach ($k in $idx) { if ($snap.ContainsKey($k)) { $sum += $snap[$k]; $n++ } }
                    if ($n) { $sum / $n }
                }
                $row["${label}_Mean"] = if ($vals) { [math]::Round(($vals | Measure-Object -Average).Average, 1) } else { $null }
            }
            $perCoreMean = @{}
            foreach ($k in $coreInfo.Index) {
                $v = foreach ($snap in $coreSamples) { if ($snap.ContainsKey($k)) { $snap[$k] } }
                $perCoreMean[$k] = if ($v) { [math]::Round(($v | Measure-Object -Average).Average, 1) } else { 0 }
            }
            $row['AllCores_Mean'] = [math]::Round((($perCoreMean.Values) | Measure-Object -Average).Average, 1)
            $top = $perCoreMean.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
            $row['BusiestCore'] = $top.Key
            $row['BusiestCorePct'] = $top.Value
            foreach ($k in ($coreInfo.Index | Sort-Object)) { $row["Core$k"] = $perCoreMean[$k] }
        }

        # Stash raw engine peaks; labelled after all runs complete.
        $row['_EnginePeaks'] = ($enginePeak.GetEnumerator() |
            ForEach-Object { "$($_.Key)=$($_.Value)" }) -join ';'

        $rows.Add([pscustomobject]$row)
    }
}

# ------------------------------------- self-calibrate adapter LUID -> label
function Get-TopEngine {
    param($Rows, [string]$Unit)
    $agg = @{}
    foreach ($r in ($Rows | Where-Object Compute -eq $Unit)) {
        foreach ($pair in ($r.'_EnginePeaks' -split ';' | Where-Object { $_ })) {
            $k, $v = $pair -split '='
            $d = [double]$v
            if (-not $agg.ContainsKey($k) -or $agg[$k] -lt $d) { $agg[$k] = $d }
        }
    }
    # Ignore the desktop compositor's steady low-single-digit 3d load.
    ($agg.GetEnumerator() | Where-Object { $_.Value -gt 20 } |
        Sort-Object Value -Descending | Select-Object -First 1)
}

$labels = @{}
foreach ($u in @('npu', 'gpu')) {
    $top = Get-TopEngine -Rows $rows -Unit $u
    if ($top) { $labels[$top.Key] = $u.ToUpper() }
}

foreach ($r in $rows) {
    foreach ($pair in ($r.'_EnginePeaks' -split ';' | Where-Object { $_ })) {
        $k, $v = $pair -split '='
        if ($labels.ContainsKey($k)) {
            $r | Add-Member -NotePropertyName "$($labels[$k])_Peak" -NotePropertyValue ([double]$v) -Force
        }
    }
    foreach ($lbl in $labels.Values) {
        if (-not $r.PSObject.Properties[ "${lbl}_Peak" ]) {
            $r | Add-Member -NotePropertyName "${lbl}_Peak" -NotePropertyValue 0 -Force
        }
    }
}

# ------------------------------------------------------------------ output
Write-Host ''
$show = @('Compute', 'Run', 'TokPerSec', 'FirstTokS', 'StartupS', 'Tokens', 'AllCores_Mean')
foreach ($lbl in $labels.Values) { $show += "${lbl}_Peak" }
$rows | Format-Table -AutoSize -Property $show

if ($labels.Count) {
    Write-Host 'Adapter identification (self-calibrated)' -ForegroundColor Cyan
    Write-Host '---------------------------------------'
    foreach ($kv in $labels.GetEnumerator()) {
        Write-Host ("  {0,-6} = adapter luid {1}" -f $kv.Value, $kv.Key)
    }
    Write-Host ''
}

Write-Host 'Summary by compute unit' -ForegroundColor Cyan
Write-Host '-----------------------'
$props = @(
    @{n = 'Compute'; e = { $_.Name } }
    @{n = 'TokPerSec'; e = { [math]::Round(($_.Group | Measure-Object TokPerSec -Average).Average, 1) } }
    @{n = 'FirstTokS'; e = { [math]::Round(($_.Group | Measure-Object FirstTokS -Average).Average, 2) } }
    @{n = 'StartupS'; e = { [math]::Round(($_.Group | Measure-Object StartupS -Average).Average, 2) } }
    @{n = 'CPU%'; e = { [math]::Round(($_.Group | Measure-Object AllCores_Mean -Average).Average, 1) } }
)
foreach ($label in $tierNames) {
    $props += @{ n = "$label%"; e = { [math]::Round(($_.Group | Measure-Object "${label}_Mean" -Average).Average, 1) }.GetNewClosure() }
}
# Peak utilization aggregates by MAX, not mean: a run whose sampling window
# missed the active phase contributes a 0 that would drag an average down.
foreach ($lbl in $labels.Values) {
    $props += @{ n = "${lbl}%"; e = { [math]::Round(($_.Group | Measure-Object "${lbl}_Peak" -Maximum).Maximum, 1) }.GetNewClosure() }
}
($rows | Group-Object Compute | Select-Object $props | Sort-Object TokPerSec -Descending) |
    Format-Table -AutoSize

# ------------------------------------------------------------------- CSV
if (-not $CsvPath) {
    $dir = Join-Path $root '.atlas-local\benchmarks'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $slug = ($Model -replace '[^\w.-]', '_')
    $CsvPath = Join-Path $dir ("{0}-{1}.csv" -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $slug)
}
$rows | Select-Object * -ExcludeProperty '_EnginePeaks' |
    Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
Write-Host ''
Write-Host "Results written to $CsvPath" -ForegroundColor Green
