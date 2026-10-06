<#
.SYNOPSIS
    Report drift and available updates across the Atlas toolchain; optionally apply them.

.DESCRIPTION
    Automates README section 4.6. Reports by default and changes nothing --
    pass -Apply to act. This matches Install-Prerequisites.ps1.

    Three classes of component are tracked, because the things that have
    actually broken this workspace were not all Python packages:

      Python packages   detected and updatable (uv)
      GenieX CLI        detected; update is a manual installer swap
      Drivers and OS    detected ONLY -- never touched by this script

    That last class matters most. Adreno driver 32.0.172.1 broke GenieX GGUF
    inference outright (section 11) and no package manager would have shown
    it. So drift is measured against a recorded baseline rather than against
    "latest": the question answered is "what changed since this last worked",
    which is the one that was hard to answer at the time.

    Updating is also not the same as working. onnxruntime-genai 0.16.0 was
    the current release and was broken for EPContext/QNN models; only running
    the repro caught it. Hence the verification pass.

    The baseline lives in .atlas-local/baseline.json, git-ignored because
    driver versions are per-machine. Seed or refresh it with -Accept, after
    verification passes.

.PARAMETER Apply
    Apply the updates that are safely scriptable. Never touches drivers.

.PARAMETER Accept
    Record the current state as the new baseline.

.PARAMETER SkipVerify
    Skip the post-update verification pass.

.PARAMETER SkipBenchmark
    Run the correctness guards but not the short benchmark.

.EXAMPLE
    .\Scripts\Update-Workspace.ps1

.EXAMPLE
    .\Scripts\Update-Workspace.ps1 -Apply

.EXAMPLE
    .\Scripts\Update-Workspace.ps1 -Accept
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Accept,
    [switch]$SkipVerify,
    [switch]$SkipBenchmark
)

$ErrorActionPreference = 'Continue'
$root         = Split-Path $PSScriptRoot -Parent
$venvPy       = Join-Path $root '.venv\Scripts\python.exe'
$baselinePath = Join-Path $root '.atlas-local\baseline.json'

# ----------------------------------------------------------------- observe

$NotDetected = 'NOT DETECTED'

function Get-CurrentState {
    $state = [ordered]@{ recorded = (Get-Date -Format 's') }

    # Matched by device name, which on this machine resolves to
    # "Qualcomm(R) Adreno(TM) X2-85 GPU" and
    # "Snapdragon(R) X2 Elite - X2E78100 - Qualcomm(R) Hexagon(TM) NPU".
    # If a rename ever breaks the match, record NOT DETECTED rather than a
    # null: a null would read as "(none)" in both columns and compare equal,
    # so a driver change would go silently unnoticed -- the exact failure this
    # script exists to catch.
    $drivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue
    $adreno = $drivers | Where-Object { $_.DeviceName -match 'Adreno' }          | Select-Object -First 1
    $npu    = $drivers | Where-Object { $_.DeviceName -match 'Hexagon|NPU' } | Select-Object -First 1
    $state.drivers = [ordered]@{
        adreno = if ($adreno) { $adreno.DriverVersion } else { $script:NotDetected }
        npu    = if ($npu)    { $npu.DriverVersion }    else { $script:NotDetected }
    }
    $state.os = (Get-CimInstance Win32_OperatingSystem).BuildNumber

    # `geniex version` loads the llama.cpp plugin, so it can crash outright
    # while the rest of the CLI works. Record that as a value, not an error:
    # a version call that started failing is itself the signal.
    $gxVersion = 'not installed'
    $gxHash    = $null
    if (Get-Command geniex -ErrorAction SilentlyContinue) {
        $raw = (geniex version 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
        if ($raw -match 'Version:\s*(\S+)') { $gxVersion = $Matches[1] }
        else                                { $gxVersion = 'version call failed' }
        if ($raw -match 'LlamaCPP Runtime Hash:\s*(\S+)') { $gxHash = $Matches[1] }
    }
    $state.geniex = [ordered]@{ version = $gxVersion; llamacpp = $gxHash }

    $packages = [ordered]@{}
    if (Test-Path $venvPy) {
        foreach ($mod in @('onnxruntime', 'onnxruntime_genai', 'onnxruntime_qnn')) {
            $v = & $venvPy -c "import $mod,sys; sys.stdout.write(getattr($mod,'__version__','?'))" 2>$null
            if ($v) { $packages[$mod] = "$v".Trim() }
        }
    }
    $state.packages = $packages

    $state
}

function New-DriftRow {
    param([string]$Name, $Was, $Now, [string]$Updatable)
    $wasText = if ($null -ne $Was -and "$Was".Trim()) { "$Was" } else { '(none)' }
    $nowText = if ($null -ne $Now -and "$Now".Trim()) { "$Now" } else { '(none)' }
    # Appearing and disappearing both count as drift. Only "absent in both"
    # is unchanged -- requiring both sides to be present would hide a
    # component that vanished between runs.
    $changed = ($wasText -ne $nowText) -and -not ($wasText -eq '(none)' -and $nowText -eq '(none)')
    [pscustomobject]@{
        Component = $Name
        Baseline  = $wasText
        Current   = $nowText
        Changed   = [bool]$changed
        Updatable = $Updatable
    }
}

function Compare-Against {
    param($Current, $Baseline)

    $rows = [System.Collections.Generic.List[object]]::new()
    $rows.Add((New-DriftRow 'Adreno driver' $Baseline.drivers.adreno   $Current.drivers.adreno   'detect only'))
    $rows.Add((New-DriftRow 'NPU driver'    $Baseline.drivers.npu      $Current.drivers.npu      'detect only'))
    $rows.Add((New-DriftRow 'Windows build' $Baseline.os               $Current.os               'detect only'))
    $rows.Add((New-DriftRow 'GenieX'        $Baseline.geniex.version   $Current.geniex.version   'installer'))
    $rows.Add((New-DriftRow 'llama.cpp'     $Baseline.geniex.llamacpp  $Current.geniex.llamacpp  'with GenieX'))

    # Union of both key sets, so a package that was added or removed still
    # shows up rather than silently vanishing from the comparison.
    $names = @($Current.packages.Keys) + @($Baseline.packages.PSObject.Properties.Name) |
             Select-Object -Unique
    foreach ($n in $names) {
        $rows.Add((New-DriftRow $n $Baseline.packages.$n $Current.packages.$n 'uv'))
    }

    $rows
}

function Get-LatestGeniexTag {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }
    $tag = gh release list --repo qualcomm/GenieX --limit 1 --json tagName --jq '.[0].tagName' 2>$null
    if ($LASTEXITCODE -eq 0 -and $tag) { return "$tag".Trim() }
    $null
}

# -------------------------------------------------------------------- main

$mode = if ($Apply) { 'APPLY' } elseif ($Accept) { 'ACCEPT baseline' } else { 'report only' }
Write-Host 'Atlas workspace update' -ForegroundColor Cyan
Write-Host "mode: $mode"
Write-Host ''

$current = Get-CurrentState

if (-not (Test-Path $baselinePath)) {
    Write-Host 'No baseline recorded yet.' -ForegroundColor Yellow
    Write-Host ''
    ($current | ConvertTo-Json -Depth 6)
    Write-Host ''
    if ($Accept -or $Apply) {
        New-Item -ItemType Directory -Force -Path (Split-Path $baselinePath) | Out-Null
        $current | ConvertTo-Json -Depth 6 | Set-Content $baselinePath -Encoding UTF8
        Write-Host "Baseline written to $baselinePath" -ForegroundColor Green
    }
    else {
        Write-Host 'Run with -Accept to record this as the baseline.'
    }
    exit 0
}

$baseline = Get-Content $baselinePath -Raw | ConvertFrom-Json
Write-Host "baseline recorded: $($baseline.recorded)"
Write-Host ''

$rows = Compare-Against -Current $current -Baseline $baseline
$rows | Format-Table -AutoSize -Property Component, Baseline, Current, Changed, Updatable |
        Out-String | Write-Host

$undetected = @($rows | Where-Object {
    $_.Updatable -eq 'detect only' -and ($_.Current -eq $NotDetected -or $_.Current -eq '(none)')
})
if ($undetected.Count -gt 0) {
    Write-Host 'WARNING: a driver could not be identified:' -ForegroundColor Red
    foreach ($u in $undetected) { Write-Host ("  {0}" -f $u.Component) -ForegroundColor Red }
    Write-Host 'The device-name match in Get-CurrentState needs updating. Until then'  -ForegroundColor Red
    Write-Host 'this script cannot tell you whether that driver changed, which is the' -ForegroundColor Red
    Write-Host 'one thing it is here to do. Check manually:'                           -ForegroundColor Red
    Write-Host '  Get-CimInstance Win32_PnPSignedDriver |'                             -ForegroundColor DarkGray
    Write-Host '    Where-Object { $_.DeviceName -match ''Qualcomm|Snapdragon'' } |'      -ForegroundColor DarkGray
    Write-Host '    Select-Object DeviceName, DriverVersion'                              -ForegroundColor DarkGray
    Write-Host ''
}

$drifted = @($rows | Where-Object { $_.Changed })
if ($drifted.Count -gt 0) {
    Write-Host "$($drifted.Count) component(s) changed since the baseline:" -ForegroundColor Yellow
    foreach ($d in $drifted) {
        Write-Host ("  {0}: {1} -> {2}" -f $d.Component, $d.Baseline, $d.Current)
    }
    if (@($drifted | Where-Object { $_.Updatable -eq 'detect only' }).Count -gt 0) {
        Write-Host ''
        Write-Host 'A driver or OS version changed. That class of change has broken this' -ForegroundColor Yellow
        Write-Host 'workspace before with no package changing -- verify before assuming a' -ForegroundColor Yellow
        Write-Host 'new failure is your own code.' -ForegroundColor Yellow
    }
}
else {
    Write-Host 'No drift from baseline.' -ForegroundColor Green
}

# -------------------------------------------------------- available updates

Write-Host ''
Write-Host 'Available updates' -ForegroundColor Cyan
Write-Host '-----------------'

$latestGx = Get-LatestGeniexTag
if ($latestGx) {
    $note = if ($current.geniex.version -eq $latestGx) { '(current)' } else { '<-- newer available' }
    Write-Host ("  GenieX   installed {0}, latest {1}  {2}" -f $current.geniex.version, $latestGx, $note)
}
else {
    Write-Host '  GenieX   could not query releases (is gh installed and authenticated?)'
}

if (Test-Path $venvPy) {
    Write-Host '  Python packages:'
    Push-Location $root
    # Drop uv's rule line, and drop the local project: `atlas` resolves to an
    # unrelated PyPI package of the same name, so it always reports as
    # outdated and upgrading it would install a stranger's code.
    $outdated = @((uv pip list --outdated 2>$null | Out-String) -split "`r?`n" |
                  Where-Object { $_.Trim() -and $_ -notmatch '^[\s-]+$' -and $_ -notmatch '^atlas\s' })
    Pop-Location
    if ($outdated.Count -gt 1) { $outdated | ForEach-Object { Write-Host ('    ' + $_.TrimEnd()) } }
    else                       { Write-Host '    all current' }
}

# ------------------------------------------------------------------- apply

if ($Apply) {
    Write-Host ''
    Write-Host 'Applying' -ForegroundColor Cyan
    Write-Host '--------'
    Write-Host '  uv sync --upgrade'
    Push-Location $root
    uv sync --upgrade 2>&1 | Select-Object -Last 5 | ForEach-Object { Write-Host ('    ' + $_) }
    Pop-Location

    Write-Host ''
    Write-Host '  GenieX is not updated automatically: it is a signed-installer swap, and' -ForegroundColor DarkGray
    Write-Host '  a version change has altered measured behaviour before (section 9.2).' -ForegroundColor DarkGray
    Write-Host '  To update it deliberately:' -ForegroundColor DarkGray
    Write-Host '    gh release download <tag> --repo qualcomm/GenieX --pattern "*windows-arm64*.exe"' -ForegroundColor DarkGray
    Write-Host '  Drivers are never touched by this script.' -ForegroundColor DarkGray
}

# ------------------------------------------------------------------ verify

if (-not $SkipVerify) {
    Write-Host ''
    Write-Host 'Verification' -ForegroundColor Cyan
    Write-Host '------------'

    # Write-Host writes to the information stream, which `| Out-Null` does
    # not capture. Only `*> $null` silences it.
    & (Join-Path $PSScriptRoot 'Test-Environment.ps1') *> $null
    $envRc = $LASTEXITCODE
    $envMsg = if ($envRc -eq 0) { 'PASS' } else { "FAIL ($envRc check(s))" }
    Write-Host "  Test-Environment.ps1      $envMsg"

    # Regression guard for the onnxruntime-genai 0.16 class of breakage: a
    # current version number that cannot actually run an EPContext model.
    $reproModel = Join-Path $root 'models\Phi-4-mini-reasoning-onnx\npu\qnn-int4\genai_config.json'
    if ((Test-Path $venvPy) -and (Test-Path $reproModel)) {
        Push-Location (Join-Path $root 'models')
        & $venvPy (Join-Path $root 'src\setup\repro_genai_016_qnn.py') *> $null
        $reproRc = $LASTEXITCODE
        Pop-Location
        $reproMsg = if ($reproRc -eq 0) { 'PASS' } else { 'FAIL - EPContext/QNN model cannot generate' }
        Write-Host "  repro_genai_016_qnn.py    $reproMsg"
    }
    else {
        Write-Host '  repro_genai_016_qnn.py    skipped (model not downloaded)'
    }

    if (-not $SkipBenchmark) {
        $model = 'unsloth/Qwen3-1.7B-GGUF:Q4_0'
        Write-Host "  short benchmark on $model ..."
        $out = (& geniex infer $model -p 'Explain what an NPU is.' `
                    --max-tokens 128 --compute npu --think=false 2>&1 | Out-String) `
               -replace '\x1b\[[0-9;]*m', ''
        # Combined pattern: a lone `(\d+)\s*tok\b` happily matches the "5 tok"
        # inside "60.5 tok/s".
        if ($out -match '([\d.]+)\s*tok/s\D+?(\d+)\s*tok\b\D+?([\d.]+)\s*s\s*first token') {
            Write-Host ("  benchmark                 {0} tok/s, first token {1}s" -f $Matches[1], $Matches[3])
            Write-Host '  Smoke test only. geniex rounds first-token to 0.1s, so a warm' -ForegroundColor DarkGray
            Write-Host '  short prompt reads 0.0s. For numbers comparable to section 9.2,' -ForegroundColor DarkGray
            Write-Host '  run .\Scripts\Invoke-Benchmark.ps1.' -ForegroundColor DarkGray
        }
        else {
            Write-Host '  benchmark                 FAIL - no tokens generated'
            Write-Host '  Reproduce it directly to see the error:' -ForegroundColor DarkGray
            Write-Host "    geniex infer $model -p 'hi' --max-tokens 8 --think=false" -ForegroundColor DarkGray
        }
    }
}

# ------------------------------------------------------------------ accept

if ($Accept) {
    New-Item -ItemType Directory -Force -Path (Split-Path $baselinePath) | Out-Null
    $current | ConvertTo-Json -Depth 6 | Set-Content $baselinePath -Encoding UTF8
    Write-Host ''
    Write-Host "Baseline updated: $baselinePath" -ForegroundColor Green
}
elseif ($drifted.Count -gt 0) {
    Write-Host ''
    Write-Host 'Run with -Accept once verification passes to record the new baseline.' -ForegroundColor DarkGray
}
