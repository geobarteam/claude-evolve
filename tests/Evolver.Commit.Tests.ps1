#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    $script:Evolver = Join-Path $script:PluginRoot 'scripts/evolver/Invoke-Evolver.ps1'
    $script:Shim = Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1'

    function New-Answers {
        param([string[]] $Answered = @('alpha', 'beta'))
        $map = [ordered]@{}
        if ('alpha' -in $Answered) { $map['Say alpha'] = 'alpha' }
        if ('beta' -in $Answered) { $map['Say beta'] = 'beta' }
        $path = Join-Path $TestDrive ("answers-" + [guid]::NewGuid().ToString('N') + '.json')
        $map | ConvertTo-Json | Set-Content -Path $path -Encoding utf8
        $path
    }

    function Invoke-EvolverCommit {
        param([string] $Root, [string] $ProposalDir, [string] $AnswerFile, [string] $ShimLog)
        $env:CLAUDE_SHIM_ANSWERS = $AnswerFile
        if ($ShimLog) { $env:CLAUDE_SHIM_LOG = $ShimLog }
        try {
            $out = & $script:Evolver -RepoRoot $Root -ProposalDir $ProposalDir -ClaudeCommand $script:Shim 2>&1 | Out-String
        }
        finally {
            Remove-Item Env:\CLAUDE_SHIM_ANSWERS -ErrorAction SilentlyContinue
            Remove-Item Env:\CLAUDE_SHIM_LOG -ErrorAction SilentlyContinue
        }
        [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    }

    function New-GoodProposal {
        param([string] $Root)
        $memory = [System.IO.File]::ReadAllText((Join-Path $Root 'MEMORY.md')) + "`n- **Evolved belief** (since: gen/1). text`n"
        New-Proposal -Dir (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Files @{ 'MEMORY.md' = $memory } -Note (New-Note -Summary 'add evolved belief' -Changes @(
                @{ Title = 'Add evolved belief'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md: agent lacked it' }))
    }
}

Describe 'Invoke-Evolver commit contract' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Base = New-ContractRepo -Root $script:Root
    }

    It 'Evolver_ValidProposalAndScoreNotLower_CommitsTagsAndAppendsLineage' {
        $r = Invoke-EvolverCommit -Root $script:Root -ProposalDir (New-GoodProposal -Root $script:Root) -AnswerFile (New-Answers)

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Score: 2/2'
        $head = [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1)
        $head | Should -Not -Be $script:Base
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('log', '-1', '--format=%s')) | Select-Object -First 1) | Should -Be 'gen(1): add evolved belief'
        (Invoke-RepoGit -Path $script:Root -GitArgs @('log', '-1', '--format=%B')) -join "`n" | Should -Match 'Score: 2/2 \(prev —\)'
        (Invoke-RepoGit -Path $script:Root -GitArgs @('tag', '--points-at', 'HEAD')) | Should -Contain 'gen/1'
        (Invoke-RepoGit -Path $script:Root -GitArgs @('diff', '--name-only', 'gen/0', 'HEAD')) | Sort-Object | Should -Be (@('MEMORY.md', 'evolution/generations/gen-1.md', 'evolution/lineage.md') | Sort-Object)
        (Get-Content (Join-Path $script:Root 'evolution/lineage.md'))[-1] | Should -Match '^\| gen/1 \| .* \| 2/2 \| provisional \| add evolved belief \|$'
        Get-Content (Join-Path $script:Root 'evolution/generations/gen-1.md') -Raw | Should -Match 'Score: 2/2 \(prev —\)'
        Get-Content (Join-Path $script:Root 'MEMORY.md') -Raw | Should -Match 'Evolved belief'
        (Invoke-RepoGit -Path $script:Root -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
    }

    It 'Evolver_Always_CommitsWithEvolverIdentityOnly' {
        Invoke-EvolverCommit -Root $script:Root -ProposalDir (New-GoodProposal -Root $script:Root) -AnswerFile (New-Answers) | Out-Null

        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('log', '-1', '--format=%an <%ae>')) | Select-Object -First 1) | Should -Be ('evolver <evolver@' + (Split-Path $script:Root -Leaf).ToLowerInvariant() + '.local>')
        (& git -C $script:Root config --local --get user.name 2>$null) | Should -BeNullOrEmpty -Because 'the runner must not change repo config'
        Get-Content $script:Evolver -Raw | Should -Not -Match 'git[^\n]*\bpush\b' -Because 'there is no push code path'
    }

    It 'Evolver_ScoreLower_DropsEditRetriesOnceThenRecordsRejected' {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $base = New-ContractRepo -Root $script:Root -PreviousScore '2/2'
        $log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')
        $memory = [System.IO.File]::ReadAllText((Join-Path $script:Root 'MEMORY.md')) + "`n- **Evolved belief** (since: gen/1). text`n"
        $skill = "---`nname: refit`n---`nRefit skill, rewritten"
        $proposal = New-Proposal -Dir (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Files @{ 'MEMORY.md' = $memory; '.claude/skills/refit/SKILL.md' = $skill } -Note (New-Note -Summary 'two changes' -Changes @(
                @{ Title = 'Add belief'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md' },
                @{ Title = 'Rewrite refit skill'; Files = @('.claude/skills/refit/SKILL.md'); Why = 'evolution/journal/2026-09-20-0900.md' }))

        $r = Invoke-EvolverCommit -Root $script:Root -ProposalDir $proposal -AnswerFile (New-Answers -Answered @('alpha')) -ShimLog $log

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Score: 1/2'
        $r.Output | Should -Match 'retry'
        @(Get-Content $log).Count | Should -Be 4 -Because 'two regression runs of two tasks: first attempt and one retry'
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1) | Should -Be $base -Because 'no generation commit'
        (Invoke-RepoGit -Path $script:Root -GitArgs @('tag', '-l', 'gen/1')) | Should -BeNullOrEmpty
        Get-Content (Join-Path $script:Root 'MEMORY.md') -Raw | Should -Not -Match 'Evolved belief' -Because 'the owner checkout is untouched'
        (Get-Content (Join-Path $script:Root 'evolution/lineage.md'))[-1] | Should -Match '^\| — \| .* \| 1/2 \| rejected \| .*two changes.*\|$'
    }

    It 'Evolver_ContractViolation_RefusesWithoutCommit' {
        $proposal = New-Proposal -Dir (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Files @{ 'CLAUDE.md' = (Add-ProtectedEdit -Root $script:Root) } -Note (New-Note -Summary 'bad' -Changes @(
                @{ Title = 'Loosen'; Files = @('CLAUDE.md'); Why = 'evolution/journal/2026-09-20-0900.md' }))

        $r = Invoke-EvolverCommit -Root $script:Root -ProposalDir $proposal -AnswerFile (New-Answers)

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'protected block'
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1) | Should -Be $script:Base
        (Invoke-RepoGit -Path $script:Root -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
    }

    It 'Evolver_OwnerHasUncommittedGenomeChanges_RefusesToTouchThem' {
        Set-Content -Path (Join-Path $script:Root 'MEMORY.md') -Value 'owner is editing this right now'

        $r = Invoke-EvolverCommit -Root $script:Root -ProposalDir (New-GoodProposal -Root $script:Root) -AnswerFile (New-Answers)

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'uncommitted'
        Get-Content (Join-Path $script:Root 'MEMORY.md') -Raw | Should -Match 'owner is editing'
    }

    It 'Evolver_Always_RemovesItsWorktree' {
        Invoke-EvolverCommit -Root $script:Root -ProposalDir (New-GoodProposal -Root $script:Root) -AnswerFile (New-Answers) | Out-Null

        @(Invoke-RepoGit -Path $script:Root -GitArgs @('worktree', 'list')).Count | Should -Be 1
    }
}
