<#
.SYNOPSIS
    Record and check the conditions a benchmark runs under.

.DESCRIPTION
    A benchmark figure depends on more than the software stack. This repository
    published numbers that turned out to depend on conditions nobody had checked:

      * an ONNX Runtime GenAI benchmark ran with the laptop on battery and looked
        like a 3x regression from a package upgrade (it was the power state; an
        unchanged control fell the same way);
      * a stray `geniex serve`, or a model left loaded in the Foundry daemon, can
        hold the NPU, because only one process may hold QNN graphs;
      * a utilization sampler running beside the timed request lowered the rate it
        reported, by about 9 % on a 7B model and about 40 % on a 0.5B one;
      * runs have sat in an unexplained half-speed state.

    This module captures those conditions before a run, applies a policy to them,
    and hands the result to the history so each record says what it ran under.

    Get-AtlasConditions   capture (about three seconds)
    Test-AtlasConditions  apply the policy to a captured object; pure, so it can be
                          tested with synthetic input
    Assert-AtlasConditions  capture, report, and throw if the policy refuses

    Policy:
      * on battery           REFUSE, unless -AllowBattery, which runs and records it
      * NPU needed and another process may hold it    REFUSE
      * busy CPU, a background consumer, a competing process off the NPU    WARN

    Foundry is checked without starting it. `foundry cache ls` starts the daemon as
    a side effect, so this asks `foundry model list --loaded` only when the daemon
    process already exists. A stopped daemon holds no models.

    Used by the benchmark scripts and, through atlas_history.py, the Python ones.
#>

#requires -Version 7

Set-StrictMode -Version Latest

# Processes that compete with a benchmark for the NPU, the GPU or the CPU.
$script:Competing = @('geniex', 'geniex-bench', 'llama-bench', 'llama-server', 'llama-cli', 'atlas-chat')

# A background process using more than this many cores is worth a warning.
$script:HogCores = 0.3
$script:BusyWarnPercent = 15

$script:Last = $null

function Get-AtlasConditions {
    [CmdletBinding()]
    param(
        # How long to watch CPU use and background processes.
        [ValidateRange(1, 30)][int]$Seconds = 3,
        # Return the last capture in this process instead of watching again.
        [switch]$Cached
    )

    if ($Cached -and $script:Last) { return $script:Last }

    # ---- power
    $onAc = $null; $percent = $null; $status = $null
    $battery = Get-CimInstance Win32_Battery -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $battery) {
        $onAc = $true            # no battery reported: mains
    }
    else {
        $percent = [int]$battery.EstimatedChargeRemaining
        $status = [int]$battery.BatteryStatus
        # 1 discharging, 4 low, 5 critical; 2 AC, 3 fully charged, 6-9 charging, 11 partly charged
        $onAc = if ($status -in 1, 4, 5) { $false }
                elseif ($status -in 2, 3, 6, 7, 8, 9, 11) { $true }
                else { $null }
    }
    $scheme = ((powercfg /getactivescheme 2>$null) -join ' ') -replace '^.*\((.*)\)\s*$', '$1'

    # ---- CPU use and background consumers, over one window
    $before = @{}
    foreach ($p in Get-Process) {
        try { $before[$p.Id] = @{ Name = $p.ProcessName; Cpu = $p.TotalProcessorTime.TotalSeconds } } catch { }
    }
    $started = Get-Date
    $busy = $null
    try {
        $samples = (Get-Counter '\Processor Information(_Total)\% Processor Utility' `
                        -SampleInterval 1 -MaxSamples $Seconds -ErrorAction Stop).CounterSamples
        $busy = [math]::Round(($samples | Measure-Object CookedValue -Average).Average, 1)
    }
    catch { Start-Sleep -Seconds $Seconds }
    $elapsed = [math]::Max(((Get-Date) - $started).TotalSeconds, 0.5)

    $use = @{}
    foreach ($p in Get-Process) {
        if ($p.Id -eq $PID -or -not $before.ContainsKey($p.Id)) { continue }
        try {
            $cores = ($p.TotalProcessorTime.TotalSeconds - $before[$p.Id].Cpu) / $elapsed
            $use[$p.ProcessName] = [double]$(if ($use.ContainsKey($p.ProcessName)) { $use[$p.ProcessName] } else { 0 }) + $cores
        }
        catch { }
    }
    $hogs = @($use.GetEnumerator() | Where-Object { $_.Value -ge $script:HogCores } |
              Sort-Object Value -Descending | Select-Object -First 5 |
              ForEach-Object { [pscustomobject]@{ name = $_.Key; cores = [math]::Round($_.Value, 2) } })

    # ---- processes that compete for the NPU or the CPU
    $competing = @()
    foreach ($group in (Get-Process -Name $script:Competing -ErrorAction SilentlyContinue | Group-Object ProcessName)) {
        $cmd = $null
        try {
            $cmd = (Get-CimInstance Win32_Process -Filter "ProcessId = $($group.Group[0].Id)" -ErrorAction Stop).CommandLine
            if ($cmd -and $cmd.Length -gt 140) { $cmd = $cmd.Substring(0, 140) }
        }
        catch { }
        $competing += [pscustomobject]@{ name = $group.Name; pids = @($group.Group.Id); commandLine = $cmd }
    }

    # ---- Foundry, without starting it
    $loaded = @()
    $daemon = [bool](Get-Process -Name foundrylocald -ErrorAction SilentlyContinue)
    if ($daemon -and (Get-Command foundry -ErrorAction SilentlyContinue)) {
        $text = (& foundry model list --loaded 2>&1 | Out-String) -replace '\x1b\[[0-9;]*[a-zA-Z]', ''
        foreach ($line in ($text -split "`r?`n")) {
            if ($line -match '^\|\s*(\S.*?)\s*\|\s*(Chat|Multimodal|Speech|Embedding)\s*\|\s*([\d.]+\s*[KMG]B)\s*\|\s*(NPU|GPU|CPU)\s*\|') {
                $loaded += [pscustomobject]@{ alias = $Matches[1]; size = $Matches[3]; device = $Matches[4] }
            }
        }
    }

    $result = [pscustomobject]@{
        capturedAt          = (Get-Date -Format 'o')
        onAcPower           = $onAc
        batteryPercent      = $percent
        batteryStatus       = $status
        powerScheme         = $scheme
        cpuBusyPercent      = $busy
        competing           = $competing
        backgroundConsumers = $hogs
        foundry             = [pscustomobject]@{ running = $daemon; loadedModels = $loaded }
        overrides           = @()
    }
    $script:Last = $result
    $result
}

function Get-AtlasConditionsSummary {
    [CmdletBinding()]
    param([Parameter(Mandatory)]$Conditions)
    $power = switch ($Conditions.onAcPower) { $true { 'AC' } $false { 'BATTERY' } default { 'power unknown' } }
    $others = @($Conditions.competing | ForEach-Object { $_.name })
    if ($Conditions.foundry.running) {
        $others += ('foundry daemon' + $(if (@($Conditions.foundry.loadedModels).Count) {
            ' (' + ((@($Conditions.foundry.loadedModels) | ForEach-Object { "$($_.alias) on $($_.device)" }) -join ', ') + ')' } else { '' }))
    }
    $cpu = if ($null -ne $Conditions.cpuBusyPercent) { "CPU busy $($Conditions.cpuBusyPercent) %" } else { 'CPU busy unknown' }
    "$power | $($Conditions.powerScheme) | $cpu | " + $(if ($others.Count) { 'running: ' + ($others -join ', ') } else { 'nothing else running' })
}

function Test-AtlasConditions {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]$Conditions,
        # Compute units the run needs exclusively: 'npu' makes a competing process a blocker.
        [string[]]$Needs = @(),
        [switch]$AllowBattery,
        # Processes or 'foundry' the caller expects and does not want flagged.
        [string[]]$Expect = @()
    )

    $blockers = [System.Collections.Generic.List[string]]::new()
    $warnings = [System.Collections.Generic.List[string]]::new()

    if ($Conditions.onAcPower -eq $false) {
        $what = "on battery ($($Conditions.batteryPercent) %, power scheme '$($Conditions.powerScheme)')"
        if ($AllowBattery) {
            $warnings.Add("$what; running anyway because of -AllowBattery, so the result is marked onAcPower = false and kept out of published figures")
        }
        else {
            $blockers.Add("$what. Plug in the charger, or pass -AllowBattery to run anyway and mark the result.")
        }
    }
    elseif ($null -eq $Conditions.onAcPower) {
        $warnings.Add('could not tell whether the laptop is on AC power')
    }

    $needsNpu = 'npu' -in $Needs
    foreach ($c in @($Conditions.competing | Where-Object { $_.name -notin $Expect })) {
        $what = "$($c.name) is running (pid $($c.pids -join ', '))" + $(if ($c.commandLine) { ": $($c.commandLine)" } else { '' })
        if ($needsNpu) { $blockers.Add("$what. It may hold the NPU, and only one process can. Stop it first.") }
        else { $warnings.Add("$what. It competes for the CPU.") }
    }

    foreach ($m in @($Conditions.foundry.loadedModels)) {
        if ($m.device -eq 'NPU' -and $needsNpu -and 'foundry' -notin $Expect) {
            $blockers.Add("Foundry has $($m.alias) loaded on the NPU. Unload it: foundry model unload $($m.alias)")
        }
        elseif ('foundry' -notin $Expect) {
            $warnings.Add("Foundry has $($m.alias) loaded on the $($m.device).")
        }
    }

    if ($null -ne $Conditions.cpuBusyPercent -and $Conditions.cpuBusyPercent -gt $script:BusyWarnPercent) {
        $warnings.Add("CPU is $($Conditions.cpuBusyPercent) % busy before the run starts")
    }
    foreach ($h in @($Conditions.backgroundConsumers)) {
        $warnings.Add("$($h.name) is using about $($h.cores) cores in the background")
    }

    [pscustomobject]@{ Ok = ($blockers.Count -eq 0); Blockers = $blockers.ToArray(); Warnings = $warnings.ToArray() }
}

function Assert-AtlasConditions {
    [CmdletBinding()]
    param(
        [string[]]$Needs = @(),
        [switch]$AllowBattery,
        [string[]]$Expect = @(),
        [ValidateRange(1, 30)][int]$Seconds = 3
    )

    $c = Get-AtlasConditions -Seconds $Seconds
    $r = Test-AtlasConditions -Conditions $c -Needs $Needs -AllowBattery:$AllowBattery -Expect $Expect
    Write-Host ("conditions: " + (Get-AtlasConditionsSummary -Conditions $c)) -ForegroundColor DarkGray
    foreach ($w in $r.Warnings) { Write-Host "  warning: $w" -ForegroundColor Yellow }
    if (-not $r.Ok) {
        foreach ($b in $r.Blockers) { Write-Host "  refusing: $b" -ForegroundColor Red }
        throw 'The conditions for a valid benchmark are not met (see above).'
    }
    if ($AllowBattery -and $c.onAcPower -eq $false) { $c.overrides = @('allowBattery') }
    # Stamp the records this run writes. Late-bound: the history module owns the cache.
    if (Get-Command Set-AtlasRunConditions -ErrorAction SilentlyContinue) { Set-AtlasRunConditions -Conditions $c }
    $c
}

Export-ModuleMember -Function Get-AtlasConditions, Get-AtlasConditionsSummary,
    Test-AtlasConditions, Assert-AtlasConditions
