# PSScriptAnalyzer settings for the Atlas PowerShell scripts.
# Run with Scripts/Test-BenchLint.ps1, or: Invoke-ScriptAnalyzer -Path Scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
#
# Errors and warnings only. Each excluded rule is excluded for a stated reason, so a
# new finding means something.
@{
    Severity     = @('Error', 'Warning')

    ExcludeRules = @(
        # These are interactive console tools and their output is the product. Write-Host
        # writes to the information stream, so the suite runner still captures it (*>&1).
        'PSAvoidUsingWriteHost'

        # Function names are domain nouns (Get-AtlasConditions, Get-Suites), not collections.
        'PSUseSingularNouns'

        # Internal helpers that build an object or a request body, and Start-FoundryDaemon,
        # which is a helper for the benchmark scripts and not a cmdlet for users.
        'PSUseShouldProcessForStateChangingFunctions'

        # The empty catches are best-effort probes: a performance counter that does not exist
        # yet, a process that exited while it was being read, a truncated last line in a
        # JSONL file. Failing there would make the benchmark worse, not safer.
        'PSAvoidUsingEmptyCatchBlock'

        # False positives. Start-Job script blocks here take their inputs through param() and
        # -ArgumentList, and parameters used only under $using: or in a nested scriptblock are
        # reported as unused.
        'PSUseUsingScopeModifierInNewRunspaces'
        'PSReviewUnusedParameter'
    )
}
