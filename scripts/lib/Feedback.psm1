#Requires -Version 7.0
<#
.SYNOPSIS
    Feedback store and transcript-signal extraction.

.DESCRIPTION
    Protected file. Writes one JSONL record per event to evolution/feedback/<yyyy-MM-dd>.jsonl:
      { ts, session_id, signal, value, reason?, ref, ...extra }
    Transcript signals (correction | frustration | praise | question | abandonment) are produced by a fixed-rubric
    classifier call (`claude -p --bare`) over owner prompts paired with the agent action that preceded them.
    Owner text is stored verbatim. Nothing here matches keywords in production; the model applies the rubric.
#>

Set-StrictMode -Version Latest

# Nested imports without -Force: forcing here would unload the caller's already-imported copies.
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Transcript.psm1')
Import-Module (Join-Path $PSScriptRoot 'HookInput.psm1')

$script:Labels = @('correction', 'frustration', 'praise', 'question', 'none')
$script:Weights = @{ frustration = 2; abandonment = 2; correction = 1; praise = 1; question = 1; none = 0 }
$script:MaxActionLength = 600

# Errors inside module functions must surface to the caller's try/catch (hooks log them and exit 0).
$ErrorActionPreference = 'Stop'

function Write-FeedbackRecord {
    <#
    .SYNOPSIS
        Appends one record to today's feedback JSONL (UTC date). Never overwrites.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $Signal,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [string] $Reason,
        [Parameter(Mandatory)] [string] $Ref,
        [hashtable] $Extra
    )

    $dir = Join-Path $RepoRoot 'evolution/feedback'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    $record = [ordered]@{
        ts         = [datetime]::UtcNow.ToString('o')
        session_id = $SessionId
        signal     = $Signal
        value      = $Value
    }
    if ($PSBoundParameters.ContainsKey('Reason') -and -not [string]::IsNullOrEmpty($Reason)) {
        $record.reason = $Reason
    }
    $record.ref = $Ref
    if ($Extra) {
        foreach ($key in $Extra.Keys) { $record[$key] = $Extra[$key] }
    }

    $path = Join-Path $dir ('{0:yyyy-MM-dd}.jsonl' -f [datetime]::UtcNow)
    Add-Content -LiteralPath $path -Value ($record | ConvertTo-Json -Compress -Depth 8) -Encoding utf8
}

function Get-PairedOwnerTurns {
    <#
    .SYNOPSIS
        Pairs every owner prompt with the agent action (text + tool names) that preceded it.
    .OUTPUTS
        [pscustomobject] Index (1-based), OwnerUuid, OwnerText, Timestamp, AgentUuid, AgentAction
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Records
    )

    $ownerByUuid = @{}
    foreach ($turn in @(Get-UserTurns -Records $Records)) { $ownerByUuid[[string] $turn.Uuid] = $turn }
    $agentByUuid = @{}
    foreach ($turn in @(Get-AssistantTurns -Records $Records)) { $agentByUuid[[string] $turn.Uuid] = $turn }

    $pairs = [System.Collections.Generic.List[object]]::new()
    $lastAgent = $null
    foreach ($record in $Records) {
        $uuid = [string] (Get-RecordUuid $record)
        if (-not $uuid) { continue }

        if ($agentByUuid.ContainsKey($uuid)) {
            $agent = $agentByUuid[$uuid]
            $action = $agent.Text
            if ($agent.ToolUses.Count -gt 0) {
                $action = ($action + ' [tools: ' + ($agent.ToolUses -join ', ') + ']').Trim()
            }
            if (-not [string]::IsNullOrWhiteSpace($action)) {
                $lastAgent = [pscustomobject]@{ Uuid = $uuid; Action = $action }
            }
            continue
        }

        if ($ownerByUuid.ContainsKey($uuid)) {
            $owner = $ownerByUuid[$uuid]
            $pairs.Add([pscustomobject]@{
                    Index       = $pairs.Count + 1
                    OwnerUuid   = $uuid
                    OwnerText   = $owner.Text
                    Timestamp   = $owner.Timestamp
                    AgentUuid   = if ($lastAgent) { $lastAgent.Uuid } else { $null }
                    AgentAction = if ($lastAgent) { Limit-Length $lastAgent.Action } else { $null }
                })
        }
    }

    return $pairs.ToArray()
}

function New-ClassifierPrompt {
    <#
    .SYNOPSIS
        Pure function: rubric + belief titles + numbered pairs. Unit-testable without a model.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Pairs,
        [Parameter(Mandatory)] [string] $RubricPath,
        [string[]] $BeliefTitles = @()
    )

    $sb = [System.Text.StringBuilder]::new()
    [void] $sb.AppendLine((Get-Content -LiteralPath $RubricPath -Raw))
    [void] $sb.AppendLine()
    [void] $sb.AppendLine('## MEMORY.md belief titles available to the agent')
    if ($BeliefTitles.Count -eq 0) { [void] $sb.AppendLine('(none)') }
    foreach ($title in $BeliefTitles) { [void] $sb.AppendLine("- $title") }
    [void] $sb.AppendLine()
    [void] $sb.AppendLine('## Pairs to classify')
    foreach ($pair in $Pairs) {
        $agent = if ($pair.AgentAction) { $pair.AgentAction -replace "`r?`n", ' ' } else { '(no preceding agent action)' }
        $owner = $pair.OwnerText -replace "`r?`n", ' '
        [void] $sb.AppendLine("[$($pair.Index)] AGENT: $agent")
        [void] $sb.AppendLine("[$($pair.Index)] OWNER: $owner")
        [void] $sb.AppendLine()
    }
    [void] $sb.AppendLine('Respond with the JSON object only.')

    return $sb.ToString()
}

function Invoke-Classifier {
    <#
    .SYNOPSIS
        Classifies paired owner turns with one headless Claude call under the fixed rubric.
    .OUTPUTS
        [pscustomobject] Index, OwnerUuid, OwnerText, AgentUuid, AgentAction, Label, Reason, Weight
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyCollection()] [object[]] $Pairs,
        [Parameter(Mandatory)] [string] $RubricPath,
        [string] $ClaudeCommand = 'claude',
        [string] $Model = 'haiku',
        [string[]] $BeliefTitles = @()
    )

    if ($Pairs.Count -eq 0) { return @() }

    $prompt = New-ClassifierPrompt -Pairs $Pairs -RubricPath $RubricPath -BeliefTitles $BeliefTitles
    $schema = @{
        type       = 'object'
        properties = @{
            classifications = @{
                type  = 'array'
                items = @{
                    type       = 'object'
                    properties = @{
                        index  = @{ type = 'integer' }
                        label  = @{ type = 'string'; enum = $script:Labels }
                        reason = @{ type = 'string' }
                    }
                    required   = @('index', 'label', 'reason')
                }
            }
        }
        required   = @('classifications')
    } | ConvertTo-Json -Depth 10 -Compress

    $command = Resolve-ClaudeCommand -ClaudeCommand $ClaudeCommand
    # No --bare: it also skips the keychain, which leaves the CLI "Not logged in". Recursion into this project's
    # hooks is prevented by EVOLUTION_CLASSIFIER=1, which every hook under .claude/hooks/ honours by exiting at once.
    $arguments = @('-p', $prompt, '--no-session-persistence', '--model', $Model, '--output-format', 'json', '--json-schema', $schema)
    $previousGuard = $env:EVOLUTION_CLASSIFIER
    try {
        $env:EVOLUTION_CLASSIFIER = '1'
        $raw = (& $command @arguments | Out-String)
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($null -eq $previousGuard) { Remove-Item Env:\EVOLUTION_CLASSIFIER -ErrorAction SilentlyContinue } else { $env:EVOLUTION_CLASSIFIER = $previousGuard }
    }
    if ($exitCode -ne 0) {
        $detail = ''
        try { $detail = ([string] ($raw | ConvertFrom-Json -Depth 8).result) } catch { $detail = $raw.Trim() }
        throw "Classifier command '$command' exited with code $exitCode. $detail"
    }

    $parsed = ConvertFrom-ClassifierOutput -Raw $raw
    $byIndex = @{}
    foreach ($c in @($parsed.classifications)) { $byIndex[[int] $c.index] = $c }

    $results = foreach ($pair in $Pairs) {
        $label = 'none'
        $reason = 'not classified'
        if ($byIndex.ContainsKey([int] $pair.Index)) {
            $c = $byIndex[[int] $pair.Index]
            $candidate = ([string] $c.label).Trim().ToLowerInvariant()
            if ($candidate -in $script:Labels) { $label = $candidate }
            $reason = [string] $c.reason
        }

        [pscustomobject]@{
            Index       = $pair.Index
            OwnerUuid   = $pair.OwnerUuid
            OwnerText   = $pair.OwnerText
            AgentUuid   = $pair.AgentUuid
            AgentAction = $pair.AgentAction
            Label       = $label
            Reason      = $reason
            Weight      = $script:Weights[$label]
        }
    }

    return @($results)
}

function Resolve-ClaudeCommand {
    <#
    .SYNOPSIS
        Picks a runnable Claude CLI. Precedence: explicit path or non-default name, $env:CLAUDE_CLI, then the first
        `claude.exe` application on PATH (skipping the npm .ps1/.cmd shims, which are broken on this machine), then 'claude'.
    #>
    [CmdletBinding()]
    param([string] $ClaudeCommand = 'claude')

    if ($ClaudeCommand -ne 'claude') { return $ClaudeCommand }
    if ($env:CLAUDE_CLI -and (Test-Path -LiteralPath $env:CLAUDE_CLI)) { return $env:CLAUDE_CLI }

    $exe = Get-Command claude -All -CommandType Application -ErrorAction SilentlyContinue |
        Where-Object { $_.Source -like '*.exe' } |
        Select-Object -First 1
    if ($exe) { return $exe.Source }

    return 'claude'
}

function Invoke-SessionFeedback {
    <#
    .SYNOPSIS
        Full per-session extraction: classify owner turns, detect abandonment, write records, mark processed.
        Idempotent per session id. Throws on classifier failure so the caller can log and retry later.
    .OUTPUTS
        [int] number of records written
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $SessionId,
        [Parameter(Mandatory)] [string] $TranscriptPath,
        [string] $ClaudeCommand = 'claude',
        [string] $Model = 'haiku',
        [string] $RubricPath = "$PSScriptRoot/../evolver/rubric.md"
    )

    if (Test-SessionProcessed -RepoRoot $RepoRoot -SessionId $SessionId) { return 0 }

    $records = @(Read-Transcript -Path $TranscriptPath)
    $pairs = @(Get-PairedOwnerTurns -Records $records)
    $journal = Find-SessionJournal -RepoRoot $RepoRoot -SessionId $SessionId
    $journalRef = if ($journal) { 'evolution/journal/' + $journal.Name } else { $null }
    $written = 0

    if ($pairs.Count -gt 0) {
        $titles = @(Get-BeliefTitles -RepoRoot $RepoRoot)
        $results = @(Invoke-Classifier -Pairs $pairs -RubricPath $RubricPath -ClaudeCommand $ClaudeCommand -Model $Model -BeliefTitles $titles)

        foreach ($r in $results) {
            if ($r.Label -eq 'none') { continue }
            $ref = if ($journalRef) { $journalRef } else { "transcript:$SessionId#$($r.OwnerUuid)" }
            Write-FeedbackRecord -RepoRoot $RepoRoot -SessionId $SessionId -Signal $r.Label -Value $r.OwnerText -Reason $r.Reason -Ref $ref -Extra @{
                agent_action = $r.AgentAction
                owner_uuid   = $r.OwnerUuid
                weight       = $r.Weight
            }
            $written++
        }
    }

    $outcome = if ($journal) { Get-JournalOutcome -Path $journal.FullName } else { $null }
    $abandoned = (-not $journal) -or [string]::IsNullOrWhiteSpace($outcome) -or ($outcome -match '^\s*abandoned')
    if ($abandoned -and $records.Count -gt 0) {
        $lastAgent = @(Get-AssistantTurns -Records $records | Where-Object { -not [string]::IsNullOrWhiteSpace($_.Text) }) | Select-Object -Last 1
        $value = if ($lastAgent) { Limit-Length $lastAgent.Text } else { '(no agent output)' }
        $reason = if (-not $journal) { 'no journal entry for the session' } elseif ([string]::IsNullOrWhiteSpace($outcome)) { 'journal has no Outcome' } else { 'journal outcome is abandoned' }
        $ref = if ($journalRef) { $journalRef } else { "transcript:$SessionId" }
        Write-FeedbackRecord -RepoRoot $RepoRoot -SessionId $SessionId -Signal 'abandonment' -Value $value -Reason $reason -Ref $ref -Extra @{ weight = $script:Weights['abandonment'] }
        $written++
    }

    Set-SessionProcessed -RepoRoot $RepoRoot -SessionId $SessionId
    return $written
}

function Test-SessionProcessed {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $SessionId)

    Test-Path -LiteralPath (Join-Path $RepoRoot "evolution/.state/processed/$SessionId")
}

function Set-SessionProcessed {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [string] $SessionId)

    $dir = Join-Path (Get-StateDirectory -RepoRoot $RepoRoot) 'processed'
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    Set-Content -LiteralPath (Join-Path $dir $SessionId) -Value ([datetime]::UtcNow.ToString('o')) -Encoding utf8
}

function Get-BeliefTitles {
    <#
    .SYNOPSIS
        Bold titles of the bullets under "## Beliefs" in MEMORY.md.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $path = Join-Path $RepoRoot 'MEMORY.md'
    if (-not (Test-Path -LiteralPath $path)) { return @() }

    $inBeliefs = $false
    $titles = foreach ($line in Get-Content -LiteralPath $path) {
        if ($line -match '^##\s+(.*)$') { $inBeliefs = ($Matches[1].Trim() -eq 'Beliefs'); continue }
        if ($inBeliefs -and $line -match '^\s*-\s+\*\*(.+?)\*\*') { $Matches[1] }
    }

    return @($titles)
}

function Get-JournalOutcome {
    <#
    .SYNOPSIS
        First non-empty line under "## Outcome", or $null when the section is missing or empty.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $inOutcome = $false
    foreach ($line in Get-Content -LiteralPath $Path) {
        if ($line -match '^##\s+(.*)$') { $inOutcome = ($Matches[1].Trim() -eq 'Outcome'); continue }
        if ($inOutcome -and -not [string]::IsNullOrWhiteSpace($line) -and $line -notmatch '^\s*<') { return $line.Trim() }
    }

    return $null
}

function ConvertFrom-ClassifierOutput {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Raw)

    $text = $Raw.Trim()
    if (-not $text) { throw 'Classifier returned no output.' }

    $envelope = $null
    try { $envelope = $text | ConvertFrom-Json -Depth 32 } catch { $envelope = $null }

    if ($envelope -is [System.Array]) {
        # stream-json style: take the last object that carries a result.
        $envelope = @($envelope | Where-Object { $_.PSObject.Properties['result'] -or $_.PSObject.Properties['structured_output'] }) | Select-Object -Last 1
    }

    if ($envelope) {
        $structured = $envelope.PSObject.Properties['structured_output']
        if ($structured -and $structured.Value -and $structured.Value.PSObject.Properties['classifications']) { return $structured.Value }

        $result = $envelope.PSObject.Properties['result']
        if ($result -and $result.Value) {
            $inner = ConvertFrom-JsonLenient -Text ([string] $result.Value)
            if ($inner -and $inner.PSObject.Properties['classifications']) { return $inner }
        }

        if ($envelope.PSObject.Properties['classifications']) { return $envelope }
    }

    $fallback = ConvertFrom-JsonLenient -Text $text
    if ($fallback -and $fallback.PSObject.Properties['classifications']) { return $fallback }

    throw 'Classifier output did not contain a classifications object.'
}

function ConvertFrom-JsonLenient {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $candidate = $Text.Trim()
    $candidate = $candidate -replace '^```(?:json)?\s*', '' -replace '\s*```$', ''
    try { return ($candidate | ConvertFrom-Json -Depth 32) } catch { }

    $start = $candidate.IndexOf('{')
    $end = $candidate.LastIndexOf('}')
    if ($start -ge 0 -and $end -gt $start) {
        try { return ($candidate.Substring($start, $end - $start + 1) | ConvertFrom-Json -Depth 32) } catch { }
    }

    return $null
}

function Get-RecordUuid {
    [CmdletBinding()]
    param([AllowNull()] $Record)

    if ($null -eq $Record) { return $null }
    $property = $Record.PSObject.Properties['uuid']
    if ($null -eq $property) { return $null }
    return $property.Value
}

function Limit-Length {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $Text)

    if ($null -eq $Text) { return $null }
    if ($Text.Length -le $script:MaxActionLength) { return $Text }
    return $Text.Substring(0, $script:MaxActionLength) + '…'
}

Export-ModuleMember -Function Write-FeedbackRecord, Get-PairedOwnerTurns, New-ClassifierPrompt, Invoke-Classifier, Resolve-ClaudeCommand, Invoke-SessionFeedback, Test-SessionProcessed, Set-SessionProcessed, Get-BeliefTitles, Get-JournalOutcome
