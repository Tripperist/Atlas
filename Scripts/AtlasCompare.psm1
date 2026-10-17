<#
.SYNOPSIS
    Compare benchmark history between two stacks, cell by cell.

.DESCRIPTION
    The v0.8.0 to v0.9.0 and Foundry re-measurement tables were assembled by hand, twice.
    This does it from the history, with the rules the hand-built tables kept in someone's
    head:

      * A CELL is one thing measured: model, compute unit, prompt length, and the script
        that measured it. Only cells present on both stacks are compared.
      * For each stack and cell, one record stands for it: records measured on battery
        are never used (unless asked), AC power is preferred over "not recorded", and the
        latest of a tier wins. Records marked invalid never count.
      * The spread inside a stack is reported. When a cell has several valid records on one
        stack their relative range is the noise, and a difference smaller than twice that is
        called within noise. When the range itself is half the mean or more the cell is
        called noisy: its records disagree too much for any change to be read from them. A
        cell with one record has no noise estimate, and says so.
      * A control (the stock llama.cpp runs) is reported apart. If a control moved between the
        stacks, the machine was not in the same state, and every other difference must be read
        with that in mind.

    Pure functions over record objects, so they can be tested without a history file.
#>
#requires -Version 7

$script:Metrics = @(
    @{ Name = 'decode';  Property = 'tokPerSec';   Unit = 'tok/s'; HigherIsBetter = $true }
    @{ Name = 'prefill'; Property = 'prefillTps';  Unit = 'tok/s'; HigherIsBetter = $true }
    @{ Name = 'first';   Property = 'firstTokenS'; Unit = 's';     HigherIsBetter = $false }
)

function Get-AtlasCellKey {
    <# The identity of a measurement, without the stack or the metric. #>
    param([Parameter(Mandatory)]$Record)
    # A control is the same cell whichever script recorded it, so hand-entered records and the
    # committed harness meet.
    $source = if ($Record.kind -eq 'control') { 'control' } else { [string]$Record.source }
    '{0}|{1}|{2}|{3}' -f $Record.model, $Record.compute, $(if ($null -ne $Record.promptTokens) { [int]$Record.promptTokens } else { '' }), $source
}

function Select-AtlasRepresentative {
    <#
    .SYNOPSIS
        The record that stands for a cell on a stack, and the noise among its valid records.
    #>
    param([Parameter(Mandatory)][object[]]$Records, [string]$Property, [switch]$IncludeBattery)

    $usable = @($Records | Where-Object {
        $_.valid -ne $false -and $null -ne $_.$Property -and ($IncludeBattery -or $_.onAcPower -ne $false)
    })
    if (-not $usable.Count) { return $null }
    $tier = { param($r) if ($r.onAcPower -eq $true) { 0 } elseif ($null -eq $r.onAcPower) { 1 } else { 2 } }
    $best = $usable | Sort-Object @{ Expression = { & $tier $_ } }, @{ Expression = { [datetime]$_.ts }; Descending = $true } | Select-Object -First 1
    # noise is taken among records of the same tier as the representative
    $same = @($usable | Where-Object { (& $tier $_) -eq (& $tier $best) })
    $values = @($same | ForEach-Object { [double]$_.$Property })
    $noise = $null
    if ($values.Count -ge 2) {
        $mean = ($values | Measure-Object -Average).Average
        if ($mean -ne 0) { $noise = (($values | Measure-Object -Maximum).Maximum - ($values | Measure-Object -Minimum).Minimum) / $mean }
    }
    [pscustomobject]@{ Record = $best; Value = [double]$best.$Property; Noise = $noise; Count = $same.Count
                       Power = $(if ($best.onAcPower -eq $true) { 'AC' } elseif ($null -eq $best.onAcPower) { '?' } else { 'battery' }) }
}

function Compare-AtlasStacks {
    <#
    .SYNOPSIS
        Rows of From / To / change for every cell and metric the two stacks share.
    .PARAMETER Records
        History records (as Get-AtlasBenchmarkHistory returns them).
    .PARAMETER Threshold
        Relative change, in percent, below which a difference is not reported as a change.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]]$Records,
        [Parameter(Mandatory)][string]$From,
        [Parameter(Mandatory)][string]$To,
        [double]$Threshold = 10,
        [switch]$IncludeBattery
    )
    $fromRecs = @($Records | Where-Object { $_.stateId -like "$From*" })
    $toRecs = @($Records | Where-Object { $_.stateId -like "$To*" })
    $fromBy = $fromRecs | Group-Object { Get-AtlasCellKey $_ } -AsHashTable -AsString
    $toBy = $toRecs | Group-Object { Get-AtlasCellKey $_ } -AsHashTable -AsString
    if (-not $fromBy) { $fromBy = @{} }
    if (-not $toBy) { $toBy = @{} }

    foreach ($key in ($fromBy.Keys | Where-Object { $toBy.ContainsKey($_) } | Sort-Object)) {
        foreach ($m in $script:Metrics) {
            $a = Select-AtlasRepresentative -Records $fromBy[$key] -Property $m.Property -IncludeBattery:$IncludeBattery
            $b = Select-AtlasRepresentative -Records $toBy[$key] -Property $m.Property -IncludeBattery:$IncludeBattery
            if (-not $a -or -not $b -or $a.Value -eq 0) { continue }
            $change = ($b.Value - $a.Value) / $a.Value * 100
            $noise = @($a.Noise, $b.Noise | Where-Object { $null -ne $_ } | Measure-Object -Maximum).Maximum
            $better = if ($m.HigherIsBetter) { $change -gt 0 } else { $change -lt 0 }
            $verdict = if ([math]::Abs($change) -lt $Threshold) { 'same' }
                       elseif ($null -ne $noise -and $noise -ge 0.5) { 'noisy' }
                       elseif ($null -ne $noise -and [math]::Abs($change) -lt 200 * $noise) { 'within noise' }
                       elseif ($better) { 'better' } else { 'worse' }
            $rec = $b.Record
            [pscustomobject]@{
                Key = $key; Model = $rec.model; Compute = $rec.compute
                Prompt = $(if ($null -ne $rec.promptTokens) { [int]$rec.promptTokens } else { $null })
                Control = ($rec.kind -eq 'control'); Metric = $m.Name; Unit = $m.Unit
                From = $a.Value; To = $b.Value; ChangePercent = $change; Verdict = $verdict
                NoisePercent = $(if ($null -ne $noise) { 100 * $noise } else { $null })
                FromPower = $a.Power; ToPower = $b.Power; FromCount = $a.Count; ToCount = $b.Count
            }
        }
    }
}

function Get-AtlasStateDiff {
    <# What differs between two recorded stack states, as name / from / to rows. #>
    param([Parameter(Mandatory)]$From, [Parameter(Mandatory)]$To)
    $flat = {
        param($o, $prefix)
        foreach ($p in $o.PSObject.Properties) {
            if ($p.Name -in 'id', 'recorded') { continue }
            $name = if ($prefix) { "$prefix.$($p.Name)" } else { $p.Name }
            if ($p.Value -is [System.Management.Automation.PSCustomObject]) { & $flat $p.Value $name } else { [pscustomobject]@{ Name = $name; Value = [string]$p.Value } }
        }
    }
    $a = @(& $flat $From '') | Group-Object Name -AsHashTable -AsString
    $b = @(& $flat $To '') | Group-Object Name -AsHashTable -AsString
    if (-not $a) { $a = @{} }
    if (-not $b) { $b = @{} }
    foreach ($name in (@($a.Keys) + @($b.Keys) | Select-Object -Unique | Sort-Object)) {
        $x = if ($a.ContainsKey($name)) { $a[$name][0].Value } else { '(absent)' }
        $y = if ($b.ContainsKey($name)) { $b[$name][0].Value } else { '(absent)' }
        if ($x -ne $y) { [pscustomobject]@{ Name = $name; From = $x; To = $y } }
    }
}

function Get-AtlasStackSummary {
    <# One row per stack that has records: counts, dates and the versions that identify it. #>
    param([Parameter(Mandatory)][object[]]$Records)
    $rows = foreach ($g in ($Records | Group-Object stateId)) {
        $first = $g.Group | Sort-Object { [datetime]$_.ts } | Select-Object -First 1
        $last = $g.Group | Sort-Object { [datetime]$_.ts } | Select-Object -Last 1
        $s = $last.state
        [pscustomobject]@{
            Stack = $g.Name; Records = $g.Count
            AC = @($g.Group | Where-Object onAcPower -EQ $true).Count
            Battery = @($g.Group | Where-Object onAcPower -EQ $false).Count
            First = [datetime]$first.ts; Last = [datetime]$last.ts
            GenieX = $s.geniex.version; LlamaCpp = $s.geniex.llamacpp; Foundry = $s.foundry
            OrtQnn = $s.packages.onnxruntime_qnn; Adreno = $s.drivers.adreno
        }
    }
    $rows | Sort-Object Last
}

Export-ModuleMember -Function Get-AtlasCellKey, Select-AtlasRepresentative, Compare-AtlasStacks, Get-AtlasStateDiff, Get-AtlasStackSummary
