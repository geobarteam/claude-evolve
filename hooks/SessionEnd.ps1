#Requires -Version 7.0
<#
.SYNOPSIS
    SessionEnd hook: extracts owner feedback signals from the session transcript into evolution/feedback/.

.DESCRIPTION
    Protected file. Wired in .claude/settings.json. Fires once when a session ends; it cannot block and never tries to.
    Runs the fixed-rubric classifier (one headless `claude -p --bare` call) over the owner's prompts, records
    correction / frustration / praise / question signals, and records abandonment when the session journal is
    missing, has no Outcome, or says abandoned. Idempotent per session (evolution/.state/processed/).
    Failures are logged to evolution/.state/hook-errors.log and the session stays unprocessed so
    evolution/feedback/Collect-DailyFeedback.ps1 retries it later.
#>
[CmdletBinding()]
param(
    [string] $InputJson,
    [string] $RepoRoot,
    [string] $ClaudeCommand = 'claude',
    [string] $Model = 'haiku'
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../scripts/lib/HookInput.psm1" -Force
Import-Module "$PSScriptRoot/../scripts/lib/Feedback.psm1" -Force

if (Test-HookSuppressed) { exit 0 }

$root = $null
try {
    $hookInput = Read-HookInput -InputJson $InputJson
    $root = Resolve-RepoRoot -RepoRoot $RepoRoot -HookInput $hookInput
    $sessionId = [string] (Get-HookProperty -Object $hookInput -Name 'session_id' -Default '')
    $transcriptPath = [string] (Get-HookProperty -Object $hookInput -Name 'transcript_path' -Default '')

    if (-not $sessionId -or -not $transcriptPath -or -not (Test-Path -LiteralPath $transcriptPath)) {
        exit 0
    }

    Invoke-SessionFeedback -RepoRoot $root -SessionId $sessionId -TranscriptPath $transcriptPath -ClaudeCommand $ClaudeCommand -Model $Model | Out-Null
    exit 0
}
catch {
    if ($root) { Write-HookError -RepoRoot $root -Hook 'SessionEnd' -Message $_.Exception.Message }
    exit 0
}
