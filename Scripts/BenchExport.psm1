<#
.SYNOPSIS
    Select the figures worth publishing from the benchmark history, and render them.

.DESCRIPTION
    The history is a local, append-only ledger of everything that was run. The published figures
    are a small, curated view of it. The rule, which is also written into the export:

      * Only AC-powered records. A figure measured on battery, or whose power state was never
        recorded (everything before 2026-10-17), is not published; the history is not edited,
        it just does not qualify.
      * Only records that are valid, and only benchmarks and controls. Smoke checks and canary
        runs are never published.
      * One figure stands for a CELL (model, compute unit, prompt length, measuring script, context
        size, and the software variant where the same stack can differ, such as the QNN package a
        C# run was built against): the MEDIAN over the records of its latest SESSION (records within 30
        minutes of each other), unless a pin names one record. One run is not a fair stand-in: the three
        C# runs of one ONNX Runtime GenAI session read 17.3 to 18.9 tok/s. A cell whose AC records disagree by
        more than a quarter of the figure (maximum minus minimum) is marked unstable.
      * Every published figure carries its stack and its date, so a figure from one GenieX version is
        visibly not a figure from another. A cell whose latest AC record is from an older stack than the
        current one is published as such, not hidden.

    Pure functions over record objects, so the rules can be tested without a history file. Local paths
    are never copied: only a fixed set of fields is.
#>
#requires -Version 7

$compareModule = Join-Path $PSScriptRoot 'BenchCompare.psm1'
if (-not (Get-Command Get-AtlasSourceName -ErrorAction SilentlyContinue)) { Import-Module $compareModule }

$script:Rule = 'AC-powered, valid benchmark and control records only; the median over the latest session (records within 30 minutes) of each cell, unless pinned; smoke and canary records are never published.'

$script:Families = @(
    @{ Source = 'Invoke-BenchDecode.ps1';         Title = 'GenieX decode from a short prompt' }
    @{ Source = 'Invoke-BenchPrefill.ps1';        Title = 'GenieX prefill and decode by prompt length' }
    @{ Source = 'Invoke-BenchFoundry.ps1';        Title = 'Foundry Local over HTTP' }
    @{ Source = 'Invoke-BenchFoundryContext.ps1'; Title = 'Foundry Local by prompt length' }
    @{ Source = 'bench_foundry_sdk.py';           Title = 'Foundry Local by prompt length' }
    @{ Source = 'Invoke-BenchOrtGenAi.ps1';       Title = 'ONNX Runtime GenAI' }
    @{ Source = 'bench_ort_genai.py';             Title = 'ONNX Runtime GenAI' }
    @{ Source = 'control';                        Title = 'Stock llama.cpp (the control)' }
)

function Get-AtlasVariant {
    <# What else can differ on one stack: the package versions a record carries itself (a C# run's QNN provider). #>
    param([Parameter(Mandatory)]$Record)
    if (-not $Record.packages) { return '' }
    (@($Record.packages.PSObject.Properties | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join ';')
}

function Get-AtlasPublishKey {
    <# The identity of a published figure: the comparison's cell key, plus what only matters here. #>
    param([Parameter(Mandatory)]$Record)
    '{0}|{1}|{2}' -f (Get-AtlasCellKey $Record), $(if ($null -ne $Record.ctxSize) { [int]$Record.ctxSize } else { '' }), (Get-AtlasVariant $Record)
}

function Test-AtlasPublishable {
    param([Parameter(Mandatory)]$Record)
    ($Record.kind -in 'benchmark', 'control') -and ($Record.valid -ne $false) -and ($Record.onAcPower -eq $true) -and
    (($null -ne $Record.tokPerSec) -or ($null -ne $Record.prefillTps) -or ($null -ne $Record.firstTokenS))
}

function Get-AtlasMedian {
    param([double[]]$Values)
    $v = @($Values | Sort-Object)
    if (-not $v.Count) { return $null }
    $mid = [int][math]::Floor($v.Count / 2)
    if ($v.Count % 2) { $v[$mid] } else { ($v[$mid - 1] + $v[$mid]) / 2 }
}

function Split-AtlasSessions {
    <#
    .SYNOPSIS
        Group one cell's records, in time order, into sessions: a gap of more than SessionMinutes, or a
        change of stack, starts a new one.
    .DESCRIPTION
        The records of one session (the three rounds of a suite step, the invocations of one afternoon's A/B
        sequence) are samples of the same conditions. One of them is not a fair stand-in for the cell: the
        three ONNX Runtime GenAI C# runs of one session read 17.3 to 18.9 tok/s, and a single one could be
        either end.
    #>
    param([Parameter(Mandatory)][object[]]$Records, [int]$SessionMinutes = 30)
    $sessions = [System.Collections.Generic.List[object]]::new()
    $current = $null; $last = $null
    foreach ($r in ($Records | Sort-Object { [datetime]$_.ts })) {
        if ($null -eq $current -or ([datetime]$r.ts - [datetime]$last.ts).TotalMinutes -gt $SessionMinutes -or $r.stateId -ne $last.stateId) {
            $current = [pscustomobject]@{ Records = [System.Collections.Generic.List[object]]::new() }
            $sessions.Add($current)
        }
        $current.Records.Add($r)
        $last = $r
    }
    $sessions.ToArray()
}

function Get-AtlasPublishedCells {
    <#
    .SYNOPSIS
        One cell per published figure, as plain objects with only the fields that may be published.
    .DESCRIPTION
        The figure for a cell is the MEDIAN of each metric over the records of its latest session (see
        Split-AtlasSessions). A cell whose AC records disagree by more than a quarter of the figure is marked
        unstable. A pin names one record, which then stands alone.
    .PARAMETER Records
        History records.
    .PARAMETER Pins
        Objects with `cell` (a publish key) and `id` (a record id) that override the latest session.
    .PARAMETER CurrentStack
        The short id of the stack the machine is on now; cells measured on another are marked not current.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [AllowEmptyCollection()][object[]]$Pins = @(),
        [string]$CurrentStack,
        [int]$SessionMinutes = 30,
        [double]$UnstableOver = 0.25
    )
    $pinFor = @{}
    foreach ($p in $Pins) { $pinFor[[string]$p.cell] = [string]$p.id }

    $groups = @($Records | Where-Object { Test-AtlasPublishable $_ } | Group-Object { Get-AtlasPublishKey $_ })
    foreach ($g in ($groups | Sort-Object Name)) {
        $sessions = @(Split-AtlasSessions -Records $g.Group -SessionMinutes $SessionMinutes)
        $standing = @($sessions[-1].Records)
        $pinned = $false
        if ($pinFor.ContainsKey($g.Name)) {
            $hit = $g.Group | Where-Object { $_.id -eq $pinFor[$g.Name] } | Select-Object -First 1
            if ($hit) { $standing = @($hit); $pinned = $true }
        }
        $r = @($standing | Sort-Object { [datetime]$_.ts })[-1]
        $st = $r.state
        $med = { param($prop) $v = @($standing | Where-Object { $null -ne $_.$prop } | ForEach-Object { [double]$_.$prop }); if ($v.Count) { Get-AtlasMedian $v } else { $null } }

        # How far ALL the cell's AC records disagree, on its main figure (decode, else prefill). A cell can
        # have a healthy latest session and an earlier AC session that was slow; that is worth knowing.
        $headline = if (@($g.Group | Where-Object { $null -ne $_.tokPerSec }).Count) { 'tokPerSec' } else { 'prefillTps' }
        $all = @($g.Group | Where-Object { $null -ne $_.$headline } | ForEach-Object { [double]$_.$headline })
        $figure = & $med $headline
        $range = $null; $unstable = $false
        if ($all.Count -gt 1 -and $figure) {
            $lo = ($all | Measure-Object -Minimum).Minimum; $hi = ($all | Measure-Object -Maximum).Maximum
            $range = @($lo, $hi)
            $unstable = (($hi - $lo) / $figure) -gt $UnstableOver
        }
        $ns = @($standing | Where-Object { $null -ne $_.n } | ForEach-Object { [int]$_.n })
        $decode = & $med 'tokPerSec'; $prefill = & $med 'prefillTps'; $first = & $med 'firstTokenS'
        [ordered]@{
            key = $g.Name
            family = (Get-AtlasFamilyTitle $r)
            model = [string]$r.model
            compute = [string]$r.compute
            promptTokens = $(if ($null -ne $r.promptTokens) { [int]$r.promptTokens } else { $null })
            ctxSize = $(if ($null -ne $r.ctxSize) { [int]$r.ctxSize } else { $null })
            kind = [string]$r.kind
            decodeTps = $decode
            prefillTps = $prefill
            firstTokenS = $first
            tokens = $(if ($null -ne $r.tokens) { [int]$r.tokens } else { $null })
            n = $(if ($ns.Count) { [int](($ns | Measure-Object -Sum).Sum) } else { $null })
            figure = $(if ($pinned) { 'a pinned record' } elseif ($standing.Count -gt 1) { "median of $($standing.Count) records in the latest session" } else { 'one record' })
            sessionRecords = $standing.Count
            acRecords = @($g.Group).Count
            acSessions = $sessions.Count
            acRange = $range
            unstable = $unstable
            pinned = $pinned
            current = [bool]($CurrentStack -and ([string]$r.stateId -eq $CurrentStack))
            date = ([datetime]$r.ts).ToString('yyyy-MM-dd')
            source = (Get-AtlasSourceName $r)
            harness = $(if ($r.harness) { [string]$r.harness } else { $null })
            harnessVersion = $(if ($r.harnessVersion) { [string]$r.harnessVersion } else { $null })
            promptKind = $(if ($r.promptKind) { [string]$r.promptKind } else { $null })
            promptSha256 = $(if ($r.promptSha256) { [string]$r.promptSha256 } else { $null })
            order = $(if ($r.order) { [string]$r.order } else { $null })
            seed = $(if ($null -ne $r.seed) { [int]$r.seed } else { $null })
            powerScheme = $(if ($r.conditions) { [string]$r.conditions.powerScheme } else { $null })
            stack = [ordered]@{
                id = [string]$r.stateId
                geniex = [string]$st.geniex.version
                llamacpp = [string]$st.geniex.llamacpp
                foundry = [string]$st.foundry
                onnxruntime = [string]$st.packages.onnxruntime
                onnxruntimeGenai = [string]$st.packages.onnxruntime_genai
                onnxruntimeQnn = [string]$st.packages.onnxruntime_qnn
                adreno = [string]$st.drivers.adreno
                npu = [string]$st.drivers.npu
                os = [string]$st.os
            }
            variant = $(if ($r.packages) { Get-AtlasVariant $r } else { $null })
            codeRev = $(if ($r.codeRev) { [string]$r.codeRev } else { $null })
            suiteRun = $(if ($r.suiteRun) { [string]$r.suiteRun } else { $null })
            recordIds = @($standing | ForEach-Object { [string]$_.id })
        }
    }
}

function Get-AtlasFamilyTitle {
    param([Parameter(Mandatory)]$Record)
    $src = Get-AtlasSourceName $Record
    $f = $script:Families | Where-Object { $_.Source -eq $src } | Select-Object -First 1
    if ($f) { $f.Title } else { 'Other' }
}

function New-AtlasExport {
    <# The committed document: the rule, the stack the machine is on, and the cells. No timestamp, so a rerun that changes nothing changes nothing. #>
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Cells, [string]$CurrentStack)
    [ordered]@{
        schemaVersion = 1
        rule = $script:Rule
        currentStack = $CurrentStack
        cellCount = @($Cells).Count
        cells = @($Cells)
    }
}

function Format-AtlasResultTables {
    <#
    .SYNOPSIS
        Markdown tables of the published cells, one per family, each row with its stack and date.
    #>
    param([Parameter(Mandatory)]$Export)
    $cells = @($Export.cells)
    $out = [System.Collections.Generic.List[string]]::new()
    if (-not $cells.Count) {
        $out.Add('_No figure qualifies yet: nothing in the history was measured on AC power._')
        return ($out -join "`n")
    }
    # U+2020, spelled out so this file stays ASCII (PowerShell 7 reads UTF-8 either way, but a BOM-less
    # non-ASCII script is read wrongly by Windows PowerShell 5.1).
    $dagger = [string][char]0x2020
    $titles = @($script:Families | ForEach-Object Title | Select-Object -Unique) + 'Other'
    $f = { param($v, $fmt) if ($null -eq $v) { '' } else { $fmt -f $v } }
    foreach ($title in $titles) {
        $rows = @($cells | Where-Object { $_.family -eq $title } | Sort-Object { $_.model }, { $_.compute }, { [int]($_.promptTokens ?? 0) }, { $_.variant })
        if (-not $rows.Count) { continue }
        $out.Add("**$title**")
        $out.Add('')
        $out.Add('| Model | Compute | Prompt | Prefill tok/s | First token s | Decode tok/s | Runs | Stack | Date |')
        $out.Add('| --- | --- | --- | --- | --- | --- | --- | --- | --- |')
        foreach ($c in $rows) {
            $compute = if ($c.variant -and $c.variant -match 'onnxruntime_providers_qnn\.dll=([0-9.]+)') { "$($c.compute) (QNN $($Matches[1]))" } else { $c.compute }
            $stack = $c.stack.id.Substring(0, [Math]::Min(7, $c.stack.id.Length)) + $(if ($c.stack.geniex) { " ($($c.stack.geniex))" } else { '' })
            if (-not $c.current) { $stack += ' *' }
            $runs = if ($c.pinned) { 'pinned' } else { "$($c.sessionRecords) of $($c.acRecords)" }
            if ($c.unstable) { $runs += " $dagger" }
            $out.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} | {7} | {8} |' -f $c.model, $compute, (& $f $c.promptTokens '{0:N0}'),
                (& $f $c.prefillTps '{0:N0}'), (& $f $c.firstTokenS '{0:N2}'), (& $f $c.decodeTps '{0:N1}'), $runs, $stack, $c.date))
        }
        $out.Add('')
    }
    $old = @($cells | Where-Object { -not $_.current }).Count
    $unstable = @($cells | Where-Object unstable).Count
    $out.Add(("{0} figures. Each is the median over the latest AC-powered session of its cell (records within 30 minutes of each other); ``Runs`` reads 'records in that session of all AC records of the cell'." -f $cells.Count) +
        $(if ($unstable) { " A ``$dagger`` marks a cell whose AC records disagree by more than a quarter of the figure ($unstable): read it as a range, which is in ``benchmarks.json``." } else { '' }) +
        $(if ($old) { " A ``*`` marks a stack older than the one the machine is on now ($old figure(s)): not re-measured since." } else { '' }))
    ($out -join "`n").TrimEnd()
}

function Set-AtlasDocBlock {
    <#
    .SYNOPSIS
        Replace the text between <!-- BEGIN GENERATED: name --> and <!-- END GENERATED: name --> in a file.
    .OUTPUTS
        True if the file changed.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Content, [switch]$CheckOnly)
    $raw = [System.IO.File]::ReadAllText($Path)
    $nl = if ($raw.Contains("`r`n")) { "`r`n" } else { "`n" }
    $text = $raw -replace "`r`n", "`n"
    $begin = "<!-- BEGIN GENERATED: $Name"
    $end = "<!-- END GENERATED: $Name -->"
    $i = $text.IndexOf($begin)
    $j = $text.IndexOf($end)
    if ($i -lt 0 -or $j -lt 0 -or $j -lt $i) { throw "$Path has no '$begin ... $end' markers." }
    $lineEnd = $text.IndexOf("`n", $i)
    $head = $text.Substring(0, $lineEnd + 1)
    $new = $head + $Content.TrimEnd() + "`n" + $text.Substring($j)
    $changed = ($new -ne $text)
    if ($changed -and -not $CheckOnly) { [System.IO.File]::WriteAllText($Path, $new.Replace("`n", $nl), [System.Text.UTF8Encoding]::new($false)) }
    $changed
}

Export-ModuleMember -Function Get-AtlasPublishKey, Test-AtlasPublishable, Split-AtlasSessions, Get-AtlasMedian, Get-AtlasPublishedCells, New-AtlasExport, Format-AtlasResultTables, Set-AtlasDocBlock
