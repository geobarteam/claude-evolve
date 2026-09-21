#Requires -Version 7.0
<#
.SYNOPSIS
    UserPromptSubmit hook: records the owner's session rating when the prompt is exactly "+", "-" or "- <reason>".

.DESCRIPTION
    Protected file. Wired in .claude/settings.json. Never blocks.
    Rating rule (deliberately narrow so ordinary prompts are never swallowed):
      "+"            -> positive
      "-"            -> negative
      "- <reason>"   -> negative with free-text reason (minus, whitespace, text)
    Anything else ("-1 doctor", "+ Add doctor page", "+1") is an ordinary prompt and produces no record.
    A recorded rating prints "Rating recorded." which Claude Code adds to the model's context.
#>
[CmdletBinding()]
param(
    [string] $InputJson,
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../scripts/lib/HookInput.psm1" -Force
Import-Module "$PSScriptRoot/../scripts/lib/Feedback.psm1" -Force

if (Test-HookSuppressed) { exit 0 }

$root = $null
try {
    $hookInput = Read-HookInput -InputJson $InputJson
    $prompt = [string] (Get-HookProperty -Object $hookInput -Name 'prompt' -Default '')

    $value = $null
    $reason = $null
    if ($prompt -match '^\s*\+\s*$') {
        $value = '+'
    }
    elseif ($prompt -match '^\s*-\s*$') {
        $value = '-'
    }
    elseif ($prompt -match '^\s*-\s+(\S.*)$') {
        $value = '-'
        $reason = $Matches[1].Trim()
    }

    if (-not $value) { exit 0 }

    $root = Resolve-RepoRoot -RepoRoot $RepoRoot -HookInput $hookInput
    $sessionId = [string] (Get-HookProperty -Object $hookInput -Name 'session_id' -Default 'unknown-session')
    $journal = Find-SessionJournal -RepoRoot $root -SessionId $sessionId
    $ref = if ($journal) { 'evolution/journal/' + $journal.Name } else { "transcript:$sessionId" }

    $params = @{
        RepoRoot  = $root
        SessionId = $sessionId
        Signal    = 'rating'
        Value     = $value
        Ref       = $ref
        Extra     = @{ weight = $(if ($value -eq '-') { 2 } else { 1 }) }
    }
    if ($reason) { $params.Reason = $reason }
    Write-FeedbackRecord @params

    Write-Output ("Rating recorded: {0}{1}" -f $value, $(if ($reason) { " ($reason)" } else { '' }))
    exit 0
}
catch {
    if ($root) { Write-HookError -RepoRoot $root -Hook 'UserPromptSubmit' -Message $_.Exception.Message }
    exit 0
}
