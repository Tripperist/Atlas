<#
.SYNOPSIS
    Helpers for benchmarking Foundry Local over its OpenAI-compatible endpoint.

.DESCRIPTION
    Shared by Invoke-BenchFoundryContext.ps1. Invoke-BenchFoundry.ps1 predates it and
    keeps its own copy of the endpoint discovery.

    Rules the helpers keep, each learned from a wrong number:

      * A request body is sent as UTF-8 BYTES. Windows PowerShell 5.1 mangles a non-ASCII
        string body, and the daemon answered HTTP 500 with a JSON deserialization error;
        the first non-ASCII character was at index 13,676.
      * `max_tokens` is never below 64. A small `max_tokens` relative to the prompt fails in
        GroupQueryAttention with HTTP 500 (README, Open questions: a 64-token prompt needs
        32 or more, a 256-token prompt 64 or more), and the failure has been followed by the
        daemon stopping answering. A 1,408-token prompt worked at 16 and failed at 8, so the
        rule is not a simple one; 64 is simply the value that has always worked.
      * Requests are stateless, so no run carries an earlier run's conversation forward.
      * The daemon is stopped only if this code started it. One that was already running
        belongs to someone else and is left as it was.
#>
#requires -Version 7

function Start-FoundryDaemon {
    <#
    .SYNOPSIS
        Make sure the Foundry daemon is up; say whether this call started it.
    #>
    [CmdletBinding()]
    param()
    $was = [bool](Get-Process -Name foundrylocald -ErrorAction SilentlyContinue)
    $startOut = (foundry server start 2>&1 | Out-String) -replace '\x1b\[[0-9;]*[a-zA-Z]', ''
    $status = (foundry status 2>&1 | Out-String) -replace '\x1b\[[0-9;]*[a-zA-Z]', ''
    $endpoint = $null
    foreach ($text in @($startOut, $status)) {
        $m = [regex]::Match($text, 'http://127\.0\.0\.1:(\d+)')
        if ($m.Success) { $endpoint = $m.Value; break }
    }
    if (-not $endpoint) { throw "Could not determine the Foundry endpoint. $($startOut.Trim())" }
    [pscustomobject]@{ Endpoint = $endpoint; StartedByUs = (-not $was) }
}

function Resolve-FoundryVariant {
    <#
    .SYNOPSIS
        Turn an alias (optionally `alias@npu`, `alias@gpu`, `alias@cpu`) into a variant id.
    .DESCRIPTION
        The CLI takes an alias but the OpenAI API wants the concrete variant id, which
        appears only as `parent` on the catalogue entry. Passing an alias gives a bare 400.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string]$Endpoint, [Parameter(Mandatory)][string]$Spec)

    $alias, $unit = $Spec -split '@', 2
    $pattern = switch ($unit) { 'npu' { 'qnn-npu' } 'gpu' { 'generic-gpu' } 'cpu' { 'generic-cpu' } default { $null } }
    if ($unit -and -not $pattern) { throw "Unknown unit '@$unit' in '$Spec'; use @npu, @gpu or @cpu." }

    $ids = @((Invoke-RestMethod -Uri "$Endpoint/v1/models" -TimeoutSec 60).data)
    $exact = @($ids | Where-Object { $_.id -eq $alias })
    if ($exact.Count) { return [pscustomobject]@{ Alias = $alias; Id = $exact[0].id; Unit = (Get-FoundryUnit $exact[0].id) } }

    $match = @($ids | Where-Object { $_.parent -eq $alias })
    if ($pattern) { $match = @($match | Where-Object { $_.id -match $pattern }) }
    elseif ($match.Count -gt 1) {
        $npu = @($match | Where-Object { $_.id -match 'qnn-npu' })
        if ($npu.Count) { $match = $npu }
    }
    if (-not $match.Count) {
        throw "No downloaded variant of '$Spec'. Download one with: foundry model download $alias"
    }
    [pscustomobject]@{ Alias = $alias; Id = $match[0].id; Unit = (Get-FoundryUnit $match[0].id) }
}

function Get-FoundryUnit {
    param([string]$VariantId)
    switch -Regex ($VariantId) { 'qnn-npu' { 'npu' } 'generic-gpu' { 'gpu' } 'generic-cpu' { 'cpu' } default { 'auto' } }
}

function Get-FoundryLoadedAliases {
    <# Aliases the daemon has loaded: the first cell of each row of `foundry model list --loaded`. #>
    $text = (foundry model list --loaded 2>&1 | Out-String) -replace '\[[0-9;]*[a-zA-Z]', ''
    @($text -split "`r?`n" | Where-Object { $_ -match '^\|' } |
        ForEach-Object { ($_ -split '\|')[1].Trim() } |
        Where-Object { $_ -and $_ -ne 'Model Name' -and $_ -notmatch '^[-+]+$' })
}

function New-FoundryChatBody {
    param([string]$Model, [string]$Prompt, [int]$MaxTokens, [switch]$Stream)
    if ($MaxTokens -lt 64) { throw 'max_tokens below 64 can fail on Foundry (HTTP 500, GroupQueryAttention).' }
    $body = @{
        model       = $Model
        messages    = @(@{ role = 'user'; content = $Prompt })
        max_tokens  = $MaxTokens
        temperature = 0
    }
    if ($Stream) { $body.stream = $true; $body.stream_options = @{ include_usage = $true } }
    # The leading comma keeps the pipeline from unrolling the bytes into an object[], which
    # Invoke-RestMethod would send as text.
    , [System.Text.Encoding]::UTF8.GetBytes(($body | ConvertTo-Json -Depth 5 -Compress))
}

function Invoke-FoundryStream {
    <#
    .SYNOPSIS
        One stateless, streamed request: time to first token and the decode rate after it.
    .DESCRIPTION
        Decode tok/s is (tokens - 1) over the time between the first and last content
        chunk, so the prefill is not counted in it. Tokens come from the usage chunk when
        the server sends one, else from the number of content chunks. The usage chunk also
        gives the EXACT prompt length, and prompt_tokens over FirstTokenS is the prefill rate
        (the time includes producing the first token and the HTTP hop).
    #>
    [CmdletBinding()]
    param([string]$Endpoint, [string]$Model, [string]$Prompt, [int]$MaxTokens = 256)

    $bytes = New-FoundryChatBody -Model $Model -Prompt $Prompt -MaxTokens $MaxTokens -Stream
    $client = [System.Net.Http.HttpClient]::new()
    $client.Timeout = [TimeSpan]::FromMinutes(30)
    try {
        $req = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Post, "$Endpoint/v1/chat/completions")
        $req.Content = [System.Net.Http.ByteArrayContent]::new($bytes)
        $req.Content.Headers.ContentType = [System.Net.Http.Headers.MediaTypeHeaderValue]::new('application/json')
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $resp = $client.Send($req, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead)
        if (-not $resp.IsSuccessStatusCode) { throw "HTTP $([int]$resp.StatusCode): $($resp.Content.ReadAsStringAsync().Result)" }
        $reader = [System.IO.StreamReader]::new($resp.Content.ReadAsStream(), [System.Text.Encoding]::UTF8)

        $first = $null; $last = $null; $chunks = 0; $usage = $null
        while ($null -ne ($line = $reader.ReadLine())) {
            if (-not $line.StartsWith('data:')) { continue }
            $payload = $line.Substring(5).Trim()
            if ($payload -eq '[DONE]') { break }
            $obj = $payload | ConvertFrom-Json
            if ($obj.usage) { $usage = $obj.usage }
            $text = if ($obj.choices -and $obj.choices[0].delta) { $obj.choices[0].delta.content } else { $null }
            if ($text) {
                $t = $sw.Elapsed.TotalSeconds
                if ($null -eq $first) { $first = $t }
                $last = $t; $chunks++
            }
        }
        $total = $sw.Elapsed.TotalSeconds
    }
    finally { $client.Dispose() }

    if ($null -eq $first) { throw 'The stream produced no content.' }
    $tokens = if ($usage -and $usage.completion_tokens) { [int]$usage.completion_tokens } else { $chunks }
    [pscustomobject]@{
        FirstTokenS = $first; TotalS = $total; Tokens = $tokens
        PromptTokens = $(if ($usage) { [int]$usage.prompt_tokens } else { $null })
        DecodeTps = $(if ($last -gt $first -and $tokens -gt 1) { ($tokens - 1) / ($last - $first) } else { 0 })
        UsageReported = [bool]$usage
    }
}

Export-ModuleMember -Function Start-FoundryDaemon, Resolve-FoundryVariant, Get-FoundryUnit, Get-FoundryLoadedAliases,
    Invoke-FoundryStream
