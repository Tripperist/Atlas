<#
.SYNOPSIS
    Shared workspace-state capture, identity, and benchmark history for Atlas.

.DESCRIPTION
    A benchmark number is meaningless without the stack that produced it. This
    repository learned that twice: an Adreno patch-level driver bump turned a
    hard crash into 131 tok/s (the README "Know your machine" section2), and GenieX v0.8.0 shifted
    one-shot first-token latency without touching throughput (see docs/BENCHMARKS.md).
    Both times the question asked afterwards was "what was installed when that
    number was measured", and the answer had to be reconstructed by hand.

    So state capture lives here rather than in any one script, and every
    benchmark is stamped with a short hash of the state it ran under. Results
    recorded under different stacks are never silently comparable.

    Used by Update-Workspace.ps1 and Invoke-Benchmark.ps1.
#>

Set-StrictMode -Version Latest

$script:NotDetected = 'NOT DETECTED'

function Get-AtlasRoot {
    Split-Path $PSScriptRoot -Parent
}

function Get-AtlasLocalDir {
    $d = Join-Path (Get-AtlasRoot) '.atlas-local'
    if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null }
    $d
}

function Get-AtlasBaselinePath { Join-Path (Get-AtlasLocalDir) 'baseline.json' }
# ATLAS_HISTORY_PATH redirects the history, for tests that must not touch the real one.
function Get-AtlasHistoryPath {
    if ($env:ATLAS_HISTORY_PATH) { return $env:ATLAS_HISTORY_PATH }
    Join-Path (Get-AtlasLocalDir) 'benchmarks\history.jsonl'
}

<#
.SYNOPSIS
    Capture the versions of everything that can change a benchmark result.
#>
function Get-AtlasState {
    [CmdletBinding()]
    param()

    $state = [ordered]@{ recorded = (Get-Date -Format 's') }

    # Matched by device name, which on this machine resolves to
    # "Qualcomm(R) Adreno(TM) X2-85 GPU" and
    # "Snapdragon(R) X2 Elite - X2E78100 - Qualcomm(R) Hexagon(TM) NPU".
    # A missed match records NOT DETECTED rather than a null: a null renders
    # as "(none)" on both sides of a comparison and so compares equal, which
    # would hide a driver change -- the exact failure this is here to catch.
    $drivers = Get-CimInstance Win32_PnPSignedDriver -ErrorAction SilentlyContinue
    $adreno = $drivers | Where-Object { $_.DeviceName -match 'Adreno' }          | Select-Object -First 1
    $npu    = $drivers | Where-Object { $_.DeviceName -match 'Hexagon|\bNPU\b' } | Select-Object -First 1
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
    $gx = Get-Command geniex -ErrorAction SilentlyContinue
    if ($gx) {
        $raw = (geniex version 2>&1 | Out-String) -replace '\x1b\[[0-9;]*m', ''
        if ($raw -match 'Version:\s*(\S+)') { $gxVersion = $Matches[1] }
        else                                { $gxVersion = 'version call failed' }
        if ($raw -match 'LlamaCPP Runtime Hash:\s*(\S+)') { $gxHash = $Matches[1] }
    }
    $state.geniex = [ordered]@{ version = $gxVersion; llamacpp = $gxHash }

    $packages = [ordered]@{}
    $venvPy = Join-Path (Get-AtlasRoot) '.venv\Scripts\python.exe'
    if (Test-Path $venvPy) {
        foreach ($mod in @('onnxruntime', 'onnxruntime_genai', 'onnxruntime_qnn')) {
            $v = & $venvPy -c "import $mod,sys; sys.stdout.write(getattr($mod,'__version__','?'))" 2>$null
            if ($v) { $packages[$mod] = "$v".Trim() }
        }
    }
    $state.packages = $packages

    # Foundry Local is Method E (the README "Foundry Local" section). It is deliberately NOT
    # part of the stack identity below: it is a separate runtime that does not
    # execute GenieX or ORT GenAI work, and folding it into the hash would
    # re-key every existing history record on a machine that had not otherwise
    # changed. It is tracked here so drift is still visible.
    #
    # Revisit that if Foundry's mere presence is ever shown to affect another
    # runtime's numbers -- it would then belong in the identity.
    $foundry = 'not installed'
    if (Get-Command foundry -ErrorAction SilentlyContinue) {
        $raw = (foundry --version 2>&1 | Out-String) -replace '\[[0-9;]*m', ''
        if ($raw -match '(\d+\.\d+\.\d+[\w.-]*)') { $foundry = $Matches[1] }
        else { $foundry = 'installed, version unknown' }
    }
    $state.foundry = $foundry

    $state.id = Get-AtlasStateId $state
    $state
}

<#
.SYNOPSIS
    Short stable hash identifying a stack, ignoring when it was recorded.

.DESCRIPTION
    Built from an explicit field list rather than by hashing the JSON, so it
    accepts both the ordered dictionary Get-AtlasState returns and the
    PSCustomObject that comes back from ConvertFrom-Json, and so adding a
    descriptive field later does not silently invalidate existing history.
#>
function Get-AtlasStateId {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$State)

    function Get-Field($obj, $name) {
        if ($null -eq $obj) { return '' }
        if ($obj -is [System.Collections.IDictionary]) {
            return $(if ($obj.Contains($name)) { "$($obj[$name])" } else { '' })
        }
        $p = $obj.PSObject.Properties[$name]
        return $(if ($p) { "$($p.Value)" } else { '' })
    }

    $drivers = if ($State -is [System.Collections.IDictionary]) { $State['drivers'] } else { $State.drivers }
    $geniex  = if ($State -is [System.Collections.IDictionary]) { $State['geniex'] }  else { $State.geniex }
    $pkgs    = if ($State -is [System.Collections.IDictionary]) { $State['packages'] } else { $State.packages }

    # Deliberately excludes $State.foundry; see Get-AtlasState for why.
    $parts = @(
        "adreno=$(Get-Field $drivers 'adreno')"
        "npu=$(Get-Field $drivers 'npu')"
        "os=$(Get-Field $State 'os')"
        "geniex=$(Get-Field $geniex 'version')"
        "llamacpp=$(Get-Field $geniex 'llamacpp')"
    )
    $names = @()
    if ($null -ne $pkgs) {
        $names = if ($pkgs -is [System.Collections.IDictionary]) { @($pkgs.Keys) }
                 else { @($pkgs.PSObject.Properties.Name) }
    }
    foreach ($n in ($names | Sort-Object)) { $parts += "$n=$(Get-Field $pkgs $n)" }

    $bytes = [System.Text.Encoding]::UTF8.GetBytes(($parts -join ';'))
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try   { ($sha.ComputeHash($bytes) | ForEach-Object { $_.ToString('x2') }) -join '' }
    finally { $sha.Dispose() }
}

function Get-AtlasShortId {
    param([Parameter(Mandatory)][string]$Id)
    $Id.Substring(0, 12)
}

function Read-AtlasBaseline {
    $p = Get-AtlasBaselinePath
    if (-not (Test-Path $p)) { return $null }
    Get-Content $p -Raw | ConvertFrom-Json
}

function Write-AtlasBaseline {
    param([Parameter(Mandatory)]$State)
    $State | ConvertTo-Json -Depth 6 | Set-Content (Get-AtlasBaselinePath) -Encoding UTF8
}

<#
.SYNOPSIS
    Append one benchmark measurement to the history, stamped with its stack.

.DESCRIPTION
    JSON Lines, append-only. A line is never rewritten, so a history file can
    be concatenated or diffed, and a crashed run loses at most its own line.

    The full state snapshot is embedded in each record, not just its id, so
    history stays self-describing after baseline.json is replaced.

    History format 2 (schemaVersion 2) adds, beside the original fields: a stable
    `id`; `kind` (benchmark, control or smoke); `conditions` and `onAcPower`, the
    state the run was made under (AtlasConditions.psm1); `codeRev`, the Atlas
    revision, with +dirty when Scripts, src or evals differ from it; and optional
    n, stdev, reps, order, promptKind, ctxSize, seed, harness, harnessVersion and
    modelArtifact. Fields that do not apply are left out. Older records stay valid
    and read as unknown: the reader fills `n`, `kind`, `valid` and `onAcPower`.
#>
# The conditions the current run was checked under, set by Assert-AtlasConditions
# (it calls Set-AtlasRunConditions if this module is loaded) and stamped on every
# record written afterwards. Held here, with the history, so that reloading
# AtlasConditions.psm1 with -Force cannot orphan it.
$script:RunConditions = $null
$script:CodeRev = $null

function Set-AtlasRunConditions {
    param($Conditions)
    $script:RunConditions = $Conditions
}

function Get-AtlasRunConditions { $script:RunConditions }

# The Atlas revision a run used, with +dirty when the code that makes a measurement
# differs from it. Only Scripts, src and evals count: a changed lock file or a
# document does not change what a harness measures.
function Get-AtlasCodeRev {
    if ($script:CodeRev) { return $script:CodeRev }
    $root = Get-AtlasRoot
    $rev = git -C $root rev-parse --short HEAD 2>$null
    if ($LASTEXITCODE -ne 0 -or -not $rev) { return $null }
    $dirty = git -C $root status --porcelain -- Scripts src evals 2>$null
    $script:CodeRev = if ($dirty) { "$rev+dirty" } else { "$rev" }
    $script:CodeRev
}

function Add-AtlasBenchmarkRecord {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$State,
        [Parameter(Mandatory)][string]$Source,
        [Parameter(Mandatory)][string]$Model,
        [string]$Compute,
        [Nullable[double]]$TokPerSec,
        [Nullable[double]]$FirstTokenS,
        [Nullable[int]]$Tokens,
        # Prefill is a separate axis, not a variant of throughput: short-prompt
        # decode rates hid a 6-9x NPU prefill advantage in this project until
        # the two were measured apart. Records carrying it keep them apart.
        [Nullable[double]]$PrefillTps,
        [Nullable[int]]$PromptTokens,
        [string]$CsvPath,
        [hashtable]$Extra,
        # ---- history format 2
        # smoke records (the check Update-Workspace runs) are never published
        [ValidateSet('benchmark', 'control', 'smoke', 'canary')][string]$Kind = 'benchmark',
        $Conditions,
        [string]$Harness,
        [string]$HarnessVersion,
        # repetitions behind the figure, its spread, and each repetition
        [Nullable[int]]$N,
        [Nullable[double]]$Stdev,
        [double[]]$Reps,
        [string]$Order,
        [string]$PromptKind,
        [Nullable[int]]$CtxSize,
        [Nullable[int]]$Seed,
        $ModelArtifact
    )

    $id = if ($State -is [System.Collections.IDictionary] -and $State.Contains('id')) { $State['id'] }
          elseif ($State.PSObject.Properties['id']) { $State.id }
          else { Get-AtlasStateId $State }
    $short = Get-AtlasShortId $id

    $conditions = if ($PSBoundParameters.ContainsKey('Conditions')) { $Conditions } else { Get-AtlasRunConditions }
    $ts = (Get-Date -Format 'o')
    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $recordId = (($sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes("$ts|$Source|$Model|$Compute|$PromptTokens|$short")) |
                      ForEach-Object { $_.ToString('x2') }) -join '').Substring(0, 12)
    }
    finally { $sha.Dispose() }

    $record = [ordered]@{
        schemaVersion = 2
        id            = $recordId
        ts            = $ts
        stateId       = $short
        kind          = $Kind
        source        = $Source
        model         = $Model
        compute       = $Compute
        tokPerSec     = $TokPerSec
        firstTokenS   = $FirstTokenS
        tokens        = $Tokens
        prefillTps    = $PrefillTps
        promptTokens  = $PromptTokens
        csv           = $CsvPath
        state         = $State
    }
    $optional = [ordered]@{
        harness = $Harness; harnessVersion = $HarnessVersion; n = $N; stdev = $Stdev; reps = $Reps
        order = $Order; promptKind = $PromptKind; ctxSize = $CtxSize; seed = $Seed; modelArtifact = $ModelArtifact
    }
    foreach ($k in $optional.Keys) {
        if ($null -ne $optional[$k] -and -not ($optional[$k] -is [string] -and -not $optional[$k])) { $record[$k] = $optional[$k] }
    }
    # A suite run (Invoke-AtlasBenchSuite.ps1) names itself here, so its records can be found again.
    if ($env:ATLAS_SUITE_RUN) { $record['suiteRun'] = $env:ATLAS_SUITE_RUN }
    $record['onAcPower'] = if ($conditions) { $conditions.onAcPower } else { $null }
    if ($conditions) { $record['conditions'] = $conditions }
    $rev = Get-AtlasCodeRev
    if ($rev) { $record['codeRev'] = $rev }
    # callers that still pass these in -Extra keep working, and win
    if ($Extra) { foreach ($k in $Extra.Keys) { $record[$k] = $Extra[$k] } }

    $path = Get-AtlasHistoryPath
    $dir = Split-Path $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Compress so each record is exactly one line; JSONL depends on that.
    Add-Content -Path $path -Value ($record | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
    $record
}

# Read the history. Older records lack the format-2 fields, so the reader fills them:
#   n          from `repetitions` or `runs`, whichever the harness used
#   kind       smoke for the Update-Workspace check, control for the stock-engine (llama-bench) runs
#   valid      true unless a record says otherwise
#   onAcPower  null (unknown) unless recorded
function Get-AtlasBenchmarkHistory {
    [CmdletBinding()]
    param(
        [string]$StateId,
        # leave out records marked invalid and those measured on battery
        [switch]$Valid,
        [ValidateSet('benchmark', 'control', 'smoke')][string]$Kind
    )

    $path = Get-AtlasHistoryPath
    if (-not (Test-Path $path)) { return @() }
    $records = @(Get-Content $path | Where-Object { $_.Trim() } | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { }   # tolerate a truncated final line
    })
    foreach ($r in $records) {
        $names = $r.PSObject.Properties.Name
        if ('n' -notin $names) {
            $n = if ('repetitions' -in $names) { $r.repetitions } elseif ('runs' -in $names) { $r.runs } else { $null }
            $r | Add-Member -NotePropertyName n -NotePropertyValue $n -Force
        }
        if ('kind' -notin $names) {
            $k = if ($r.source -eq 'Update-Workspace.ps1') { 'smoke' }
                 elseif (('control' -in $names -and $r.control) -or $r.source -like '*control*' -or $r.source -like 'llama-bench*') { 'control' }
                 else { 'benchmark' }
            $r | Add-Member -NotePropertyName kind -NotePropertyValue $k -Force
        }
        if ('valid' -notin $names) { $r | Add-Member -NotePropertyName valid -NotePropertyValue $true -Force }
        if ('onAcPower' -notin $names) { $r | Add-Member -NotePropertyName onAcPower -NotePropertyValue $null -Force }
    }
    if ($StateId) { $records = @($records | Where-Object { $_.stateId -eq $StateId }) }
    if ($Valid) { $records = @($records | Where-Object { $_.valid -ne $false -and $_.onAcPower -ne $false }) }
    if ($Kind) { $records = @($records | Where-Object { $_.kind -eq $Kind }) }
    $records
}

Export-ModuleMember -Function Get-AtlasRoot, Get-AtlasLocalDir, Get-AtlasBaselinePath,
    Get-AtlasHistoryPath, Get-AtlasState, Get-AtlasStateId, Get-AtlasShortId,
    Read-AtlasBaseline, Write-AtlasBaseline, Add-AtlasBenchmarkRecord,
    Get-AtlasBenchmarkHistory, Set-AtlasRunConditions, Get-AtlasRunConditions, Get-AtlasCodeRev
