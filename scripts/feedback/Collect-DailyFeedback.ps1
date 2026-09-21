#Requires -Version 7.0
<#
.SYNOPSIS
    Backstop for the SessionEnd hook: processes every recent transcript that has not been processed yet.

.DESCRIPTION
    Protected file. Run by hand (or from /evolve before a generation). Covers sessions whose window was closed
    without a SessionEnd event, and sessions whose classifier call failed. Same rubric, same records, same
    idempotency markers as the hook. Git-based signals (code corrections, reverts, markers) are added in Step 4.

.PARAMETER TranscriptDir
    Folder holding Claude Code transcripts for this project (one <session_id>.jsonl per session).

.PARAMETER Days
    Look-back window on the transcript's last write time.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $TranscriptDir,
    [string] $ClaudeCommand = 'claude',
    [string] $Model,
    [int] $Days = 2,
    [int] $GitSinceDays = 7,
    [int] $MinSurvivalAgeDays = 7
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/../lib/HookInput.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Feedback.psm1" -Force
Import-Module "$PSScriptRoot/../lib/GitSignals.psm1" -Force
$RepoRoot = Resolve-ProjectRoot -ProjectRoot $RepoRoot
$config = Get-EvolveConfig -ProjectRoot $RepoRoot
if (-not $TranscriptDir) { $TranscriptDir = $config.TranscriptDir }
if (-not $Model) { $Model = $config.Classifier.Model }

$cutoff = [datetime]::UtcNow.AddDays(-$Days)
$candidates = @()
if (Test-Path -LiteralPath $TranscriptDir) {
    $candidates = @(Get-ChildItem -LiteralPath $TranscriptDir -Filter '*.jsonl' -File | Where-Object { $_.LastWriteTimeUtc -ge $cutoff })
}
else {
    Write-Output "No transcript directory at $TranscriptDir; transcript signals skipped."
}

$processed = 0
$skipped = 0
$failed = 0
$records = 0
foreach ($transcript in $candidates) {
    $sessionId = $transcript.BaseName
    if (Test-SessionProcessed -RepoRoot $RepoRoot -SessionId $sessionId) {
        $skipped++
        continue
    }

    try {
        $records += Invoke-SessionFeedback -RepoRoot $RepoRoot -SessionId $sessionId -TranscriptPath $transcript.FullName -ClaudeCommand $ClaudeCommand -Model $Model
        $processed++
    }
    catch {
        $failed++
        Write-HookError -RepoRoot $RepoRoot -Hook 'Collect-DailyFeedback' -Message "$sessionId : $($_.Exception.Message)"
    }
}

$gitRecords = 0
try {
    $gitRecords = Invoke-GitSignals -RepoRoot $RepoRoot -RepoPath $RepoRoot -SinceDays $GitSinceDays -MinSurvivalAgeDays $MinSurvivalAgeDays -TrailerPattern $config.AgentTrailerPattern
}
catch {
    Write-HookError -RepoRoot $RepoRoot -Hook 'Collect-DailyFeedback' -Message "git signals: $($_.Exception.Message)"
}

Write-Output ("Transcripts in window: {0}; processed: {1}; skipped (already processed): {2}; failed: {3}; transcript records: {4}; git records: {5}" -f $candidates.Count, $processed, $skipped, $failed, $records, $gitRecords)
exit 0
