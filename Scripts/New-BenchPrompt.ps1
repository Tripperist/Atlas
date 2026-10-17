<#
.SYNOPSIS
    Build a deterministic long prompt of a target size from pinned repository text.

.DESCRIPTION
    Context-length benchmarks need prompts of known length that can be rebuilt byte
    for byte. A prompt typed into a scratch file cannot, and one built from the
    working tree changes with every commit.

    The text comes from a fixed list of files read from a PINNED git revision
    (`git show <rev>:<path>`), so the same -Rev and -Tokens always give the same
    bytes. LF line endings, UTF-8 without a BOM, cut at a line boundary (or a space, inside a long paragraph), with a short
    instruction at the END, so the model has to read all of it before it can answer.

    -Tokens is a TARGET. The length in characters is Tokens x 3.3, which is what this
    corpus measured on the Qwen2.5 tokenizer (1,152 tokens for a 3,789-character
    prompt built for 1,024 at 3.7). It is a code-and-table-heavy text, and another
    tokenizer will differ by several percent. The harnesses that can report an exact count do: the Foundry
    HTTP endpoint returns `usage.prompt_tokens`. Label results with the count a run
    reports, not with this target.

    The prompt is cached under .atlas-local/benchmarks/prompts/ with a JSON sidecar
    (SHA256, revision, files, characters). A harness that records `promptSha256` makes
    a changed prompt visible in the history.

    The corpus contains non-ASCII characters (arrows, dashes). That is deliberate:
    a request body with them is what exposed the Windows PowerShell 5.1 encoding
    failure, so a long prompt should exercise it. Pass -AsciiOnly to replace them.

.PARAMETER Tokens
    Target prompt length in tokens.

.PARAMETER Rev
    Git revision the text is read from. Change it only on purpose: it changes every prompt.

.PARAMETER AsciiOnly
    Replace non-ASCII characters with ASCII equivalents (or '?').

.PARAMETER Force
    Rebuild even if a cached prompt exists.

.OUTPUTS
    An object with Path, Sha256, Chars, TargetTokens, Rev and Files.

.EXAMPLE
    .\Scripts\New-BenchPrompt.ps1 -Tokens 4096

.EXAMPLE
    (.\Scripts\New-BenchPrompt.ps1 -Tokens 8192).Path
#>
#requires -Version 7
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(128, 200000)][int]$Tokens,
    [string]$Rev = 'f1f890f',
    [switch]$AsciiOnly,
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$CharsPerToken = 3.3
$Instruction = "`n`n---`nThe text above is documentation and source from a software repository. " +
               "Explain in a short paragraph what the repository is for and which parts matter most.`n"

# Order matters: it is part of what makes the prompt reproducible.
$Corpus = @(
    'README.md', 'docs/BENCHMARKS.md', 'docs/BENCHMARK-HARNESS-PLAN.md',
    'Scripts/Update-Workspace.ps1', 'Scripts/Invoke-Benchmark.ps1', 'Scripts/AtlasBaseline.psm1',
    'Scripts/AtlasConditions.psm1', 'Scripts/Invoke-FoundryBench.ps1', 'Scripts/Invoke-PrefillBench.ps1'
)

# Read the blob as UTF-8 bytes. Piping git's output through PowerShell decodes it with the
# console code page (IBM437 here), which turns an em dash into three other characters.
function Read-GitBlob([string]$File) {
    $psi = [System.Diagnostics.ProcessStartInfo]::new('git')
    foreach ($a in '-C', $root, 'show', "${Rev}:$File") { $psi.ArgumentList.Add($a) }
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.StandardOutputEncoding = [System.Text.UTF8Encoding]::new($false)
    $p = [System.Diagnostics.Process]::Start($psi)
    $text = $p.StandardOutput.ReadToEnd()
    $null = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    if ($p.ExitCode -ne 0 -or -not $text) { throw "git show ${Rev}:$File failed; is the revision in this clone?" }
    $text
}

$chars = [int][math]::Round($Tokens * $CharsPerToken)
$dir = Join-Path $root '.atlas-local/benchmarks/prompts'
$kind = if ($AsciiOnly) { 'ascii' } else { 'utf8' }
$name = "repo-$($Rev.Substring(0, [math]::Min(7, $Rev.Length)))-$kind-$Tokens"
$path = Join-Path $dir "$name.txt"
$meta = Join-Path $dir "$name.json"

if (-not $Force -and (Test-Path $path) -and (Test-Path $meta)) {
    return (Get-Content $meta -Raw | ConvertFrom-Json)
}

$parts = [System.Collections.Generic.List[string]]::new()
$used = [System.Collections.Generic.List[string]]::new()
$have = 0
$cutShort = $false
$budget = $chars - $Instruction.Length
foreach ($file in $Corpus) {
    if ($used.Count -gt 0 -and $budget - $have -lt 400) { break }   # a header and a line or two is not worth another file
    $text = Read-GitBlob $file
    $text = $text -replace "`r`n", "`n"
    if ($AsciiOnly) {
        $text = [regex]::Replace($text, '[^\x00-\x7F]', {
            param($m)
            switch ([int][char]$m.Value) { 0x2014 { '-' } 0x2013 { '-' } 0x2192 { '->' } 0x00D7 { 'x' } 0x2019 { "'" } default { '?' } }
        })
    }
    $parts.Add("=== $file ===`n")
    $have += $parts[-1].Length
    $room = $budget - $have
    if ($text.Length -gt $room) {
        $cutShort = $true
        $cut = $text.LastIndexOf("`n", [math]::Max(0, $room - 1))
        # No line break close enough (a short prompt that ends inside a long paragraph): cut at a space.
        if ($cut -lt $room * 0.5) { $cut = $text.LastIndexOf(' ', [math]::Max(0, $room - 1)) }
        $text = if ($cut -gt 0) { $text.Substring(0, $cut + 1) } else { '' }
    }
    $parts.Add($text)
    $have += $text.Length
    $used.Add($file)
}
if (-not $cutShort -and $have -lt $budget * 0.95) {
    throw "The corpus at $Rev has only $have characters; $Tokens tokens needs about $chars."
}

$body = ($parts -join '') + $Instruction
New-Item -ItemType Directory -Force -Path $dir | Out-Null
[System.IO.File]::WriteAllText($path, $body, [System.Text.UTF8Encoding]::new($false))
$sha = (Get-FileHash $path -Algorithm SHA256).Hash.ToLower()

$result = [pscustomobject]@{
    Path = $path; Sha256 = $sha; Chars = $body.Length; TargetTokens = $Tokens
    CharsPerToken = $CharsPerToken; Rev = $Rev; Kind = $kind; Files = @($used)
}
$result | ConvertTo-Json | Set-Content $meta -Encoding utf8
$result
