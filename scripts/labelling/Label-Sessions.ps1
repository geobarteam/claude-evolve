#Requires -Version 7.0
<#
.SYNOPSIS
    Interactive labelling tool: the owner labels each prompt of a real session so the classifier can be checked.

.DESCRIPTION
    Protected file. Prints every owner prompt with the agent action that preceded it and asks for a label:
      c = correction, f = frustration, p = praise, q = question (answer was in MEMORY.md/codebase), n = none, s = skip rest
    Labels go to evolution/labelled/<session_id>.labels.jsonl (gitignored; real transcripts stay local).
    Run Test-ClassifierAgreement.ps1 afterwards. The spec's gate is >= 80 % agreement over >= 30 sessions.

.EXAMPLE
    pwsh <plugin>/scripts/labelling/Label-Sessions.ps1 -TranscriptPath "$HOME/.claude/projects/<encoded project path>/<id>.jsonl"
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $TranscriptPath,
    [string] $RepoRoot
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Transcript.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Feedback.psm1" -Force
$RepoRoot = Resolve-ProjectRoot -ProjectRoot $RepoRoot

$labelMap = @{ c = 'correction'; f = 'frustration'; p = 'praise'; q = 'question'; n = 'none' }
$sessionId = [System.IO.Path]::GetFileNameWithoutExtension($TranscriptPath)
$records = @(Read-Transcript -Path $TranscriptPath)
$pairs = @(Get-PairedOwnerTurns -Records $records)

if ($pairs.Count -eq 0) {
    Write-Output "No owner prompts found in $TranscriptPath."
    exit 0
}

$outDir = Join-Path $RepoRoot 'evolution/labelled'
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
$outPath = Join-Path $outDir "$sessionId.labels.jsonl"
if (Test-Path -LiteralPath $outPath) { Remove-Item -LiteralPath $outPath }

Write-Output "Session $sessionId : $($pairs.Count) owner prompts. Labels: c f p q n, s = stop."
foreach ($pair in $pairs) {
    Write-Output ''
    Write-Output ('[{0}] AGENT: {1}' -f $pair.Index, ($(if ($pair.AgentAction) { $pair.AgentAction } else { '(none)' })))
    Write-Output ('[{0}] OWNER: {1}' -f $pair.Index, $pair.OwnerText)

    $answer = ''
    while ($answer -notin @('c', 'f', 'p', 'q', 'n', 's')) {
        $answer = (Read-Host 'label').Trim().ToLowerInvariant()
    }
    if ($answer -eq 's') { break }

    [ordered]@{ session_id = $sessionId; uuid = $pair.OwnerUuid; index = $pair.Index; label = $labelMap[$answer] } |
        ConvertTo-Json -Compress | Add-Content -LiteralPath $outPath -Encoding utf8
}

Write-Output "Labels written to $outPath"
