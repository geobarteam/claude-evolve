#Requires -Version 7.0
<#
.SYNOPSIS
    Scores the rubric classifier against the owner's labels from Label-Sessions.ps1.

.DESCRIPTION
    Protected file. For every evolution/labelled/<session_id>.labels.jsonl, classifies the matching transcript
    with the real classifier (one Claude call per session) and prints per-session and overall agreement.
    Gate from the spec: >= 80 % agreement over >= 30 labelled sessions before the first real generation.

.EXAMPLE
    pwsh <plugin>/scripts/labelling/Test-ClassifierAgreement.ps1
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $TranscriptDir,
    [string] $ClaudeCommand = 'claude',
    [string] $Model
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Transcript.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Feedback.psm1" -Force
$RepoRoot = Resolve-ProjectRoot -ProjectRoot $RepoRoot
$config = Get-EvolveConfig -ProjectRoot $RepoRoot
if (-not $TranscriptDir) { $TranscriptDir = $config.TranscriptDir }
if (-not $Model) { $Model = $config.Classifier.Model }

$labelDir = Join-Path $RepoRoot 'evolution/labelled'
$labelFiles = @(Get-ChildItem -LiteralPath $labelDir -Filter '*.labels.jsonl' -File -ErrorAction SilentlyContinue)
if ($labelFiles.Count -eq 0) {
    Write-Output "No labelled sessions under $labelDir. Run Label-Sessions.ps1 first."
    exit 0
}

$rubric = "$PSScriptRoot/../evolver/rubric.md"
$titles = @(Get-BeliefTitles -RepoRoot $RepoRoot)
$totalAgree = 0
$totalLabels = 0
$sessions = 0

foreach ($file in $labelFiles) {
    $sessionId = $file.Name -replace '\.labels\.jsonl$', ''
    $transcript = Join-Path $TranscriptDir "$sessionId.jsonl"
    if (-not (Test-Path -LiteralPath $transcript)) {
        Write-Output "$sessionId : transcript not found, skipped"
        continue
    }

    $labels = @{}
    foreach ($line in Get-Content -LiteralPath $file.FullName) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        $l = $line | ConvertFrom-Json
        $labels[[string] $l.uuid] = [string] $l.label
    }

    $pairs = @(Get-PairedOwnerTurns -Records @(Read-Transcript -Path $transcript))
    $results = @(Invoke-Classifier -Pairs $pairs -RubricPath $rubric -ClaudeCommand $ClaudeCommand -Model $Model -BeliefTitles $titles)

    $agree = 0
    $count = 0
    foreach ($r in $results) {
        if (-not $labels.ContainsKey([string] $r.OwnerUuid)) { continue }
        $count++
        if ($labels[[string] $r.OwnerUuid] -eq $r.Label) { $agree++ } else {
            Write-Output ("  {0} [{1}] owner={2} model={3} :: {4}" -f $sessionId, $r.Index, $labels[[string] $r.OwnerUuid], $r.Label, $r.OwnerText)
        }
    }

    if ($count -gt 0) {
        $sessions++
        $totalAgree += $agree
        $totalLabels += $count
        Write-Output ("{0} : {1}/{2} ({3:P0})" -f $sessionId, $agree, $count, ($agree / $count))
    }
}

if ($totalLabels -gt 0) {
    $pct = $totalAgree / $totalLabels
    Write-Output ("Overall: {0}/{1} labels agree ({2:P1}) over {3} session(s). Gate: >= 80 % over >= 30 sessions -> {4}" -f $totalAgree, $totalLabels, $pct, $sessions, $(if ($pct -ge 0.8 -and $sessions -ge 30) { 'PASS' } else { 'NOT YET' }))
}
