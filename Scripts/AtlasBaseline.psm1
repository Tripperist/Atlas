<#
.SYNOPSIS
    Shared workspace-state capture, identity, and benchmark history for Atlas.

.DESCRIPTION
    A benchmark number is meaningless without the stack that produced it. This
    repository learned that twice: an Adreno patch-level driver bump turned a
    hard crash into 131 tok/s (README section 12), and GenieX v0.8.0 shifted
    one-shot first-token latency without touching throughput (section 9.2).
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
function Get-AtlasHistoryPath  { Join-Path (Get-AtlasLocalDir) 'benchmarks\history.jsonl' }

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
#>
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
        [hashtable]$Extra
    )

    $id = if ($State -is [System.Collections.IDictionary] -and $State.Contains('id')) { $State['id'] }
          elseif ($State.PSObject.Properties['id']) { $State.id }
          else { Get-AtlasStateId $State }

    $record = [ordered]@{
        ts          = (Get-Date -Format 'o')
        stateId     = Get-AtlasShortId $id
        source      = $Source
        model       = $Model
        compute     = $Compute
        tokPerSec   = $TokPerSec
        firstTokenS = $FirstTokenS
        tokens      = $Tokens
        prefillTps  = $PrefillTps
        promptTokens = $PromptTokens
        csv         = $CsvPath
        state       = $State
    }
    if ($Extra) { foreach ($k in $Extra.Keys) { $record[$k] = $Extra[$k] } }

    $path = Get-AtlasHistoryPath
    $dir = Split-Path $path
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    # Compress so each record is exactly one line; JSONL depends on that.
    Add-Content -Path $path -Value ($record | ConvertTo-Json -Depth 8 -Compress) -Encoding UTF8
    $record
}

function Get-AtlasBenchmarkHistory {
    [CmdletBinding()]
    param([string]$StateId)

    $path = Get-AtlasHistoryPath
    if (-not (Test-Path $path)) { return @() }
    $records = Get-Content $path | Where-Object { $_.Trim() } | ForEach-Object {
        try { $_ | ConvertFrom-Json } catch { }   # tolerate a truncated final line
    }
    if ($StateId) { $records = $records | Where-Object { $_.stateId -eq $StateId } }
    $records
}

Export-ModuleMember -Function Get-AtlasRoot, Get-AtlasLocalDir, Get-AtlasBaselinePath,
    Get-AtlasHistoryPath, Get-AtlasState, Get-AtlasStateId, Get-AtlasShortId,
    Read-AtlasBaseline, Write-AtlasBaseline, Add-AtlasBenchmarkRecord,
    Get-AtlasBenchmarkHistory
