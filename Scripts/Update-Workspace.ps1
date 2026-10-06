<#
.SYNOPSIS
    Report drift and available updates across the Atlas toolchain; optionally apply them.

.DESCRIPTION
    Automates README section 4.6. Reports by default and changes nothing --
    pass -Apply to act. This matches Install-Prerequisites.ps1.

    Three classes of component are tracked, because the things that have
    actually broken this workspace were not all Python packages:

      Python packages   detected; updated by -Apply via uv
      GenieX CLI        detected; updated by -Apply via the signed installer
      Drivers and OS    detected ONLY -- never touched by this script

    That last class matters most. Adreno driver 32.0.172.1 broke GenieX GGUF
    inference outright (section 12) and no package manager would have shown
    it. So drift is measured against a recorded baseline rather than against
    "latest", and the question answered is "what changed since this last
    worked", which is the one that was hard to answer at the time.

    Updating is also not the same as working. onnxruntime-genai 0.16.0 was
    the current release and was broken for EPContext/QNN models; only running
    the repro caught it. Hence the verification pass.

    Every benchmark run is appended to .atlas-local/benchmarks/history.jsonl,
    stamped with a short hash of the stack it ran under, so results measured
    under different drivers or runtimes are never silently compared. See
    -History.

    The baseline lives in .atlas-local/baseline.json, git-ignored because
    driver versions are per-machine. Seed or refresh it with -Accept, after
    verification passes.

.PARAMETER Apply
    Apply available updates: Python packages via uv, and GenieX via its signed
    installer. Drivers are never touched.

.PARAMETER Accept
    Record the current state as the new baseline.

.PARAMETER SkipGeniex
    With -Apply, update Python packages but leave GenieX alone.

.PARAMETER SkipVerify
    Skip the post-update verification pass.

.PARAMETER SkipBenchmark
    Run the correctness guards but not the short benchmark.

.PARAMETER History
    Print recorded benchmark history grouped by stack, and exit.

.EXAMPLE
    .\Scripts\Update-Workspace.ps1

.EXAMPLE
    .\Scripts\Update-Workspace.ps1 -Apply

.EXAMPLE
    .\Scripts\Update-Workspace.ps1 -History
#>
[CmdletBinding()]
param(
    [switch]$Apply,
    [switch]$Accept,
    [switch]$SkipGeniex,
    [switch]$SkipVerify,
    [switch]$SkipBenchmark,
    [switch]$History
)

$ErrorActionPreference = 'Continue'
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force

$root         = Get-AtlasRoot
$venvPy       = Join-Path $root '.venv\Scripts\python.exe'
$baselinePath = Get-AtlasBaselinePath
$NotDetected  = 'NOT DETECTED'

# ------------------------------------------------------------------ history

if ($History) {
    $records = @(Get-AtlasBenchmarkHistory)
    if ($records.Count -eq 0) {
        Write-Host "No benchmark history yet at $(Get-AtlasHistoryPath)."
        Write-Host 'It is written by Update-Workspace.ps1 and Invoke-Benchmark.ps1.'
        exit 0
    }
    Write-Host "Benchmark history ($($records.Count) record(s))" -ForegroundColor Cyan
    Write-Host "from $(Get-AtlasHistoryPath)"
    $currentId = Get-AtlasShortId (Get-AtlasStateId (Get-AtlasState))
    foreach ($g in ($records | Group-Object stateId | Sort-Object { $_.Group[0].ts })) {
        $s = $g.Group[0].state
        $marker = if ($g.Name -eq $currentId) { '  <-- current stack' } else { '' }
        Write-Host ''
        Write-Host ("stack {0}{1}" -f $g.Name, $marker) -ForegroundColor Yellow
        Write-Host ("  adreno {0} | npu {1} | os {2} | geniex {3} | llama.cpp {4}" -f `
            $s.drivers.adreno, $s.drivers.npu, $s.os, $s.geniex.version, $s.geniex.llamacpp)
        $g.Group |
            Sort-Object ts |
            Select-Object @{n = 'when';     e = { ([datetime]$_.ts).ToString('yyyy-MM-dd HH:mm') } },
                          @{n = 'model';    e = { $_.model } },
                          @{n = 'compute';  e = { $_.compute } },
                          @{n = 'tok/s';    e = { $_.tokPerSec } },
                          @{n = 'firstTok'; e = { $_.firstTokenS } },
                          @{n = 'source';   e = { $_.source } } |
            Format-Table -AutoSize | Out-String | Write-Host
    }
    Write-Host 'Numbers measured under different stacks are not directly comparable.' -ForegroundColor DarkGray
    exit 0
}

# -------------------------------------------------------------------- drift

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

# ------------------------------------------------------------------- geniex

function Get-LatestGeniexTag {
    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) { return $null }
    $tag = gh release list --repo qualcomm/GenieX --limit 1 --json tagName --jq '.[0].tagName' 2>$null
    if ($LASTEXITCODE -eq 0 -and $tag) { return "$tag".Trim() }
    $null
}

<#
.SYNOPSIS
    Download, hash-verify and silently install a GenieX CLI release.

.DESCRIPTION
    The Windows ARM64 asset is an Inno Setup installer that installs per-user
    into %LOCALAPPDATA%\GenieX CLI, so no elevation is required.

    The published .sha256 is always checked. "A corrupted installation" was
    one of the candidates eliminated by hand during the GGUF crash
    investigation (section 12); verifying here rules it out by construction
    next time.
#>
function Install-Geniex {
    param([Parameter(Mandatory)][string]$Tag)

    if (-not (Get-Command gh -ErrorAction SilentlyContinue)) {
        Write-Host '    gh not available; cannot download the release.' -ForegroundColor Red
        return $false
    }
    # The installer replaces DLLs that a running CLI holds open.
    $busy = Get-Process -Name 'geniex*' -ErrorAction SilentlyContinue
    if ($busy) {
        Write-Host '    A geniex process is running; close it first:' -ForegroundColor Red
        $busy | ForEach-Object { Write-Host ("      PID {0}  {1}" -f $_.Id, $_.ProcessName) -ForegroundColor Red }
        return $false
    }

    $asset   = "geniex-cli-setup-windows-arm64-$Tag.exe"
    $staging = Join-Path ([System.IO.Path]::GetTempPath()) "atlas-geniex-$Tag"
    New-Item -ItemType Directory -Force -Path $staging | Out-Null

    Write-Host "    downloading $asset ..."
    gh release download $Tag --repo qualcomm/GenieX `
        --pattern $asset --pattern "$asset.sha256" --dir $staging --clobber 2>&1 |
        ForEach-Object { Write-Host "      $_" }

    $exePath = Join-Path $staging $asset
    $shaPath = "$exePath.sha256"
    if (-not (Test-Path $exePath)) {
        Write-Host "    download failed: $asset not found in $staging" -ForegroundColor Red
        return $false
    }

    if (Test-Path $shaPath) {
        # The file is "<hash>  <name>"; take the first field.
        $expected = ((Get-Content $shaPath -Raw).Trim() -split '\s+')[0].ToLower()
        $actual   = (Get-FileHash $exePath -Algorithm SHA256).Hash.ToLower()
        if ($expected -ne $actual) {
            Write-Host '    SHA256 MISMATCH -- refusing to install.' -ForegroundColor Red
            Write-Host "      expected $expected" -ForegroundColor Red
            Write-Host "      actual   $actual"   -ForegroundColor Red
            return $false
        }
        Write-Host '    sha256 verified'
    }
    else {
        Write-Host '    no .sha256 published for this asset; skipping verification.' -ForegroundColor Yellow
    }

    Write-Host '    running installer (silent) ...'
    $p = Start-Process -FilePath $exePath `
        -ArgumentList '/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART', '/NOCANCEL' `
        -Wait -PassThru
    if ($p.ExitCode -ne 0) {
        Write-Host "    installer exited $($p.ExitCode)" -ForegroundColor Red
        return $false
    }

    # This process inherited its PATH at launch, so a freshly installed exe
    # may not resolve by name here even though it will in a new shell.
    $installed = Join-Path $env:LOCALAPPDATA 'GenieX CLI\geniex.exe'
    if (Test-Path $installed) {
        $raw = (& $installed version 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
        if ($raw -match 'Version:\s*(\S+)') {
            Write-Host "    installed $($Matches[1])" -ForegroundColor Green
        }
    }
    Remove-Item $staging -Recurse -Force -ErrorAction SilentlyContinue
    $true
}

# --------------------------------------------------------------------- main

$mode = if ($Apply) { 'APPLY' } elseif ($Accept) { 'ACCEPT baseline' } else { 'report only' }
Write-Host 'Atlas workspace update' -ForegroundColor Cyan
Write-Host "mode: $mode"
Write-Host ''

$current = Get-AtlasState
Write-Host ("current stack: {0}" -f (Get-AtlasShortId $current.id))

if (-not (Test-Path $baselinePath)) {
    Write-Host 'No baseline recorded yet.' -ForegroundColor Yellow
    Write-Host ''
    ($current | ConvertTo-Json -Depth 6)
    Write-Host ''
    if ($Accept -or $Apply) {
        Write-AtlasBaseline $current
        Write-Host "Baseline written to $baselinePath" -ForegroundColor Green
    }
    else {
        Write-Host 'Run with -Accept to record this as the baseline.'
    }
    exit 0
}

$baseline = Read-AtlasBaseline
Write-Host ("baseline     : {0}  recorded {1}" -f (Get-AtlasShortId (Get-AtlasStateId $baseline)), $baseline.recorded)
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
    Write-Host 'The device-name match in Get-AtlasState needs updating. Until then'    -ForegroundColor Red
    Write-Host 'this script cannot tell you whether that driver changed, which is the' -ForegroundColor Red
    Write-Host 'one thing it is here to do. Check manually:'                           -ForegroundColor Red
    Write-Host '  Get-CimInstance Win32_PnPSignedDriver |'                             -ForegroundColor DarkGray
    Write-Host '    Where-Object { $_.DeviceName -match ''Qualcomm|Snapdragon'' } |'   -ForegroundColor DarkGray
    Write-Host '    Select-Object DeviceName, DriverVersion'                           -ForegroundColor DarkGray
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

# ---------------------------------------------------------- available updates

Write-Host ''
Write-Host 'Available updates' -ForegroundColor Cyan
Write-Host '-----------------'

$latestGx = Get-LatestGeniexTag
$gxOutdated = $false
if ($latestGx) {
    $gxOutdated = ($current.geniex.version -ne $latestGx)
    $note = if ($gxOutdated) { '<-- newer available' } else { '(current)' }
    Write-Host ("  GenieX   installed {0}, latest {1}  {2}" -f $current.geniex.version, $latestGx, $note)
}
else {
    Write-Host '  GenieX   could not query releases (is gh installed and authenticated?)'
}

if (Test-Path $venvPy) {
    Write-Host '  Python packages:'
    # Run this from a directory with no pyproject.toml and point uv at the venv
    # explicitly. Invoked inside the project, `uv pip list --outdated` can
    # auto-sync it: on first use here it upgraded qai-hub, qai-hub-models-cli,
    # onnx, botocore and wcwidth in the venv and rewrote uv.lock. That is
    # unacceptable for a command whose contract is to report and change
    # nothing. A neutral working directory gives uv no project to act on.
    $lockPath   = Join-Path $root 'uv.lock'
    $lockBefore = if (Test-Path $lockPath) { (Get-FileHash $lockPath -Algorithm SHA256).Hash } else { $null }
    Push-Location ([System.IO.Path]::GetTempPath())
    try   { $raw = (uv pip list --outdated --python $venvPy 2>$null | Out-String) }
    finally { Pop-Location }

    # Belt and braces: if a future uv finds a way to touch the lock anyway,
    # say so rather than leaving the venv and the lock quietly out of step.
    if ($lockBefore -and (Get-FileHash $lockPath -Algorithm SHA256).Hash -ne $lockBefore) {
        Write-Host '    WARNING: uv.lock changed during a read-only check.' -ForegroundColor Yellow
        Write-Host '    Inspect with: git diff uv.lock' -ForegroundColor Yellow
        Write-Host '    Realign the environment with: uv sync' -ForegroundColor Yellow
    }

    # Drop uv's banner and rule lines, and the local project: `atlas` resolves
    # to an unrelated PyPI package of the same name, so it always reports as
    # outdated and upgrading it would install a stranger's code.
    $outdated = @($raw -split "`r?`n" | Where-Object {
        $_.Trim() -and $_ -notmatch '^[\s-]+$' -and $_ -notmatch '^atlas\s' -and $_ -notmatch '^Using Python'
    })
    if ($outdated.Count -gt 1) {
        $outdated | ForEach-Object { Write-Host ('    ' + $_.TrimEnd()) }
        # uv compares against the latest on PyPI regardless of constraints, so
        # some of these cannot move: protobuf stays on 6.x because onnx pins it.
        # Without this note a run after -Apply looks like the upgrade failed.
        Write-Host '    Some of these are held back by dependency constraints and will' -ForegroundColor DarkGray
        Write-Host '    remain listed after -Apply. That is uv reporting PyPI latest,' -ForegroundColor DarkGray
        Write-Host '    not a failed upgrade.' -ForegroundColor DarkGray
    }
    else { Write-Host '    all current' }
}

# --------------------------------------------------------------------- apply

if ($Apply) {
    Write-Host ''
    Write-Host 'Applying' -ForegroundColor Cyan
    Write-Host '--------'

    Write-Host '  uv sync --upgrade'
    Push-Location $root
    uv sync --upgrade 2>&1 | Select-Object -Last 5 | ForEach-Object { Write-Host ('    ' + $_) }
    Pop-Location

    if ($SkipGeniex) {
        Write-Host '  GenieX: skipped (-SkipGeniex)'
    }
    elseif (-not $latestGx) {
        Write-Host '  GenieX: skipped (latest release unknown)'
    }
    elseif (-not $gxOutdated) {
        Write-Host "  GenieX: already $latestGx"
    }
    else {
        Write-Host "  GenieX $($current.geniex.version) -> $latestGx"
        if (Install-Geniex -Tag $latestGx) {
            # The stack changed, so re-read it: anything measured below must be
            # stamped with what actually ran, not with the pre-update state.
            $current = Get-AtlasState
            Write-Host ("  stack is now {0}" -f (Get-AtlasShortId $current.id))
        }
    }

    Write-Host ''
    Write-Host '  Drivers are never touched by this script.' -ForegroundColor DarkGray
}

# -------------------------------------------------------------------- verify

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
        $gxExe = Join-Path $env:LOCALAPPDATA 'GenieX CLI\geniex.exe'
        if (-not (Test-Path $gxExe)) { $gxExe = 'geniex' }
        $out = (& $gxExe infer $model -p 'Explain what an NPU is.' `
                    --max-tokens 128 --compute npu --think=false 2>&1 | Out-String) `
               -replace '\x1b\[[0-9;]*m', ''
        # Combined pattern: a lone `(\d+)\s*tok\b` happily matches the "5 tok"
        # inside "60.5 tok/s".
        if ($out -match '([\d.]+)\s*tok/s\D+?(\d+)\s*tok\b\D+?([\d.]+)\s*s\s*first token') {
            $tps = [double]$Matches[1]; $tok = [int]$Matches[2]; $ftt = [double]$Matches[3]
            Write-Host ("  benchmark                 {0} tok/s, first token {1}s" -f $tps, $ftt)
            Add-AtlasBenchmarkRecord -State $current -Source 'Update-Workspace.ps1' `
                -Model $model -Compute 'npu' -TokPerSec $tps -FirstTokenS $ftt -Tokens $tok | Out-Null
            Write-Host ("  recorded under stack {0}; see -History" -f (Get-AtlasShortId $current.id)) -ForegroundColor DarkGray
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

# -------------------------------------------------------------------- accept

if ($Accept) {
    Write-AtlasBaseline $current
    Write-Host ''
    Write-Host "Baseline updated: $baselinePath" -ForegroundColor Green
    Write-Host ("stack {0}" -f (Get-AtlasShortId $current.id))
}
elseif ($drifted.Count -gt 0 -or $Apply) {
    Write-Host ''
    Write-Host 'Run with -Accept once verification passes to record the new baseline.' -ForegroundColor DarkGray
}
