#Requires -Version 7.0
<#
.SYNOPSIS
    The evolver runner: one owner-triggered run reads the evidence, has a headless Claude propose at most 3 cited
    genome edits in a disposable worktree, and turns that proposal into one generation commit, or refuses/rejects it.

.DESCRIPTION
    Protected file. Started by the owner only (`/evolve` in a session, or this script by hand). Never scheduled.
    Bookkeeping first (both modes):
      - `Revert "gen(N): ..."` commits since the last run add a `reverted` lineage row for gen/N (once).
      - `provisional` rows older than 14 days become `settled`.
      - Bookkeeping rows are committed on their own as "lineage: ..." by the evolver identity.
    Run mode (no -ProposalDir):
      1. Stop when no journal entry is newer than the last generation and short-term memory is empty (-Force overrides).
      2. Memory consolidation, step 1 (deterministic, in a disposable worktree at HEAD holding the owner's current
         memory/short-term.md): the recalls since the last generation strengthen the long-term memories that were
         read, the others decay, idle weak ones are forgotten (scripts/lib/Memory.psm1, Invoke-MemoryDecay).
      3. Build the evidence bundle under evolution/.state/evolver/ and in the worktree at .evolver/evidence.md.
      4. `claude -p` with evolution/evolver/prompt.md inside that worktree: EVOLUTION_CLASSIFIER=1
         (this project's hooks stay silent), permission mode acceptEdits, tools Read/Glob/Grep/Write/Edit only, a budget cap.
         The model compresses short-term into long-term memory (step 2) and proposes the genome edits.
      5. Memory consolidation, step 3 (deterministic): counters for new memories, the weakest memories forgotten while
         the index is over its limit, short-term memory cleared. Recalls and forgetting are appended to the note.
      6. The worktree's changes become the proposal; the run then continues exactly like -ProposalDir mode.
    Proposal mode (-ProposalDir): the commit contract of Step 7:
      contract check in a fresh worktree -> regression score -> drop the last change and retry once if the score fell ->
      commit only the proposed paths + note + lineage as "evolver <evolver@<project>.local>", tag gen/N.
    There is no push code path anywhere in this script; pushing is the owner's act.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [string] $ProposalDir,
    [string] $ClaudeCommand = 'claude',
    [string] $Model,
    [string] $TasksDir,
    [int] $MaxEdits,
    [double] $MaxBudgetUsd,
    [int] $SettleAfterDays,
    [switch] $SkipRegression,
    [switch] $Force
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Contract.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Worktree.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Feedback.psm1" -Force
Import-Module "$PSScriptRoot/../lib/GitSignals.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Memory.psm1" -Force
$RepoRoot = Resolve-ProjectRoot -ProjectRoot $RepoRoot

$config = Get-EvolveConfig -ProjectRoot $RepoRoot
if (-not $PSBoundParameters.ContainsKey('Model')) { $Model = $config.Proposal.Model }
if (-not $PSBoundParameters.ContainsKey('MaxEdits')) { $MaxEdits = $config.MaxEdits }
if (-not $PSBoundParameters.ContainsKey('MaxBudgetUsd')) { $MaxBudgetUsd = $config.Proposal.MaxBudgetUsd }
if (-not $PSBoundParameters.ContainsKey('SettleAfterDays')) { $SettleAfterDays = $config.SettleAfterDays }
$regressionModel = if ($PSBoundParameters.ContainsKey('Model')) { $Model } else { $config.Regression.Model }
$script:EvolverName = $config.EvolverName
$script:EvolverEmail = $config.EvolverEmail
$regressionScript = "$PSScriptRoot/../regression/Invoke-Regression.ps1"
$promptPath = Join-Path $PSScriptRoot 'prompt.md'
if (-not $TasksDir) { $TasksDir = Join-Path $RepoRoot 'evolution/regression/tasks' }
$stamp = [datetime]::UtcNow.ToString('yyyyMMdd-HHmmss')
$shortTermSnapshot = $null
$stateDir = Join-Path $RepoRoot 'evolution/.state/evolver'
if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$logPath = Join-Path $stateDir "$stamp.log"

function Write-Log {
    param([string] $Message)
    Write-Output $Message
    Add-Content -LiteralPath $logPath -Value $Message -Encoding utf8
}

function Invoke-EvolverGit {
    param([string] $Path, [string[]] $GitArgs, [switch] $AsEvolver)
    $identity = if ($AsEvolver) { @('-c', "user.name=$script:EvolverName", '-c', "user.email=$script:EvolverEmail", '-c', 'commit.gpgsign=false') } else { @() }
    $out = & git -C $Path @identity @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $($out -join "`n")" }
    return @($out | ForEach-Object { [string] $_ })
}

function Get-GitLine {
    param([string] $Path, [string[]] $GitArgs)
    [string] (@(Invoke-EvolverGit -Path $Path -GitArgs $GitArgs) | Select-Object -First 1)
}

# A proposal folder lists the files it deletes (a forgotten memory, a retired skill) in this file, one path per line.
$script:DeletedList = '.deleted'

function Copy-ProposalFiles {
    param([string] $Source, [string] $Destination, [string[]] $Paths)
    foreach ($rel in $Paths) {
        if (-not (Test-PathInsideProject -Path $rel)) { throw "REFUSED: path outside the project root: $rel" }
        $dest = Join-Path $Destination $rel
        if (-not (Test-Path -LiteralPath (Join-Path $Source $rel))) {
            if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
            continue
        }
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $Source $rel) -Destination $dest -Force
    }
}

function Get-RegressionScore {
    param([string] $Ref)
    $output = & $regressionScript -RepoRoot $RepoRoot -Ref $Ref -ClaudeCommand $ClaudeCommand -Model $regressionModel -TasksDir $TasksDir 2>&1 | ForEach-Object { [string] $_ }
    foreach ($line in $output) { Write-Host "    $line"; Add-Content -LiteralPath $logPath -Value "    $line" -Encoding utf8 }
    $scoreLine = $output | Where-Object { $_ -match '^Score: (\d+/\d+)' } | Select-Object -Last 1
    if (-not $scoreLine) { throw 'Regression run produced no score.' }
    return [string] [regex]::Match($scoreLine, '^Score: (\d+/\d+)').Groups[1].Value
}

function Get-LastGenerationTime {
    param([int] $Generation, [datetime] $FallbackDate)
    & git -C $RepoRoot rev-parse -q --verify "refs/tags/gen/$Generation" 2>&1 | Out-Null
    if ($LASTEXITCODE -eq 0) {
        $iso = Get-GitLine -Path $RepoRoot -GitArgs @('log', '-1', '--format=%cI', "gen/$Generation")
        return [datetime]::Parse($iso, [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
    }
    return $FallbackDate
}

function New-EvidenceBundle {
    param([datetime] $Since, [int] $Generation, [string[]] $Journals, [string] $MemoryReport)
    $sb = [System.Text.StringBuilder]::new()
    $add = { param($t) [void] $sb.AppendLine($t) }
    & $add "# Evidence for gen/$Generation (since $($Since.ToString('u')))"
    & $add ''
    & $add '## Lineage'
    & $add (Get-Content -LiteralPath (Join-Path $RepoRoot 'evolution/lineage.md') -Raw)
    & $add '## Journal entries since the last generation'
    foreach ($j in $Journals) {
        & $add "### evolution/journal/$(Split-Path $j -Leaf)"
        & $add (Get-Content -LiteralPath $j -Raw)
        & $add ''
    }
    & $add '## Feedback records since the last generation'
    $feedbackDir = Join-Path $RepoRoot 'evolution/feedback'
    $usage = @{}
    if (Test-Path -LiteralPath $feedbackDir) {
        foreach ($f in Get-ChildItem -LiteralPath $feedbackDir -Filter '*.jsonl' -File | Where-Object { $_.BaseName -ge $Since.ToString('yyyy-MM-dd') } | Sort-Object Name) {
            & $add "### evolution/feedback/$($f.Name)"
            foreach ($line in Get-Content -LiteralPath $f.FullName) {
                if ([string]::IsNullOrWhiteSpace($line)) { continue }
                try { $rec = $line | ConvertFrom-Json } catch { continue }
                if ($rec.signal -eq 'recall') { continue }
                if ($rec.signal -eq 'usage') { $usage[[string] $rec.value] = 1 + $(if ($usage.ContainsKey([string] $rec.value)) { $usage[[string] $rec.value] } else { 0 }); continue }
                & $add "- $line"
            }
            & $add ''
        }
    }
    & $add '## Skill and sub-agent usage counts in the window'
    if ($usage.Count -eq 0) { & $add '(no usage records)' }
    foreach ($k in $usage.Keys | Sort-Object) { & $add "- $k : $($usage[$k])" }
    & $add ''
    & $add '## Git history of genome paths since the last generation (owner edits are settled truth)'
    $genomeLog = @(& git -C $RepoRoot log "--since=$($Since.ToString('o'))" '--format=%h %an: %s' -- CLAUDE.md memory .claude/agents .claude/skills .claude/tools 2>&1 | ForEach-Object { [string] $_ })
    if ($genomeLog.Count -eq 0) { & $add '(none)' } else { $genomeLog | ForEach-Object { & $add "- $_" } }
    & $add ''
    & $add '## Agent-authored commits in the last 30 days'
    $agentCommits = @(Get-AgentCommits -RepoPath $RepoRoot -SinceDays 30 -TrailerPattern $config.AgentTrailerPattern)
    if ($agentCommits.Count -eq 0) { & $add '(none)' } else { $agentCommits | ForEach-Object { & $add "- $($_.Sha.Substring(0, 12)) $($_.Subject)" } }
    & $add ''
    & $add '## Genome inventory'
    foreach ($dir in '.claude/agents', '.claude/skills', '.claude/tools', '.claude/instructions') {
        $full = Join-Path $RepoRoot $dir
        if (Test-Path -LiteralPath $full) {
            & $add "- ${dir}: " + ((Get-ChildItem -LiteralPath $full | ForEach-Object Name | Sort-Object) -join ', ')
        }
    }
    & $add ''
    & $add '## Protected paths (never edit)'
    & $add (Get-Content -LiteralPath (Join-Path $RepoRoot 'evolution/evolver/protected-paths.txt') -Raw)
    & $add '# Protected at runtime as well (not listed in the manifest):'
    & $add 'evolution/evolve.json'
    & $add "the plugin folder: $(Get-PluginRoot)"
    & $add ''
    & $add $MemoryReport
    return $sb.ToString()
}

# --- 0. branch, lineage, bookkeeping (reverts, settlement) --------------------------------------------------------
$branch = Get-GitLine -Path $RepoRoot -GitArgs @('symbolic-ref', '--short', '-q', 'HEAD')
if (-not $branch) { throw 'The repository is in detached HEAD state; check out the main line first.' }
$lineagePath = Join-Path $RepoRoot 'evolution/lineage.md'
Write-Log "Evolver run $stamp on branch '$branch' (mainLine: $(if ($config.MainLine) { $config.MainLine } else { 'unset' }); log: evolution/.state/evolver/$stamp.log)"

$lineageDirty = @(Invoke-EvolverGit -Path $RepoRoot -GitArgs @('status', '--porcelain', '--', 'evolution/lineage.md')).Count -gt 0
$bookkeeping = [System.Collections.Generic.List[string]]::new()
if ($lineageDirty) {
    Write-Log 'evolution/lineage.md has uncommitted owner changes; revert and settlement bookkeeping skipped this run.'
}
else {
    $rows = @(Get-Content -LiteralPath $lineagePath)
    foreach ($revert in Get-GenerationReverts -RepoPath $RepoRoot -SinceDays 3650) {
        $gen = $revert.Value
        if (@($rows | Where-Object { $_ -match ('^\|\s*' + [regex]::Escape($gen) + '\s*\|.*\|\s*reverted\s*\|') }).Count -gt 0) { continue }
        Add-LineageRow -Path $lineagePath -Generation $gen -Score '—' -Status 'reverted' -Summary "reverted by $($revert.Ref.Substring(0, 12)): $($revert.Reason)"
        $bookkeeping.Add("$gen reverted")
        $rows = @(Get-Content -LiteralPath $lineagePath)
    }
    foreach ($row in $rows) {
        if ($row -match '^\|\s*(gen/\d+)\s*\|\s*(\d{4}-\d{2}-\d{2})\s*\|[^|]*\|\s*provisional\s*\|') {
            $age = ([datetime]::UtcNow - [datetime]::ParseExact($Matches[2], 'yyyy-MM-dd', [cultureinfo]::InvariantCulture)).TotalDays
            if ($age -ge $SettleAfterDays) {
                Update-LineageStatus -Path $lineagePath -Generation $Matches[1] -Status 'settled'
                $bookkeeping.Add("$($Matches[1]) settled")
            }
        }
    }
    if ($bookkeeping.Count -gt 0) {
        Invoke-EvolverGit -Path $RepoRoot -GitArgs @('add', '--', 'evolution/lineage.md') | Out-Null
        Invoke-EvolverGit -Path $RepoRoot -GitArgs @('commit', '-q', '-m', "lineage: $($bookkeeping -join ', ')", '--', 'evolution/lineage.md') -AsEvolver | Out-Null
        Write-Log "Lineage bookkeeping committed: $($bookkeeping -join ', ')"
    }
}

$baseSha = Get-GitLine -Path $RepoRoot -GitArgs @('rev-parse', 'HEAD')
$lineage = Get-LineageState -Path $lineagePath
$generation = $lineage.LastGeneration + 1
$noteRel = "evolution/generations/gen-$generation.md"

# --- run mode: evidence -> headless proposal in a worktree ---------------------------------------------------------
if (-not $ProposalDir) {
    $fallback = if ($lineage.LastDate) { $lineage.LastDate } else { [datetime]::UtcNow.AddDays(-30) }
    $since = Get-LastGenerationTime -Generation $lineage.LastGeneration -FallbackDate $fallback
    $threshold = $since.AddSeconds(1)
    $journalDir = Join-Path $RepoRoot 'evolution/journal'
    $journals = @()
    if (Test-Path -LiteralPath $journalDir) {
        $journals = @(Get-ChildItem -LiteralPath $journalDir -Filter '*.md' -File | Where-Object { $_.Name -ne 'TEMPLATE.md' -and $_.LastWriteTimeUtc -gt $threshold } | Sort-Object Name | ForEach-Object FullName)
    }
    $shortTermEmpty = Test-ShortTermEmpty -RepoRoot $RepoRoot
    if ($journals.Count -eq 0 -and $shortTermEmpty -and -not $Force) {
        Write-Log "There is no journal entry newer than gen/$($lineage.LastGeneration) ($($since.ToString('u'))) and short-term memory is empty; nothing to evolve. Use -Force to run anyway."
        exit 0
    }

    $prompt = [System.IO.File]::ReadAllText($promptPath).Replace('{{GENERATION}}', "$generation").Replace('{{PREVIOUS_SCORE}}', $lineage.LastScore).Replace('{{MAX_EDITS}}', "$MaxEdits").Replace('{{RETIRE_AFTER_DAYS}}', "$($config.RetireAfterDays)").Replace('{{EVIDENCE_PATH}}', '.evolver/evidence.md')
    $command = Resolve-ClaudeCommand -ClaudeCommand $ClaudeCommand
    $worktree = $null
    $previousGuard = $env:EVOLUTION_CLASSIFIER
    try {
        $worktree = New-DisposableWorktree -RepoPath $RepoRoot -Ref $baseSha -Prefix 'evolve-evolver-propose'
        New-Item -ItemType Directory -Path (Join-Path $worktree '.evolver') -Force | Out-Null

        # Consolidation step 1: the owner's current short-term memory, then recall counting, decay and idle forgetting.
        $layout = Get-MemoryLayout
        $shortTermSource = Join-Path $RepoRoot $layout.ShortTerm
        if (Test-Path -LiteralPath $shortTermSource) {
            New-Item -ItemType Directory -Path (Split-Path (Join-Path $worktree $layout.ShortTerm) -Parent) -Force | Out-Null
            Copy-Item -LiteralPath $shortTermSource -Destination (Join-Path $worktree $layout.ShortTerm) -Force
            $shortTermSnapshot = [System.IO.File]::ReadAllText($shortTermSource)
        }
        $recalls = Get-RecallCounts -RepoRoot $RepoRoot -Since $since
        $decay = Invoke-MemoryDecay -Root $worktree -Recalls $recalls -Limits $config.Memory
        $existingLinks = @(Get-LongTermIndex -RepoRoot $worktree | ForEach-Object Link)
        Write-Log "Memory: $($decay.Recalled.Count) memory/memories recalled, $($decay.Decayed) decayed, $($decay.Forgotten.Count) forgotten (idle); short-term memory $(if ($shortTermEmpty) { 'empty' } else { 'to consolidate' })."

        $report = [System.Text.StringBuilder]::new()
        [void] $report.AppendLine('## Memory')
        [void] $report.AppendLine("Limits: $($config.Memory.MaxLines) lines / $($config.Memory.MaxBytes) bytes per memory file; decay $($config.Memory.Decay) per cycle; forgotten after $($config.Memory.ForgetAfterCycles) idle cycle(s) below strength $($config.Memory.ForgetBelow).")
        [void] $report.AppendLine()
        [void] $report.AppendLine('### Recalled since the last generation (reads of memory/long-term/*.md; counters already updated)')
        if ($decay.Recalled.Count -eq 0) { [void] $report.AppendLine('(none)') }
        foreach ($r in $decay.Recalled) { [void] $report.AppendLine("- $($r.Link) x$($r.Count), strength $($r.Strength)") }
        [void] $report.AppendLine()
        [void] $report.AppendLine('### Forgotten by decay in this cycle (already removed)')
        if ($decay.Forgotten.Count -eq 0) { [void] $report.AppendLine('(none)') }
        foreach ($f in $decay.Forgotten) { [void] $report.AppendLine("- $($f.Link): $($f.Reason)") }
        [void] $report.AppendLine()
        foreach ($rel in $layout.ShortTerm, $layout.LongTermIndex) {
            $path = Join-Path $worktree $rel
            [void] $report.AppendLine("### $rel")
            [void] $report.AppendLine($(if (Test-Path -LiteralPath $path) { [System.IO.File]::ReadAllText($path) } else { '(missing)' }))
        }

        $evidence = New-EvidenceBundle -Since $since -Generation $generation -Journals $journals -MemoryReport $report.ToString()
        $evidencePath = Join-Path $stateDir "$stamp-evidence.md"
        [System.IO.File]::WriteAllText($evidencePath, $evidence, [System.Text.UTF8Encoding]::new($false))
        Write-Log "Evidence: $($journals.Count) journal entry/entries since $($since.ToString('u')); bundle at evolution/.state/evolver/$stamp-evidence.md"
        [System.IO.File]::WriteAllText((Join-Path $worktree '.evolver/evidence.md'), $evidence, [System.Text.UTF8Encoding]::new($false))

        Write-Log "Asking $Model for a proposal in $worktree (budget $MaxBudgetUsd USD)"
        Push-Location $worktree
        try {
            $env:EVOLUTION_CLASSIFIER = '1'
            $arguments = @('-p', $prompt, '--permission-mode', 'acceptEdits', '--allowedTools', 'Read,Glob,Grep,Write,Edit', '--output-format', 'json', '--model', $Model, '--no-session-persistence', '--max-budget-usd', $MaxBudgetUsd.ToString([cultureinfo]::InvariantCulture))
            $raw = (& $command @arguments | Out-String)
            $exit = $LASTEXITCODE
        }
        finally {
            if ($null -eq $previousGuard) { Remove-Item Env:\EVOLUTION_CLASSIFIER -ErrorAction SilentlyContinue } else { $env:EVOLUTION_CLASSIFIER = $previousGuard }
            Pop-Location
        }
        $reply = $raw
        try { $reply = [string] ($raw | ConvertFrom-Json -Depth 32).result } catch { }
        Add-Content -LiteralPath $logPath -Value "--- model reply ---`n$reply`n--- end ---" -Encoding utf8
        if ($exit -ne 0) {
            Write-Log "REFUSED: the model call exited with code $exit. $($reply.Trim())"
            exit 1
        }
        Write-Log "Model: $($reply.Trim().Split("`n")[0])"

        # Consolidation step 3: counters for new memories, capacity forgetting, short-term memory cleared.
        $shortTermTemplate = [System.IO.File]::ReadAllText((Join-Path (Get-PluginRoot) 'templates/memory-short-term.md'))
        $completion = Complete-MemoryConsolidation -Root $worktree -Limits $config.Memory -ShortTermTemplate $shortTermTemplate -ExistingLinks $existingLinks
        $forgotten = @($decay.Forgotten) + @($completion.Forgotten)
        Write-Log "Memory: $($completion.New.Count) new long-term memory/memories, $($completion.Forgotten.Count) forgotten for capacity; short-term memory cleared."
        $noteFile = Join-Path $worktree $noteRel
        $memoryChanged = (@(Invoke-EvolverGit -Path $worktree -GitArgs @('status', '--porcelain', '--', 'memory')).Count -gt 0) -or -not $shortTermEmpty
        if ($memoryChanged) {
            $noteBody = if (Test-Path -LiteralPath $noteFile) { [System.IO.File]::ReadAllText($noteFile).TrimEnd() } else { "# gen/$generation — memory consolidation`n`nScore: pending" }
            $lines = [System.Collections.Generic.List[string]]::new()
            $lines.Add('')
            $lines.Add('Recalled:')
            if ($decay.Recalled.Count -eq 0) { $lines.Add('- nothing') }
            foreach ($r in $decay.Recalled) { $lines.Add("- $($r.Link) x$($r.Count) (strength $($r.Strength))") }
            $lines.Add('')
            $lines.Add('Forgotten:')
            if ($forgotten.Count -eq 0) { $lines.Add('- nothing') }
            foreach ($f in $forgotten) { $lines.Add("- $($f.Link) — $($f.Reason)") }
            New-Item -ItemType Directory -Path (Split-Path $noteFile -Parent) -Force | Out-Null
            [System.IO.File]::WriteAllText($noteFile, ($noteBody + "`n" + ($lines -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
        }

        $changed = @(Invoke-EvolverGit -Path $worktree -GitArgs @('diff', '--name-only')) +
        @(Invoke-EvolverGit -Path $worktree -GitArgs @('ls-files', '--others', '--exclude-standard'))
        # Short-term memory is cleared against the owner's working copy, which may hold notes HEAD does not have.
        $shortTermWorktree = Join-Path $worktree (Get-MemoryLayout).ShortTerm
        if ($null -ne $shortTermSnapshot -and (Test-Path -LiteralPath $shortTermWorktree) -and [System.IO.File]::ReadAllText($shortTermWorktree) -cne $shortTermSnapshot) {
            $changed += (Get-MemoryLayout).ShortTerm
        }
        $changed = @($changed | ForEach-Object { ($_ -replace '\\', '/').Trim() } | Where-Object { $_ -and $_ -notlike '.evolver/*' } | Sort-Object -Unique)
        if ($changed.Count -eq 0) {
            Write-Log 'The evolver proposed no change; nothing to commit.'
            exit 0
        }
        $ProposalDir = Join-Path $stateDir "$stamp-proposal"
        New-Item -ItemType Directory -Path $ProposalDir -Force | Out-Null
        Copy-ProposalFiles -Source $worktree -Destination $ProposalDir -Paths $changed
        $deletedPaths = @($changed | Where-Object { -not (Test-Path -LiteralPath (Join-Path $worktree $_)) })
        if ($deletedPaths.Count -gt 0) { [System.IO.File]::WriteAllText((Join-Path $ProposalDir $script:DeletedList), (($deletedPaths -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false)) }
        Write-Log "Proposal captured: $($changed -join ', ')"
    }
    finally {
        if ($worktree) { Remove-DisposableWorktree -RepoPath $RepoRoot -Path $worktree }
    }
}

# --- proposal mode: the commit contract ---------------------------------------------------------------------------
$ProposalDir = (Resolve-Path -LiteralPath $ProposalDir).Path
$notePath = Join-Path $ProposalDir $noteRel
if (-not (Test-Path -LiteralPath $notePath)) {
    Write-Log "REFUSED: proposal has no $noteRel (next generation is gen/$generation)."
    exit 1
}

$deletedListPath = Join-Path $ProposalDir $script:DeletedList
$deletedPaths = @()
if (Test-Path -LiteralPath $deletedListPath) {
    $deletedPaths = @([System.IO.File]::ReadAllLines($deletedListPath) | ForEach-Object { ($_ -replace '\\', '/').Trim() } | Where-Object { $_ })
}
$proposalPaths = @(@(Get-ChildItem -LiteralPath $ProposalDir -Recurse -File | ForEach-Object {
            $_.FullName.Substring($ProposalDir.Length).TrimStart('\', '/') -replace '\\', '/'
        } | Where-Object { $_ -ne $script:DeletedList }) + $deletedPaths | Sort-Object -Unique)
$noteText = [System.IO.File]::ReadAllText($notePath)
$note = Get-GenerationNote -Text $noteText
$summary = if ($note.Summary) { $note.Summary } else { "generation $generation" }
Write-Log "Proposal for gen/$generation on branch '$branch' at $($baseSha.Substring(0, 12)): $($proposalPaths.Count) file(s), $($note.Changes.Count) change(s); previous score $($lineage.LastScore)."

$dirty = @(Invoke-EvolverGit -Path $RepoRoot -GitArgs (@('status', '--porcelain', '--') + $proposalPaths + @('evolution/lineage.md')))
# The owner's uncommitted short-term memory is what this run consolidated; it may be replaced if it did not change meanwhile.
$shortTermRel = (Get-MemoryLayout).ShortTerm
$shortTermNow = Join-Path $RepoRoot $shortTermRel
if ($null -ne $shortTermSnapshot -and (Test-Path -LiteralPath $shortTermNow) -and [System.IO.File]::ReadAllText($shortTermNow) -ceq $shortTermSnapshot) {
    $dirty = @($dirty | Where-Object { ($_.Substring([math]::Min(3, $_.Length)).Trim('"') -replace '\\', '/') -ne $shortTermRel })
}
if ($dirty.Count -gt 0) {
    Write-Log 'REFUSED: the owner has uncommitted changes to proposed paths; commit or stash them first:'
    $dirty | ForEach-Object { Write-Log "  $_" }
    exit 1
}

$activePaths = $proposalPaths
$currentNote = $noteText
$score = 'skipped'
$accepted = $false
for ($attempt = 1; $attempt -le 2; $attempt++) {
    $worktree = $null
    try {
        $worktree = New-DisposableWorktree -RepoPath $RepoRoot -Ref $baseSha -Prefix 'evolve-evolver'
        Copy-ProposalFiles -Source $ProposalDir -Destination $worktree -Paths $activePaths
        [System.IO.File]::WriteAllText((Join-Path $worktree $noteRel), $currentNote, [System.Text.UTF8Encoding]::new($false))

        $violations = @(Test-GenomeContract -RepoPath $RepoRoot -Base $baseSha -Worktree $worktree -MaxEdits $MaxEdits)
        if ($violations.Count -gt 0) {
            Write-Log 'REFUSED: the proposal violates the genome contract:'
            $violations | ForEach-Object { Write-Log "  VIOLATION: $_" }
            exit 1
        }

        if ($SkipRegression) {
            $accepted = $true
            break
        }

        Invoke-EvolverGit -Path $worktree -GitArgs @('add', '-A') | Out-Null
        Invoke-EvolverGit -Path $worktree -GitArgs @('commit', '-q', '-m', "gen($generation): candidate") -AsEvolver | Out-Null
        $candidateSha = Get-GitLine -Path $worktree -GitArgs @('rev-parse', 'HEAD')

        Write-Log "Attempt ${attempt}: regression on candidate $($candidateSha.Substring(0, 12))"
        $score = Get-RegressionScore -Ref $candidateSha
        if (Compare-Score -Score $score -Previous $lineage.LastScore) {
            $accepted = $true
            break
        }

        Write-Log "Score $score is below the previous $($lineage.LastScore)."
        $changes = (Get-GenerationNote -Text $currentNote).Changes
        if ($attempt -eq 1 -and $changes.Count -gt 1) {
            $dropped = $changes[-1]
            $activePaths = @($activePaths | Where-Object { $_ -notin $dropped.Files })
            $currentNote = $currentNote.TrimEnd() + "`n`nDropped after regression: Change $($dropped.Index) ($($dropped.Title)) — score $score < $($lineage.LastScore)`n"
            Write-Log "Dropping Change $($dropped.Index) ($($dropped.Title)) and retrying once."
        }
        else {
            break
        }
    }
    finally {
        if ($worktree) { Remove-DisposableWorktree -RepoPath $RepoRoot -Path $worktree }
    }
}

if (-not $accepted) {
    Add-LineageRow -Path $lineagePath -Generation '—' -Score $score -Status 'rejected' -Summary "$summary (score $score below previous $($lineage.LastScore); no commit)"
    Write-Log "Score: $score"
    Write-Log "REJECTED: no generation committed; a 'rejected' row was appended to evolution/lineage.md (uncommitted)."
    exit 0
}

$prevLabel = if ($lineage.LastScore) { $lineage.LastScore } else { '—' }
Copy-ProposalFiles -Source $ProposalDir -Destination $RepoRoot -Paths $activePaths
$finalNote = Set-NoteScore -Text $currentNote -Score $score -Previous $prevLabel
[System.IO.File]::WriteAllText((Join-Path $RepoRoot $noteRel), $finalNote, [System.Text.UTF8Encoding]::new($false))
Add-LineageRow -Path $lineagePath -Generation "gen/$generation" -Score $score -Status 'provisional' -Summary $summary

$commitPaths = @($activePaths + @($noteRel, 'evolution/lineage.md') | Sort-Object -Unique)
$body = ([regex]::new('(?m)^#.*\r?\n').Replace($finalNote, '', 1)).Trim()
$message = "gen($generation): $summary`n`n$body`n"
$messageFile = [System.IO.Path]::GetTempFileName()
try {
    [System.IO.File]::WriteAllText($messageFile, $message, [System.Text.UTF8Encoding]::new($false))
    Invoke-EvolverGit -Path $RepoRoot -GitArgs (@('add', '--') + $commitPaths) | Out-Null
    Invoke-EvolverGit -Path $RepoRoot -GitArgs (@('commit', '-q', '-F', $messageFile, '--') + $commitPaths) -AsEvolver | Out-Null
    Invoke-EvolverGit -Path $RepoRoot -GitArgs @('tag', "gen/$generation") | Out-Null
}
finally {
    Remove-Item -LiteralPath $messageFile -Force -ErrorAction SilentlyContinue
}

$sha = Get-GitLine -Path $RepoRoot -GitArgs @('rev-parse', 'HEAD')
Write-Log "Score: $score (prev $prevLabel)"
Write-Log "COMMITTED gen/$generation as $($sha.Substring(0, 12)) on '$branch' (not pushed): $summary"
Write-Log "Generation note: $noteRel"
exit 0
