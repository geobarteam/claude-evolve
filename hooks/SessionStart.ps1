#!/usr/bin/env pwsh
#Requires -Version 7.0
<#
.SYNOPSIS
    SessionStart hook: injects long-term memory (the index), short-term memory and the last 3 journal entries.

.DESCRIPTION
    Protected file. Wired in hooks/hooks.json. Reads the hook JSON from stdin (or -InputJson in tests).
    Both memory files are cut to the memory limits of evolution/evolve.json (default 200 lines / 25 KB), the
    limits Claude Code applies to its own memory index. On startup/resume/clear it also records the session start
    in evolution/.state/<session_id>.json, which the Stop hook uses to name the journal file. On compact/fork only
    the memory is re-injected. Whatever this script writes to stdout is added to the model's context (exit code 0).
#>
[CmdletBinding()]
param(
    [string] $InputJson,
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../scripts/lib/HookInput.psm1" -Force
Import-Module "$PSScriptRoot/../scripts/lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/../scripts/lib/Memory.psm1" -Force

if (Test-HookSuppressed) { exit 0 }

$root = $null
try {
    $hookInput = Read-HookInput -InputJson $InputJson
    $root = Resolve-RepoRoot -RepoRoot $RepoRoot -HookInput $hookInput
    $sessionId = [string] (Get-HookProperty -Object $hookInput -Name 'session_id' -Default 'unknown-session')
    $source = [string] (Get-HookProperty -Object $hookInput -Name 'source' -Default 'startup')
    $limits = (Get-EvolveConfig -ProjectRoot $root).Memory
    $layout = Get-MemoryLayout

    $output = [System.Text.StringBuilder]::new()

    $sections = [ordered]@{
        $layout.LongTermIndex = "# Long-term memory ($($layout.LongTermIndex): cues; read the linked file under $($layout.LongTermDir)/ before relying on one — reads are counted)"
        $layout.ShortTerm     = "# Short-term memory ($($layout.ShortTerm): your working notes since the last consolidation)"
    }
    foreach ($rel in $sections.Keys) {
        $path = Join-Path $root $rel
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $cut = Limit-MemoryText -Text ([System.IO.File]::ReadAllText($path)) -Limits $limits
        [void] $output.AppendLine($sections[$rel])
        [void] $output.AppendLine($cut.Text)
        if ($cut.Truncated) { [void] $output.AppendLine("(cut at $($limits.MaxLines) lines / $($limits.MaxBytes) bytes; the rest of $rel was not loaded)") }
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
        [void] $output.AppendLine('# Journal and memory duty')
        [void] $output.AppendLine("Session id: $sessionId. Before each of your turns ends, create or update ``evolution/journal/$journalName`` from ``evolution/journal/TEMPLATE.md``. Its first line must be ``<!-- session: $sessionId -->``. The Stop hook blocks the turn until that file is newer than the owner's last prompt. Keep it short and honest; 'What I fought against' is the evolver's main evidence. Anything worth remembering beyond this session goes to ``$($layout.ShortTerm)`` as one dated bullet; never edit long-term memory. Owner shortcut: a prompt of exactly ``+`` or ``- <reason>`` rates the session.")
    }

    Write-Output $output.ToString()
    exit 0
}
catch {
    if ($root) { Write-HookError -RepoRoot $root -Hook 'SessionStart' -Message $_.Exception.Message }
    exit 0
}
