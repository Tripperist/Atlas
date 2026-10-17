<#
.SYNOPSIS
    The canary verdict: is the machine in the state that earlier AC runs measured?

.DESCRIPTION
    A short fixed run (Invoke-BenchCanary.ps1) is compared with the median of earlier runs of
    the same cell that were measured on AC power and were themselves healthy. Pure functions,
    so the rules can be tested without a machine in a bad state.

    The levels are ratios of the current figure to the reference:

        ok       at or above WarnBelow             (default 0.85)
        warn     below WarnBelow, at or above AbortBelow
        abort    below AbortBelow                  (default 0.60)

    The defaults are PROVISIONAL. They were chosen before there was any AC data to set them
    from: the failures seen so far were a 3x slowdown on battery (ratio about 0.33) and a
    half-speed state (about 0.5), which 0.60 catches, and 0.85 leaves room for the 3 to 7 %
    run-to-run spread the controls showed. They should be revisited when the history holds
    enough AC canary runs to measure the real spread.

    With fewer than MinReference earlier runs there is no reference, and the verdict is
    'no-reference': the run is recorded and nothing is gated on it.
#>
#requires -Version 7

function Get-AtlasCanaryReference {
    <#
    .SYNOPSIS
        The records that may serve as the reference: canary kind, valid, on AC power, healthy.
    .PARAMETER Records
        History records. Callers pass the whole history; the filtering is here so it is tested.
    #>
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Records,
        [Parameter(Mandatory)][string]$Model,
        [Parameter(Mandatory)][int]$PromptTokens
    )
    @($Records | Where-Object {
        $_.kind -eq 'canary' -and $_.valid -ne $false -and $_.onAcPower -eq $true -and
        $_.model -eq $Model -and $_.promptTokens -eq $PromptTokens -and
        $_.canaryVerdict -notin 'warn', 'abort'
    } | Sort-Object { [datetime]$_.ts })
}

function Get-AtlasCanaryVerdict {
    <#
    .PARAMETER Current
        One object per configuration: Config (cpu, gpu), Prefill, Decode (tok/s).
    .PARAMETER Reference
        Reference records, from Get-AtlasCanaryReference. `compute` ends in /<config>.
    .PARAMETER Runs
        How many earlier runs the median is taken over.
    #>
    param(
        [Parameter(Mandatory)][object[]]$Current,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]]$Reference,
        [double]$WarnBelow = 0.85,
        [double]$AbortBelow = 0.60,
        [int]$MinReference = 3,
        [int]$Runs = 5
    )
    $rows = foreach ($c in $Current) {
        $refs = @($Reference | Where-Object { $_.compute -like "*/$($c.Config)" } | Sort-Object { [datetime]$_.ts } | Select-Object -Last $Runs)
        foreach ($m in @(@{ Name = 'prefill'; Prop = 'prefillTps'; Cur = $c.Prefill }, @{ Name = 'decode'; Prop = 'tokPerSec'; Cur = $c.Decode })) {
            $vals = @($refs | Where-Object { $null -ne $_.($m.Prop) } | ForEach-Object { [double]$_.($m.Prop) } | Sort-Object)
            $median = $null; $ratio = $null
            if ($vals.Count) {
                $mid = [int][math]::Floor($vals.Count / 2)
                $median = if ($vals.Count % 2) { $vals[$mid] } else { ($vals[$mid - 1] + $vals[$mid]) / 2 }
                if ($median -gt 0) { $ratio = $m.Cur / $median }
            }
            $level = if ($vals.Count -lt $MinReference -or $null -eq $ratio) { 'no-reference' }
                     elseif ($ratio -lt $AbortBelow) { 'abort' } elseif ($ratio -lt $WarnBelow) { 'warn' } else { 'ok' }
            [pscustomobject]@{ Config = $c.Config; Metric = $m.Name; Current = $m.Cur; Reference = $median; Ratio = $ratio; Count = $vals.Count; Level = $level }
        }
    }
    $levels = @($rows.Level)
    $verdict = if ('abort' -in $levels) { 'abort' } elseif ('warn' -in $levels) { 'warn' } elseif ($levels -and @($levels | Where-Object { $_ -eq 'no-reference' }).Count -eq $levels.Count) { 'no-reference' } else { 'ok' }
    $worst = $rows | Where-Object { $null -ne $_.Ratio } | Sort-Object Ratio | Select-Object -First 1
    [pscustomobject]@{ Verdict = $verdict; Rows = @($rows); Worst = $worst; WarnBelow = $WarnBelow; AbortBelow = $AbortBelow }
}

Export-ModuleMember -Function Get-AtlasCanaryReference, Get-AtlasCanaryVerdict
