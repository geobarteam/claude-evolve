#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    Stop hook: refuses to let a turn end until the session's journal entry exists and is current.

.DESCRIPTION
    Protected file. Wired in .claude/settings.json. Fires after every assistant turn.
    - stop_hook_active = true  → exit 0 silently (Claude Code set it because this hook already blocked once; avoids loops).
    - No journal whose first line is "<!-- session: <session_id> -->" → block with instructions.
    - Journal older than the owner's last prompt (from the transcript) → block asking for an update.
    - Otherwise exit 0 with no output.
    Blocking is signalled by {"decision":"block","reason":"..."} on stdout with exit code 0.
    Errors never block: they go to evolution/.state/hook-errors.log (under the project) and the hook exits 0.
#>
[CmdletBinding()]
param(
    [string] $InputJson,
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../scripts/lib/HookInput.psm1" -Force
Import-Module "$PSScriptRoot/../scripts/lib/Transcript.psm1" -Force

function Write-Block {
    param([Parameter(Mandatory)] [string] $Reason)
    Write-Output (@{ decision = 'block'; reason = $Reason } | ConvertTo-Json -Compress)
}

if (Test-HookSuppressed) { exit 0 }

$root = $null
try {
    $hookInput = Read-HookInput -InputJson $InputJson
    if ([bool](Get-HookProperty -Object $hookInput -Name 'stop_hook_active' -Default $false)) {
        exit 0
    }

    $root = Resolve-RepoRoot -RepoRoot $RepoRoot -HookInput $hookInput
    $sessionId = [string] (Get-HookProperty -Object $hookInput -Name 'session_id' -Default 'unknown-session')
    $marker = "<!-- session: $sessionId -->"

    $journal = Find-SessionJournal -RepoRoot $root -SessionId $sessionId

    if (-not $journal) {
        $name = Get-JournalFileName -RepoRoot $root -SessionId $sessionId
        Write-Block -Reason ("No journal entry exists for session $sessionId. Create evolution/journal/$name from evolution/journal/TEMPLATE.md: " +
            "first line exactly '$marker', then fill Task, Outcome (done | partial | abandoned), What worked, What I fought against, " +
            "What I wished I had, Beliefs to revise. Then finish your turn.")
        exit 0
    }

    $lastUser = $null
    $transcriptPath = [string] (Get-HookProperty -Object $hookInput -Name 'transcript_path' -Default '')
    if ($transcriptPath -and (Test-Path -LiteralPath $transcriptPath)) {
        $lastUser = Get-LastUserTimestamp -Path $transcriptPath
    }

    if ($lastUser -and $journal.LastWriteTimeUtc -lt $lastUser) {
        Write-Block -Reason ("The journal evolution/journal/$($journal.Name) for session $sessionId is older than the owner's last prompt. " +
            "Update it so it reflects this turn (Outcome, What worked, What I fought against, What I wished I had, Beliefs to revise), then finish your turn.")
        exit 0
    }

    exit 0
}
catch {
    if ($root) { Write-HookError -RepoRoot $root -Hook 'Stop' -Message $_.Exception.Message }
    exit 0
}
