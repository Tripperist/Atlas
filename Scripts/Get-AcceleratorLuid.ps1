<#
.SYNOPSIS
    Identify which GPU Engine adapter LUID is the NPU and which is the GPU.

.DESCRIPTION
    The Hexagon NPU is measured through the ordinary `GPU Engine` counter set
    under its own adapter LUID (README section 7). Those LUIDs are **assigned
    per boot** and move on reboot or driver re-enumeration, so a value recorded
    in a previous session will silently read zero later. Three different NPU
    LUIDs have been observed on this machine across reboots.

    This re-derives the mapping empirically rather than trusting a recorded id.

    Two modes:

      Full (default) drives a GGUF model with `--compute npu`, `gpu` and `cpu`
      in turn and reports which adapter lights up for each. This separates the
      NPU from the GPU, but needs a working GGUF/llama.cpp path.

      -UseQairt drives a QAIRT bundle, which is NPU-targeted by construction.
      It identifies the NPU only -- `--compute` is a no-op for QAIRT bundles --
      but works when GGUF inference is unavailable.

    All output is emitted as a single stream at the end rather than via
    Write-Host, so it stays ordered when captured or redirected.

.PARAMETER Model
    Model to probe with. Must be a GGUF unless -UseQairt is set.

.PARAMETER UseQairt
    Probe with a QAIRT bundle instead. Identifies the NPU only.

.PARAMETER MaxTokens
    Tokens per probe run; enough to keep the accelerator busy while sampling.

.EXAMPLE
    .\Scripts\Get-AcceleratorLuid.ps1

.EXAMPLE
    .\Scripts\Get-AcceleratorLuid.ps1 -UseQairt -Model "qualcomm/Qwen3-4B:W4A16"
#>
[CmdletBinding()]
param(
    [string]$Model,
    [switch]$UseQairt,
    [int]$MaxTokens = 300,
    # The probe needs the run to last longer than a couple of counter samples
    # (each Get-Counter call costs ~1s). A prompt that stops early leaves too
    # few samples to catch the accelerator, which looks like an idle adapter.
    [string]$Prompt = 'Write a long, detailed essay about the history of maritime navigation. Cover early Polynesian wayfinding, the astrolabe, the marine chronometer, and satellite positioning. Use several paragraphs for each.'
)

$ErrorActionPreference = 'Continue'
$report = [System.Collections.Generic.List[string]]::new()
function Add-Line { param([string]$Text = '') $script:report.Add($Text) }

if (-not (Get-Command geniex -ErrorAction SilentlyContinue)) {
    Write-Error 'geniex not found on PATH. See README section 4.2.'
    exit 1
}

if (-not $Model) {
    $Model = if ($UseQairt) { 'qualcomm/Qwen3-4B:W4A16' } else { 'unsloth/Qwen3-1.7B-GGUF:Q4_0' }
}

function Measure-Unit {
    param([string]$Unit)

    $cmdArgs = @('infer', $Model, '-p', $Prompt,
                 '--max-tokens', "$MaxTokens", '--think=false')
    if ($Unit) { $cmdArgs += @('--compute', $Unit) }

    $outFile = [System.IO.Path]::GetTempFileName()
    $job = Start-Job {
        # Copy to locals first: `@using:var` is not valid splatting syntax and
        # `$using:` is not valid as a redirection target. Both fail quietly.
        $a = $using:cmdArgs
        $f = $using:outFile
        & geniex @a 2>&1 | Out-File -FilePath $f -Encoding UTF8
        $LASTEXITCODE
    }

    # Wildcards re-expand per call, so instances created by the inference
    # process after this loop starts are still captured.
    $peak = @{}
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($job.State -eq 'Running') {
        try {
            $samples = (Get-Counter '\GPU Engine(*)\Utilization Percentage' -EA Stop).CounterSamples |
                       Where-Object { $_.CookedValue -gt 5 }
            foreach ($c in $samples) {
                if ($c.Path -match 'luid_[0-9a-fx]+_(0x[0-9a-f]+)_.*engtype_(\w+)') {
                    $key = "$($Matches[1])/$($Matches[2])"
                    $val = [math]::Min($c.CookedValue, 100)
                    if (-not $peak.ContainsKey($key) -or $peak[$key] -lt $val) {
                        $peak[$key] = [math]::Round($val, 1)
                    }
                }
            }
        }
        catch { }
        if ($sw.Elapsed.TotalSeconds -gt 240) { break }
    }
    Wait-Job $job -Timeout 120 | Out-Null
    $exit = Receive-Job $job | Select-Object -Last 1
    Remove-Job $job -Force
    $sw.Stop()

    $text = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
    Remove-Item -LiteralPath $outFile -ErrorAction SilentlyContinue

    # A crashed run produces no tokens, so an empty counter set would otherwise
    # look like "the accelerator was idle" rather than "nothing ran".
    $ran = $text -match '([\d.]+)\s*tok/s'
    $rate = if ($ran) { [double]$Matches[1] } else { $null }
    $clean = ($text -replace '[^\x20-\x7E]', '').Trim()

    $top = $peak.GetEnumerator() | Sort-Object Value -Descending | Select-Object -First 1
    [pscustomobject]@{
        Compute = if ($Unit) { $Unit } else { '(default)' }
        Ran     = $ran
        TokPerS = $rate
        Busiest = if ($top) { $top.Key } else { '-' }
        Peak    = if ($top) { "$($top.Value)%" } else { '-' }
        Seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1)
        Exit    = $exit
        Tail    = if ($clean) { $clean.Substring([Math]::Max(0, $clean.Length - 120)) } else { '(no output)' }
    }
}

Add-Line "Model : $Model"
Add-Line "Mode  : $(if ($UseQairt) { 'QAIRT (identifies NPU only)' } else { 'GGUF (separates NPU/GPU/CPU)' })"
Add-Line

# No warm-up run: starting a second geniex process while the previous one may
# still hold the NPU context is a known source of fail-fast crashes.
$units = if ($UseQairt) { @('') } else { @('npu', 'gpu', 'cpu') }
$results = foreach ($u in $units) { Measure-Unit $u }

Add-Line (($results | Format-Table -AutoSize -Property Compute, Ran, TokPerS, Busiest, Peak, Seconds, Exit |
           Out-String).TrimEnd())
Add-Line

$short = @($results | Where-Object { $_.Ran -and $_.Seconds -lt 6 -and $_.Busiest -eq '-' })
if ($short.Count) {
    Add-Line 'NOTE: some runs finished in under 6s with no adapter seen. Each counter'
    Add-Line 'query costs about a second, so a short run yields too few samples to'
    Add-Line 'catch the accelerator. Raise -MaxTokens, or pass a -Prompt that keeps'
    Add-Line 'the model generating for longer.'
    Add-Line
}

$failed = @($results | Where-Object { -not $_.Ran })
if ($failed.Count -eq $results.Count) {
    Add-Line 'No probe run produced tokens, so these counters say nothing about'
    Add-Line 'placement. geniex output from the last attempt:'
    Add-Line "  $(($results | Select-Object -Last 1).Tail)"
    Add-Line
    Add-Line 'Exit -1073740791 (0xC0000409) is a hard crash. Check it runs at all:'
    Add-Line "  geniex infer $Model -p 'hi' --max-tokens 8 --think=false"
    if (-not $UseQairt) {
        Add-Line 'If GGUF inference is broken, retry with -UseQairt to at least'
        Add-Line 'identify the NPU.'
    }
    $report -join [Environment]::NewLine
    exit 1
}

Add-Line 'Derived mapping'
Add-Line '---------------'
if ($UseQairt) {
    Add-Line "  NPU = $(($results | Select-Object -First 1).Busiest)"
    Add-Line '  GPU = not determined (QAIRT mode cannot separate the units)'
}
else {
    $npu = ($results | Where-Object Compute -eq 'npu').Busiest
    $gpu = ($results | Where-Object Compute -eq 'gpu').Busiest
    Add-Line "  NPU = $npu"
    Add-Line "  GPU = $gpu"
    if ($npu -eq $gpu) {
        Add-Line
        Add-Line 'WARNING: npu and gpu runs lit the same adapter. Either --compute is'
        Add-Line 'being ignored (a QAIRT bundle rather than GGUF?) or the probe is'
        Add-Line 'reading background activity.'
    }
}
Add-Line
Add-Line 'LUIDs change on reboot. Re-run this rather than reusing the values.'

$report -join [Environment]::NewLine
