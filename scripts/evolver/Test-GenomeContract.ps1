#Requires -Version 7.0
<#
.SYNOPSIS
    Checks a generation against the genome contract. Exit 0 = OK, exit 1 = one violation per output line.

.DESCRIPTION
    Protected file. Used by Invoke-Evolver.ps1 before committing and by CI after (same rules, same code:
    evolution/lib/Contract.psm1). Compare a base ref with a committed head (-Head) or a worktree (-Worktree).

.PARAMETER OnlyIfAuthor
    CI mode: exit 0 without checking when the head commit's author name differs (owner commits are not bound
    by the evolver's contract; the evolver identity is).

.PARAMETER ScanNotes
    Also fail when a journal entry or generation note changed in the range contains a flagged phrase
    (resisting reverts or shutdown, preserving memory, bypassing the owner). The owner then reverts the generation.

.EXAMPLE
    pwsh evolution/evolver/Test-GenomeContract.ps1 -Base HEAD~1 -Head HEAD -OnlyIfAuthor evolver -ScanNotes
.EXAMPLE
    pwsh <plugin>/scripts/evolver/Test-GenomeContract.ps1 -Base gen/0 -Worktree C:\Temp\candidate
#>
[CmdletBinding()]
param(
    [string] $RepoPath,
    [Parameter(Mandatory)] [string] $Base,
    [string] $Head,
    [string] $Worktree,
    [int] $MaxEdits = 3,
    [string] $OnlyIfAuthor,
    [switch] $ScanNotes
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Contract.psm1" -Force
$RepoPath = Resolve-ProjectRoot -ProjectRoot $RepoPath

if (-not $Worktree -and -not $Head) { $Head = 'HEAD' }

if ($OnlyIfAuthor -and -not $Worktree) {
    $author = Get-CommitAuthorName -RepoPath $RepoPath -Ref $Head
    if ($author -ne $OnlyIfAuthor) {
        Write-Output "Skipped: $Head is by '$author', not by $OnlyIfAuthor; the genome contract binds only the evolver identity."
        exit 0
    }
}

$params = @{ RepoPath = $RepoPath; Base = $Base; MaxEdits = $MaxEdits }
if ($Worktree) { $params.Worktree = $Worktree } else { $params.Head = $Head }

$violations = [System.Collections.Generic.List[string]]::new()
foreach ($v in @(Test-GenomeContract @params)) { $violations.Add($v) }
if ($ScanNotes -and -not $Worktree) {
    foreach ($hit in @(Find-FlaggedPhrases -RepoPath $RepoPath -Base $Base -Head $Head)) { $violations.Add("flagged phrase in $hit") }
}

if ($violations.Count -gt 0) {
    foreach ($v in $violations) { Write-Output "VIOLATION: $v" }
    exit 1
}

Write-Output 'Contract OK'
exit 0
