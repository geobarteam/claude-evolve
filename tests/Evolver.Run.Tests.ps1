#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    $script:Evolver = Join-Path $script:PluginRoot 'scripts/evolver/Invoke-Evolver.ps1'
    $script:Shim = Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1'

    function New-Answers {
        $path = Join-Path $TestDrive ("answers-" + [guid]::NewGuid().ToString('N') + '.json')
        [ordered]@{ 'Say alpha' = 'alpha'; 'Say beta' = 'beta' } | ConvertTo-Json | Set-Content -Path $path -Encoding utf8
        $path
    }

    function New-ShimProposal {
        # What the fake evolver "writes" into its worktree: three cited changes plus the generation note.
        param([string] $Root, [int] $Generation = 1)
        $memory = [System.IO.File]::ReadAllText((Join-Path $Root 'MEMORY.md')) + "`n- **Evolved belief** (since: gen/$Generation). text`n"
        $files = [ordered]@{
            'MEMORY.md'                     = $memory
            'CLAUDE.md'                     = (Add-OutsideEdit -Root $Root)
            '.claude/skills/refit/SKILL.md' = "---`nname: refit`n---`nRefit skill, rewritten by the evolver"
            "evolution/generations/gen-$Generation.md" = (New-Note -Generation $Generation -Summary 'three evidence-backed changes' -Changes @(
                    @{ Title = 'Add belief'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-22-0900.md: agent lacked it' },
                    @{ Title = 'Add instruction'; Files = @('CLAUDE.md'); Why = 'evolution/feedback/2026-09-22.jsonl frustration record' },
                    @{ Title = 'Rewrite refit skill'; Files = @('.claude/skills/refit/SKILL.md'); Why = 'transcript:s2#u3 correction' }))
        }
        $path = Join-Path $TestDrive ("proposal-" + [guid]::NewGuid().ToString('N') + '.json')
        $files | ConvertTo-Json -Depth 3 | Set-Content -Path $path -Encoding utf8
        $path
    }

    function Invoke-Run {
        param([string] $Root, [string] $ProposalJson, [string] $ShimLog, [string[]] $Extra = @())
        $env:CLAUDE_SHIM_ANSWERS = New-Answers
        if ($ProposalJson) { $env:CLAUDE_SHIM_PROPOSAL = $ProposalJson }
        if ($ShimLog) { $env:CLAUDE_SHIM_LOG = $ShimLog }
        try {
            $out = & $script:Evolver -RepoRoot $Root -ClaudeCommand $script:Shim @Extra 2>&1 | Out-String
        }
        finally {
            Remove-Item Env:\CLAUDE_SHIM_ANSWERS, Env:\CLAUDE_SHIM_PROPOSAL, Env:\CLAUDE_SHIM_LOG -ErrorAction SilentlyContinue
        }
        [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    }

    function Add-NewJournal {
        param([string] $Root)
        Start-Sleep -Seconds 2
        Set-Content -Path (Join-Path $Root 'evolution/journal/2026-09-22-0900.md') -Value "<!-- session: s2 -->`n## Task`nrefit work`n## Outcome`npartial — fought the refit skill`n## What I fought against`n- refit skill is stale"
    }

    function Get-HeadSha {
        param([string] $Root)
        [string] (@(Invoke-RepoGit -Path $Root -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1)
    }
}

Describe 'Invoke-Evolver run mode' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Base = New-ContractRepo -Root $script:Root
    }

    It 'Evolver_NoNewJournals_ExitsWithoutClaudeCall' {
        $log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')

        $r = Invoke-Run -Root $script:Root -ShimLog $log

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'no journal entry newer than gen/0'
        Test-Path $log | Should -BeFalse -Because 'no model call happens without new evidence'
        Get-HeadSha -Root $script:Root | Should -Be $script:Base
    }

    It 'Evolver_ShimProposal_ProducesGenCommitWithThreeCitedChanges' {
        Add-NewJournal -Root $script:Root
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'journal: session s2') | Out-Null

        $r = Invoke-Run -Root $script:Root -ProposalJson (New-ShimProposal -Root $script:Root)

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'COMMITTED gen/1'
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('log', '-1', '--format=%s')) | Select-Object -First 1) | Should -Be 'gen(1): three evidence-backed changes'
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('log', '-1', '--format=%an')) | Select-Object -First 1) | Should -Be 'evolver'
        (Invoke-RepoGit -Path $script:Root -GitArgs @('tag', '--points-at', 'HEAD')) | Should -Contain 'gen/1'
        (Invoke-RepoGit -Path $script:Root -GitArgs @('diff', '--name-only', 'HEAD~1', 'HEAD')) | Sort-Object | Should -Be (@('.claude/skills/refit/SKILL.md', 'CLAUDE.md', 'MEMORY.md', 'evolution/generations/gen-1.md', 'evolution/lineage.md') | Sort-Object)
        (Get-Content (Join-Path $script:Root 'evolution/lineage.md'))[-1] | Should -Match '^\| gen/1 \| .* \| 2/2 \| provisional \| three evidence-backed changes \|$'
        Test-Path (Join-Path $script:Root 'evolution/.state/evolver') | Should -BeTrue -Because 'the run is logged'
        @(Invoke-RepoGit -Path $script:Root -GitArgs @('worktree', 'list')).Count | Should -Be 1
    }

    It 'Evolver_ClaudeCall_SilencesHooksAndLimitsTools' {
        Add-NewJournal -Root $script:Root
        $log = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.log')

        Invoke-Run -Root $script:Root -ProposalJson (New-ShimProposal -Root $script:Root) -ShimLog $log | Out-Null

        $calls = @(Get-Content $log)
        $proposalCall = $calls | Where-Object { $_ -match 'EVOLVER PROPOSAL' } | Select-Object -First 1
        $proposalCall | Should -Not -BeNullOrEmpty -Because 'the evolver prompt names its task'
        $proposalCall | Should -Match 'EVOLUTION_CLASSIFIER=1'
        $proposalCall | Should -Match '--allowedTools Read,Glob,Grep,Write,Edit'
        $proposalCall | Should -Not -Match 'Bash'
        $proposalCall | Should -Not -Match '--bare'
        $proposalCall | Should -Match '--permission-mode acceptEdits'
        $proposalCall | Should -Match '--max-budget-usd'
    }

    It 'Evolver_RevertCommitSinceLastRun_AppendsRevertedRow' {
        Add-NewJournal -Root $script:Root
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'journal: session s2') | Out-Null
        Invoke-Run -Root $script:Root -ProposalJson (New-ShimProposal -Root $script:Root) | Out-Null
        (Invoke-RepoGit -Path $script:Root -GitArgs @('tag', '-l', 'gen/1')) | Should -Contain 'gen/1'
        Invoke-RepoGit -Path $script:Root -GitArgs @('revert', '--no-edit', 'gen/1') | Out-Null

        $r = Invoke-Run -Root $script:Root

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'gen/1 reverted'
        $rows = Get-Content (Join-Path $script:Root 'evolution/lineage.md')
        ($rows | Where-Object { $_ -match '^\| gen/1 \| .* \| reverted \|' }).Count | Should -Be 1
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('log', '-1', '--format=%an %s')) | Select-Object -First 1) | Should -Match '^evolver lineage:'
        (Invoke-RepoGit -Path $script:Root -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty

        $again = Invoke-Run -Root $script:Root
        ((Get-Content (Join-Path $script:Root 'evolution/lineage.md')) | Where-Object { $_ -match '^\| gen/1 \| .* \| reverted \|' }).Count | Should -Be 1 -Because 'a revert is recorded once'
    }

    It 'Evolver_ProvisionalOlderThan14Days_MarkedSettled' {
        Add-Content -Path (Join-Path $script:Root 'evolution/lineage.md') -Value '| gen/1 | 2026-08-01 | 2/2 | provisional | old generation |'
        Add-Content -Path (Join-Path $script:Root 'evolution/lineage.md') -Value ('| gen/2 | {0:yyyy-MM-dd} | 2/2 | provisional | fresh generation |' -f [datetime]::UtcNow)
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'lineage: seed') | Out-Null

        $r = Invoke-Run -Root $script:Root

        $r.Output | Should -Match 'gen/1 settled'
        $rows = Get-Content (Join-Path $script:Root 'evolution/lineage.md')
        ($rows | Where-Object { $_ -match '^\| gen/1 \|' }) | Should -Match '\| settled \| old generation \|'
        ($rows | Where-Object { $_ -match '^\| gen/2 \|' }) | Should -Match '\| provisional \| fresh generation \|'
    }
}
