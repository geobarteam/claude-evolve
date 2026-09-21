#Requires -Version 7.0
<#
.SYNOPSIS
    PostToolUse hook: counts skill and sub-agent invocations as "usage" feedback records.

.DESCRIPTION
    Protected file. Wired in .claude/settings.json with matcher "Skill|Agent|Task". Never blocks, prints nothing.
    Records { signal: usage, value: <skill name | agent type>, kind: skill | agent }. The evolver aggregates
    usage per week to find skills and agents unused for 30 days (retirement candidates).
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
    $toolName = [string] (Get-HookProperty -Object $hookInput -Name 'tool_name' -Default '')
    $toolInput = Get-HookProperty -Object $hookInput -Name 'tool_input'

    $kind = $null
    $name = $null
    switch ($toolName) {
        'Skill' {
            $kind = 'skill'
            $name = [string] (Get-HookProperty -Object $toolInput -Name 'skill' -Default '')
        }
        { $_ -in @('Agent', 'Task') } {
            $kind = 'agent'
            $name = [string] (Get-HookProperty -Object $toolInput -Name 'subagent_type' -Default '')
        }
    }

    if (-not $kind -or [string]::IsNullOrWhiteSpace($name)) { exit 0 }

    $root = Resolve-RepoRoot -RepoRoot $RepoRoot -HookInput $hookInput
    $sessionId = [string] (Get-HookProperty -Object $hookInput -Name 'session_id' -Default 'unknown-session')
    $toolUseId = [string] (Get-HookProperty -Object $hookInput -Name 'tool_use_id' -Default '')
    $ref = if ($toolUseId) { "transcript:$sessionId#$toolUseId" } else { "transcript:$sessionId" }

    Write-FeedbackRecord -RepoRoot $root -SessionId $sessionId -Signal 'usage' -Value $name.Trim() -Ref $ref -Extra @{
        kind = $kind
        tool = $toolName
    }
    exit 0
}
catch {
    if ($root) { Write-HookError -RepoRoot $root -Hook 'PostToolUse' -Message $_.Exception.Message }
    exit 0
}
