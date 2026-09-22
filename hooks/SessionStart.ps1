#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    SessionStart hook: injects MEMORY.md and the last 3 journal entries into the new session's context.

.DESCRIPTION
    Protected file. Wired in .claude/settings.json. Reads the hook JSON from stdin (or -InputJson in tests).
    On startup/resume/clear it also records the session start in evolution/.state/<session_id>.json,
    which the Stop hook uses to name the journal file. On compact/fork only MEMORY.md is re-injected.
    Whatever this script writes to stdout is added to the model's context (exit code 0).
#>
[CmdletBinding()]
param(
    [string] $InputJson,
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../scripts/lib/HookInput.psm1" -Force

if (Test-HookSuppressed) { exit 0 }

$root = $null
try {
    $hookInput = Read-HookInput -InputJson $InputJson
    $root = Resolve-RepoRoot -RepoRoot $RepoRoot -HookInput $hookInput
    $sessionId = [string] (Get-HookProperty -Object $hookInput -Name 'session_id' -Default 'unknown-session')
    $source = [string] (Get-HookProperty -Object $hookInput -Name 'source' -Default 'startup')

    $output = [System.Text.StringBuilder]::new()

    $memoryPath = Join-Path $root 'MEMORY.md'
    if (Test-Path -LiteralPath $memoryPath) {
        [void] $output.AppendLine('# MEMORY.md (genome — project beliefs)')
        [void] $output.AppendLine((Get-Content -LiteralPath $memoryPath -Raw))
        [void] $output.AppendLine()
    }

    if ($source -in @('startup', 'resume', 'clear')) {
        $stateDir = Get-StateDirectory -RepoRoot $root
        $state = [ordered]@{
            session_id = $sessionId
            started    = [datetime]::UtcNow.ToString('o')
            source     = $source
            cwd        = [string] (Get-HookProperty -Object $hookInput -Name 'cwd' -Default $root)
        }
        $state | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $stateDir "$sessionId.json") -Encoding utf8

        $journalDir = Join-Path $root 'evolution/journal'
        $recent = @()
        if (Test-Path -LiteralPath $journalDir) {
            $recent = @(Get-ChildItem -LiteralPath $journalDir -Filter '*.md' -File |
                    Where-Object { $_.Name -ne 'TEMPLATE.md' } |
                    Sort-Object Name -Descending |
                    Select-Object -First 3)
        }

        if ($recent.Count -gt 0) {
            [void] $output.AppendLine('# Recent journal entries (newest first)')
            foreach ($entry in $recent) {
                [void] $output.AppendLine("## $($entry.Name)")
                [void] $output.AppendLine((Get-Content -LiteralPath $entry.FullName -Raw))
                [void] $output.AppendLine()
            }
        }

        $journalName = Get-JournalFileName -RepoRoot $root -SessionId $sessionId
        [void] $output.AppendLine('# Journal duty')
        [void] $output.AppendLine("Session id: $sessionId. Before each of your turns ends, create or update ``evolution/journal/$journalName`` from ``evolution/journal/TEMPLATE.md``. Its first line must be ``<!-- session: $sessionId -->``. The Stop hook blocks the turn until that file is newer than the owner's last prompt. Keep it short and honest; 'What I fought against' and 'Beliefs to revise' are the evolver's main evidence. Owner shortcut: a prompt of exactly ``+`` or ``- <reason>`` rates the session.")
    }

    Write-Output $output.ToString()
    exit 0
}
catch {
    if ($root) { Write-HookError -RepoRoot $root -Hook 'SessionStart' -Message $_.Exception.Message }
    exit 0
}
