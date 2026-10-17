<#
.SYNOPSIS
    Run a named set of benchmarks from a committed manifest, into one run folder,
    and print a summary of what they measured.

.DESCRIPTION
    A suite is a manifest in Scripts/suites/<name>.json: an ordered list of steps, each
    one of the benchmark scripts with its arguments. Committing the manifest means "the
    stack-compare numbers" is a command, not a recollection of which commands were run.

        smoke           a few minutes; proves the harnesses run
        stack-compare   what to run after a stack change, to see what moved
        runtimes        GenieX, Foundry and ONNX Runtime GenAI side by side
        longctx         prefill and decode at 512 to 6,784 tokens
        ort             ONNX Runtime GenAI from Python and C#

    Each step runs in its own PowerShell process, so array arguments bind (they do not
    under `pwsh -File`) and one step's state cannot leak into the next. The steps do their
    own conditions check and refuse on battery; so does this script, once, up front, so a
    suite on battery stops before anything has loaded. Steps are independent: a step that
    fails is reported and the rest still run (-StopOnError changes that).

    The run folder, .atlas-local/benchmarks/runs/<timestamp>-<suite>/ (git-ignored):

        suite.json      the manifest as run, the stack, the code revision, the conditions
        steps.json      each step's status, exit code, duration and record count
        records.jsonl   the history records the steps wrote (also appended to history.jsonl)
        logs/<id>.log   each step's output
        summary.md      the table printed at the end

    Records written during the run carry `suiteRun` (the run's folder name), so they can be
    found in the history later.

    A step that exits with code 4 means a prerequisite is not present (for example the
    pinned llama.cpp build is not unpacked) and is reported as skipped, not failed.

    The estimates in the manifests are rough, from runs on one machine.

.PARAMETER Suite
    A suite name, as listed by -List.

.PARAMETER List
    List the suites and exit.

.PARAMETER DryRun
    Show the steps, the commands and the estimate, and run nothing.

.PARAMETER Only
    Run only these step ids.

.PARAMETER Skip
    Skip these step ids.

.PARAMETER StopOnError
    Stop at the first failed step.

.PARAMETER AllowBattery
    Pass -AllowBattery to every step; everything is then recorded onAcPower = false.

.EXAMPLE
    .\Scripts\Invoke-AtlasBenchSuite.ps1 -List

.EXAMPLE
    .\Scripts\Invoke-AtlasBenchSuite.ps1 -Suite stack-compare -DryRun

.EXAMPLE
    pwsh -Command "& .\Scripts\Invoke-AtlasBenchSuite.ps1 -Suite longctx -Skip foundry-7b-inprocess"
#>
#requires -Version 7
[CmdletBinding()]
param(
    [string]$Suite,
    [switch]$List,
    [switch]$DryRun,
    [string[]]$Only,
    [string[]]$Skip,
    [switch]$StopOnError,
    [switch]$AllowBattery,
    # Where the manifests and run folders are. The defaults are the committed suites and
    # .atlas-local/benchmarks/runs; the tests point them at a temporary folder.
    [string]$SuiteDir,
    [string]$RunsDir
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$suiteDir = if ($SuiteDir) { $SuiteDir } else { Join-Path $PSScriptRoot 'suites' }
Import-Module (Join-Path $PSScriptRoot 'AtlasBaseline.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'AtlasConditions.psm1') -Force

function Get-Suites {
    Get-ChildItem $suiteDir -Filter '*.json' | Sort-Object Name | ForEach-Object {
        $m = Get-Content $_.FullName -Raw | ConvertFrom-Json
        [pscustomobject]@{
            Name = $_.BaseName; Description = $m.description; Steps = @($m.steps)
            Minutes = ($m.steps | Measure-Object estimateMinutes -Sum).Sum; Path = $_.FullName
        }
    }
}

function ConvertTo-CommandLine([string]$Script, $StepArgs, [bool]$Battery) {
    $parts = [System.Collections.Generic.List[string]]::new()
    $parts.Add("& '$($Script -replace "'", "''")'")
    foreach ($p in @($StepArgs.PSObject.Properties)) {
        $v = $p.Value
        if ($v -is [bool]) { if ($v) { $parts.Add("-$($p.Name)") }; continue }
        $items = foreach ($i in @($v)) { if ($i -is [string]) { "'" + ($i -replace "'", "''") + "'" } else { [string]$i } }
        $parts.Add("-$($p.Name) " + ($items -join ','))
    }
    if ($Battery) { $parts.Add('-AllowBattery') }
    # `pwsh -Command` exits 0 or 1 from $?, so a script's `exit 4` would arrive as 1. Pass the
    # code through when the script failed, and call a normal finish 0 even if an inner native
    # command left a stale $LASTEXITCODE behind.
    ($parts -join ' ') + '; if ($?) { exit 0 } else { exit $(if ($LASTEXITCODE) { $LASTEXITCODE } else { 1 }) }'
}

$suites = @(Get-Suites)

if ($List -or -not $Suite) {
    Write-Host 'Suites (Scripts/suites/*.json):' -ForegroundColor Cyan
    foreach ($s in $suites) {
        Write-Host ("  {0,-14} {1} steps, about {2} min" -f $s.Name, $s.Steps.Count, $s.Minutes)
        Write-Host ("  {0,-14} {1}" -f '', $s.Description) -ForegroundColor DarkGray
    }
    Write-Host ''
    Write-Host 'Run one with -Suite <name>; -DryRun shows what it would do.'
    if (-not $List -and -not $Suite) { exit 1 }
    return
}

$def = $suites | Where-Object Name -EQ $Suite
if (-not $def) { Write-Host "No suite '$Suite'. Known: $(($suites.Name) -join ', ')" -ForegroundColor Red; exit 1 }

$steps = @($def.Steps | Where-Object { (-not $Only -or $_.id -in $Only) -and ($_.id -notin $Skip) })
foreach ($id in @($Only) + @($Skip)) {
    if ($id -and $id -notin $def.Steps.id) { Write-Host "Suite '$Suite' has no step '$id'. Steps: $(($def.Steps.id) -join ', ')" -ForegroundColor Red; exit 1 }
}
if (-not $steps.Count) { Write-Host 'No steps selected.' -ForegroundColor Red; exit 1 }
$estimate = ($steps | Measure-Object estimateMinutes -Sum).Sum

Write-Host ("Suite {0}: {1} step(s), about {2} min (a rough estimate)" -f $Suite, $steps.Count, $estimate) -ForegroundColor Cyan
Write-Host $def.Description -ForegroundColor DarkGray
Write-Host ''
if ($DryRun) {
    foreach ($s in $steps) {
        Write-Host ("  {0}  (~{1} min, needs {2})" -f $s.id, $s.estimateMinutes, (@($s.needs) -join ', '))
        Write-Host ("    pwsh -NoProfile -Command ""{0}""" -f (ConvertTo-CommandLine $s.script $s.args $AllowBattery.IsPresent)) -ForegroundColor DarkGray
        if ($s.note) { Write-Host "    $($s.note)" -ForegroundColor DarkGray }
    }
    Write-Host ''
    Write-Host 'Dry run: nothing was run, and the machine''s conditions were not checked.'
    return
}

# One check for the whole suite, before anything loads.
$needs = @($steps | ForEach-Object { @($_.needs) } | Where-Object { $_ } | Select-Object -Unique)
$conditions = Assert-AtlasConditions -Needs $needs -AllowBattery:$AllowBattery

$state = Get-AtlasState
$runId = '{0}-{1}' -f (Get-Date -Format 'yyyyMMdd-HHmmss'), $Suite
$runDir = Join-Path $(if ($RunsDir) { $RunsDir } else { Join-Path $root '.atlas-local/benchmarks/runs' }) $runId
New-Item -ItemType Directory -Force -Path (Join-Path $runDir 'logs') | Out-Null
$env:ATLAS_SUITE_RUN = $runId
$historyPath = Get-AtlasHistoryPath

[ordered]@{
    runId = $runId; suite = $Suite; started = (Get-Date -Format 'o'); stack = (Get-AtlasShortId $state.id)
    codeRev = (Get-AtlasCodeRev); onAcPower = $conditions.onAcPower; conditions = $conditions
    options = @{ only = $Only; skip = $Skip; stopOnError = $StopOnError.IsPresent; allowBattery = $AllowBattery.IsPresent }
    manifest = (Get-Content (Join-Path $suiteDir "$Suite.json") -Raw | ConvertFrom-Json)
} | ConvertTo-Json -Depth 12 | Set-Content (Join-Path $runDir 'suite.json') -Encoding utf8

function Get-HistoryLineCount { if (Test-Path $historyPath) { @(Get-Content $historyPath).Count } else { 0 } }

$results = [System.Collections.Generic.List[object]]::new()
$allRecords = [System.Collections.Generic.List[string]]::new()
try {
    $n = 0
    foreach ($s in $steps) {
        $n++
        Write-Host ("[{0}/{1}] {2}" -f $n, $steps.Count, $s.id) -ForegroundColor Cyan
        $scriptPath = if ([System.IO.Path]::IsPathRooted($s.script)) { $s.script } else { Join-Path $PSScriptRoot $s.script }
        $cmd = ConvertTo-CommandLine $scriptPath $s.args $AllowBattery.IsPresent
        $log = Join-Path $runDir "logs/$($s.id).log"
        $before = Get-HistoryLineCount
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        & pwsh -NoProfile -Command $cmd *>&1 | Tee-Object -FilePath $log | ForEach-Object { Write-Host $_ }
        $code = $LASTEXITCODE
        $sw.Stop()
        $new = @(if (Test-Path $historyPath) { Get-Content $historyPath | Select-Object -Skip $before } else { @() })
        foreach ($line in $new) { $allRecords.Add($line) }

        $status = if ($code -eq 0) { 'ok' } elseif ($code -eq 4) { 'skipped' } else { 'failed' }
        $results.Add([pscustomobject]@{
            id = $s.id; script = $s.script; status = $status; exitCode = $code
            seconds = [math]::Round($sw.Elapsed.TotalSeconds, 1); records = $new.Count; optional = [bool]$s.optional
        })
        $color = switch ($status) { 'ok' { 'Green' } 'skipped' { 'Yellow' } default { 'Red' } }
        Write-Host ("  -> {0} in {1:N0} s, {2} record(s)" -f $status, $sw.Elapsed.TotalSeconds, $new.Count) -ForegroundColor $color
        Write-Host ''
        if ($status -eq 'failed' -and $StopOnError) { Write-Host 'Stopping: -StopOnError.' -ForegroundColor Red; break }
    }
}
finally {
    Remove-Item Env:ATLAS_SUITE_RUN -ErrorAction SilentlyContinue
    $results | ConvertTo-Json -Depth 4 | Set-Content (Join-Path $runDir 'steps.json') -Encoding utf8
    [System.IO.File]::WriteAllLines((Join-Path $runDir 'records.jsonl'), [string[]]$allRecords, [System.Text.UTF8Encoding]::new($false))
}

# ------------------------------------------------------------------- summary

$records = @($allRecords | ForEach-Object { try { $_ | ConvertFrom-Json } catch { $null } } | Where-Object { $_ })
$md = [System.Collections.Generic.List[string]]::new()
$md.Add("# $runId")
$md.Add('')
$md.Add(('Stack `{0}`, code `{1}`, {2}.' -f (Get-AtlasShortId $state.id), (Get-AtlasCodeRev), $(if ($conditions.onAcPower -eq $false) { '**on battery: not comparable with AC runs**' } elseif ($conditions.onAcPower) { 'on AC power' } else { 'power state unknown' })))
$md.Add('')
$md.Add('| Step | Status | Time | Records |')
$md.Add('| --- | --- | --- | --- |')
foreach ($r in $results) { $md.Add(('| {0} | {1} | {2} s | {3} |' -f $r.id, $r.status, $r.seconds, $r.records)) }
$md.Add('')
if ($records.Count) {
    $md.Add('| Model | Compute | Prompt | Prefill tok/s | First token s | Decode tok/s | n |')
    $md.Add('| --- | --- | --- | --- | --- | --- | --- |')
    $f = { param($v, $fmt) if ($null -eq $v) { '' } else { $fmt -f $v } }
    foreach ($r in ($records | Sort-Object model, compute, @{ Expression = { [int]$_.promptTokens } })) {
        $md.Add(('| {0} | {1} | {2} | {3} | {4} | {5} | {6} |' -f $r.model, $r.compute, (& $f $r.promptTokens '{0}'),
            (& $f $r.prefillTps '{0:N0}'), (& $f $r.firstTokenS '{0:N2}'), (& $f $r.tokPerSec '{0:N1}'), (& $f $r.n '{0}')))
    }
}
$md | Set-Content (Join-Path $runDir 'summary.md') -Encoding utf8

Write-Host ''
Write-Host ($md -join "`n")
Write-Host ''
Write-Host "Run folder: $runDir" -ForegroundColor DarkGray

$failed = @($results | Where-Object { $_.status -eq 'failed' -and -not $_.optional })
if ($failed.Count) { Write-Host ("{0} step(s) failed: {1}" -f $failed.Count, ($failed.id -join ', ')) -ForegroundColor Red }
exit $failed.Count
