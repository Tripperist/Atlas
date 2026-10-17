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

    ONE FIGURE IS INFORMATION ONLY: CPU decode. It is shown with its ratio (level 'info') but
    does not decide the verdict. Over the first 12 AC readings (six runs, two rounds each) of the
    0.6B model, the spread (maximum minus minimum, over the mean) was:

        GPU decode    4 %    93.5 to 97.0 tok/s
        CPU prefill  19 %    1,363 to 1,662 tok/s
        GPU prefill  29 %    1,352 to 1,792 tok/s
        CPU decode   37 %    127 to 187 tok/s

    A warn line at 85 % on a figure that moves by more than a third between healthy runs would fire on
    noise, so CPU decode does not gate. GPU prefill and CPU prefill are noisier than they look
    comfortable with: their lowest readings were about 90 % of their means, so 85 % has little margin.
    These are 12 readings from one machine on one day: revisit the lines with more.
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
            # CPU decode is too noisy to gate on (see the description): shown, not counted.
            $gated = -not ($c.Config -eq 'cpu' -and $m.Name -eq 'decode')
            $vals = @($refs | Where-Object { $null -ne $_.($m.Prop) } | ForEach-Object { [double]$_.($m.Prop) } | Sort-Object)
            $median = $null; $ratio = $null
            if ($vals.Count) {
                $mid = [int][math]::Floor($vals.Count / 2)
                $median = if ($vals.Count % 2) { $vals[$mid] } else { ($vals[$mid - 1] + $vals[$mid]) / 2 }
                if ($median -gt 0) { $ratio = $m.Cur / $median }
            }
            $level = if ($vals.Count -lt $MinReference -or $null -eq $ratio) { 'no-reference' }
                     elseif (-not $gated) { 'info' }
                     elseif ($ratio -lt $AbortBelow) { 'abort' } elseif ($ratio -lt $WarnBelow) { 'warn' } else { 'ok' }
            [pscustomobject]@{ Config = $c.Config; Metric = $m.Name; Current = $m.Cur; Reference = $median; Ratio = $ratio; Count = $vals.Count; Level = $level; Gated = $gated }
        }
    }
    $levels = @($rows | Where-Object Gated | ForEach-Object Level)
    $verdict = if ('abort' -in $levels) { 'abort' } elseif ('warn' -in $levels) { 'warn' } elseif ($levels -and @($levels | Where-Object { $_ -eq 'no-reference' }).Count -eq $levels.Count) { 'no-reference' } else { 'ok' }
    $worst = $rows | Where-Object { $_.Gated -and $null -ne $_.Ratio } | Sort-Object Ratio | Select-Object -First 1
    [pscustomobject]@{ Verdict = $verdict; Rows = @($rows); Worst = $worst; WarnBelow = $WarnBelow; AbortBelow = $AbortBelow }
}

Export-ModuleMember -Function Get-AtlasCanaryReference, Get-AtlasCanaryVerdict
