#Requires -Version 7.0
<#
.SYNOPSIS
    Scores a genome: runs every regression task against a disposable git worktree at -Ref and prints "Score: n/N".

.DESCRIPTION
    Protected file. Never touches the owner's checkout: a detached worktree is created under the temp folder,
    reset between tasks, and removed in `finally` (unless -KeepWorktree). Each task is one headless Claude call
    run from inside the worktree with the candidate genome, EVOLUTION_CLASSIFIER=1 (this project's hooks stay
    silent), bypassed permissions confined to that worktree, and a tool allow-list without git, network or delete.
    Results go to evolution/.state/regression/<timestamp>.json in the owner's checkout (gitignored).

.PARAMETER Ref
    Commit, tag or branch whose genome is scored (default HEAD). Uncommitted changes are never scored.

.EXAMPLE
    pwsh <plugin>/scripts/regression/Invoke-Regression.ps1 -Ref gen/0
#>
[CmdletBinding()]
param(
    [string] $Ref = 'HEAD',
    [string] $RepoRoot,
    [string] $TasksDir,
    [string] $ClaudeCommand = 'claude',
    [string] $Model = 'sonnet',
    [string] $PermissionMode = 'bypassPermissions',
    [string] $AllowedTools = 'Read,Glob,Grep,Edit,Write',
    [double] $MaxBudgetUsd = 1.0,
    [string[]] $Only = @(),
    [switch] $KeepWorktree
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Feedback.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Regression.psm1" -Force
$RepoRoot = Resolve-ProjectRoot -ProjectRoot $RepoRoot
if (-not $TasksDir) { $TasksDir = Join-Path $RepoRoot 'evolution/regression/tasks' }

function Invoke-RepoGit {
    param([string] $Path, [string[]] $GitArgs)
    $out = & git -C $Path @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $($out -join "`n")" }
    return @($out | ForEach-Object { [string] $_ })
}

$tasks = @(Get-RegressionTasks -TasksDir $TasksDir)
if ($Only.Count -gt 0) { $tasks = @($tasks | Where-Object { $_.Id -in $Only }) }
if ($tasks.Count -eq 0) { throw 'No regression tasks selected.' }

$command = Resolve-ClaudeCommand -ClaudeCommand $ClaudeCommand
$sha = [string] (@(Invoke-RepoGit -Path $RepoRoot -GitArgs @('rev-parse', '--verify', "$Ref^{commit}")) | Select-Object -First 1)
$stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$worktree = Join-Path ([System.IO.Path]::GetTempPath()) "evolve-regression-$stamp-$([guid]::NewGuid().ToString('N').Substring(0, 6))"
$results = [System.Collections.Generic.List[object]]::new()
$previousGuard = $env:EVOLUTION_CLASSIFIER

try {
    Invoke-RepoGit -Path $RepoRoot -GitArgs @('worktree', 'add', '--detach', '-q', $worktree, $sha) | Out-Null
    Write-Output "Worktree $worktree at $($sha.Substring(0, 12)) ($Ref); $($tasks.Count) task(s); model $Model"

    foreach ($task in $tasks) {
        Invoke-RepoGit -Path $worktree -GitArgs @('reset', '-q', '--hard', $sha) | Out-Null
        Invoke-RepoGit -Path $worktree -GitArgs @('clean', '-fdq') | Out-Null

        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        $answer = ''
        $taskError = $null
        Push-Location $worktree
        try {
            $env:EVOLUTION_CLASSIFIER = '1'
            $arguments = @('-p', $task.Prompt, '--permission-mode', $PermissionMode, '--allowedTools', $AllowedTools, '--output-format', 'json', '--model', $Model, '--no-session-persistence', '--max-budget-usd', $MaxBudgetUsd.ToString([cultureinfo]::InvariantCulture))
            $raw = (& $command @arguments | Out-String)
            $exit = $LASTEXITCODE
            try {
                $envelope = $raw | ConvertFrom-Json -Depth 32
                if ($envelope -is [System.Array]) { $envelope = @($envelope | Where-Object { $_.PSObject.Properties['result'] }) | Select-Object -Last 1 }
                $answer = [string] $envelope.result
                if ($envelope.PSObject.Properties['is_error'] -and $envelope.is_error) { $taskError = "claude reported an error: $answer" }
            }
            catch {
                $answer = $raw
            }
            if ($exit -ne 0 -and -not $taskError) { $taskError = "claude exited with code $exit" }
        }
        catch {
            $taskError = $_.Exception.Message
        }
        finally {
            if ($null -eq $previousGuard) { Remove-Item Env:\EVOLUTION_CLASSIFIER -ErrorAction SilentlyContinue } else { $env:EVOLUTION_CLASSIFIER = $previousGuard }
            Pop-Location
        }

        $verdict = if ($taskError) { [pscustomobject]@{ Passed = $false; Detail = $taskError } } else { Test-RegressionAnswer -Task $task -Answer $answer -Worktree $worktree }
        $sw.Stop()
        $results.Add([ordered]@{
                id         = $task.Id
                check      = $task.Check
                passed     = [bool] $verdict.Passed
                detail     = [string] $verdict.Detail
                duration_s = [math]::Round($sw.Elapsed.TotalSeconds, 1)
            })
        Write-Output ("  {0} {1,-5} {2,6}s  {3}" -f $(if ($verdict.Passed) { 'PASS' } else { 'FAIL' }), $task.Id, $results[-1].duration_s, $verdict.Detail)
    }
}
finally {
    if (-not $KeepWorktree -and (Test-Path -LiteralPath $worktree)) {
        & git -C $RepoRoot worktree remove --force $worktree 2>&1 | Out-Null
        & git -C $RepoRoot worktree prune 2>&1 | Out-Null
        if (Test-Path -LiteralPath $worktree) { Remove-Item -LiteralPath $worktree -Recurse -Force -ErrorAction SilentlyContinue }
    }
}

$score = @($results | Where-Object { $_.passed }).Count
$summary = [ordered]@{
    ref      = $Ref
    sha      = $sha
    started  = $stamp
    model    = $Model
    score    = $score
    total    = $results.Count
    failed   = @($results | Where-Object { -not $_.passed } | ForEach-Object { $_.id })
    tasks    = $results.ToArray()
}

$resultDir = Join-Path $RepoRoot 'evolution/.state/regression'
if (-not (Test-Path -LiteralPath $resultDir)) { New-Item -ItemType Directory -Path $resultDir -Force | Out-Null }
$resultPath = Join-Path $resultDir "$stamp.json"
$summary | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $resultPath -Encoding utf8

Write-Output "Score: $score/$($results.Count)"
if ($summary.failed.Count -gt 0) { Write-Output "Failed: $($summary.failed -join ', ')" }
Write-Output "Results: $resultPath"
exit 0
