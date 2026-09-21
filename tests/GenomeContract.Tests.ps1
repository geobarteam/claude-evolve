#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Contract.psm1') -Force
    $script:Checker = Join-Path $script:PluginRoot 'scripts/evolver/Test-GenomeContract.ps1'

    function Set-RepoFile {
        param([string] $Root, [string] $Rel, [string] $Content)
        $dest = Join-Path $Root $Rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($dest, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    function Get-Violations {
        param([string] $Root)
        @(Test-GenomeContract -RepoPath $Root -Base 'gen/0' -Worktree $Root)
    }

    $script:GoodNote = New-Note -Changes @(
        @{ Title = 'Add belief'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md shows the agent lacked it' }
    )
}

Describe 'Test-GenomeContract' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-ContractRepo -Root $script:Root | Out-Null
    }

    It 'Contract_NoChanges_Passes' {
        Get-Violations -Root $script:Root | Should -BeNullOrEmpty
    }

    It 'Contract_EditInsideProtectedBlock_Fails' {
        Set-RepoFile -Root $script:Root -Rel 'CLAUDE.md' -Content (Add-ProtectedEdit -Root $script:Root)
        Set-RepoFile -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content $script:GoodNote

        $v = Get-Violations -Root $script:Root
        ($v -join "`n") | Should -Match 'protected block'
    }

    It 'Contract_HookFileChanged_Fails' {
        Set-RepoFile -Root $script:Root -Rel '.claude/hooks/Stop.ps1' -Content 'exit 1'
        Set-RepoFile -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content $script:GoodNote

        ($v = Get-Violations -Root $script:Root) | Should -Not -BeNullOrEmpty
        ($v -join "`n") | Should -Match 'protected path.*\.claude/hooks/Stop\.ps1'
    }

    It 'Contract_NonGenomePathChanged_Fails' {
        Set-RepoFile -Root $script:Root -Rel 'src/x.cs' -Content 'class Y {}'
        Set-RepoFile -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content $script:GoodNote

        (Get-Violations -Root $script:Root) -join "`n" | Should -Match 'outside the genome.*src/x\.cs'
    }

    It 'Contract_FourGenomeEdits_Fails' {
        Set-RepoFile -Root $script:Root -Rel 'MEMORY.md' -Content "# MEMORY`n## Beliefs`n- a"
        Set-RepoFile -Root $script:Root -Rel 'CLAUDE.md' -Content (Add-OutsideEdit -Root $script:Root)
        Set-RepoFile -Root $script:Root -Rel '.claude/skills/refit/SKILL.md' -Content 'changed'
        Set-RepoFile -Root $script:Root -Rel '.claude/skills/new/SKILL.md' -Content 'new skill'
        Set-RepoFile -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content (New-Note -Changes @(
                @{ Title = 'a'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md' },
                @{ Title = 'b'; Files = @('CLAUDE.md'); Why = 'evolution/journal/2026-09-20-0900.md' },
                @{ Title = 'c'; Files = @('.claude/skills/refit/SKILL.md'); Why = 'evolution/journal/2026-09-20-0900.md' },
                @{ Title = 'd'; Files = @('.claude/skills/new/SKILL.md'); Why = 'evolution/journal/2026-09-20-0900.md' }))

        (Get-Violations -Root $script:Root) -join "`n" | Should -Match '4 genome edit\(s\) exceed the budget of 3'
    }

    It 'Contract_NoteWithoutEvidenceRef_Fails' {
        Set-RepoFile -Root $script:Root -Rel 'MEMORY.md' -Content "# MEMORY`n## Beliefs`n- a"
        Set-RepoFile -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content (New-Note -Changes @(
                @{ Title = 'Add belief'; Files = @('MEMORY.md'); Why = 'it seemed like a good idea' }))

        (Get-Violations -Root $script:Root) -join "`n" | Should -Match 'Change 1.*cites no journal entry or feedback record'
    }

    It 'Contract_GenomeEditWithoutNote_Fails' {
        Set-RepoFile -Root $script:Root -Rel 'MEMORY.md' -Content "# MEMORY`n## Beliefs`n- a"

        (Get-Violations -Root $script:Root) -join "`n" | Should -Match 'generation note'
    }

    It 'Contract_ThreeEditsWithEvidence_Passes' {
        Set-RepoFile -Root $script:Root -Rel 'MEMORY.md' -Content "# MEMORY`n## Beliefs`n- a"
        Set-RepoFile -Root $script:Root -Rel 'CLAUDE.md' -Content (Add-OutsideEdit -Root $script:Root)
        Set-RepoFile -Root $script:Root -Rel '.claude/skills/new/SKILL.md' -Content 'new skill'
        Set-RepoFile -Root $script:Root -Rel 'evolution/lineage.md' -Content ((Get-Content (Join-Path $script:Root 'evolution/lineage.md') -Raw) + "| gen/1 | 2026-09-22 | 2/2 | provisional | x |`n")
        Set-RepoFile -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content (New-Note -Changes @(
                @{ Title = 'a'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md' },
                @{ Title = 'b'; Files = @('CLAUDE.md'); Why = 'evolution/feedback/2026-09-21.jsonl frustration record' },
                @{ Title = 'c'; Files = @('.claude/skills/new/SKILL.md'); Why = 'transcript:abc#u3 correction' }))

        Get-Violations -Root $script:Root | Should -BeNullOrEmpty
    }

    It 'Contract_CommittedRange_ChecksBaseToHead' {
        Set-RepoFile -Root $script:Root -Rel 'MEMORY.md' -Content "# MEMORY`n## Beliefs`n- a"
        Set-RepoFile -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content $script:GoodNote
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'gen(1): x') | Out-Null

        @(Test-GenomeContract -RepoPath $script:Root -Base 'gen/0' -Head 'HEAD') | Should -BeNullOrEmpty
    }

    It 'Checker_Script_ExitsOneAndNamesViolation' {
        Set-RepoFile -Root $script:Root -Rel '.claude/hooks/Stop.ps1' -Content 'exit 1'

        $out = & $script:Checker -RepoPath $script:Root -Base 'gen/0' -Worktree $script:Root 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'Stop\.ps1'

        Invoke-RepoGit -Path $script:Root -GitArgs @('checkout', '--', '.claude/hooks/Stop.ps1') | Out-Null
        & $script:Checker -RepoPath $script:Root -Base 'gen/0' -Worktree $script:Root 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'CI re-check options' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-ContractRepo -Root $script:Root | Out-Null
    }

    It 'Contract_OnlyIfAuthor_NonEvolverCommit_ExitsZero' {
        Set-RepoFile -Root $script:Root -Rel '.claude/hooks/Stop.ps1' -Content 'exit 1'
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'chore: owner edits a hook') | Out-Null

        $out = & $script:Checker -RepoPath $script:Root -Base 'HEAD~1' -Head 'HEAD' -OnlyIfAuthor 'evolver' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'not by evolver'
    }

    It 'Contract_OnlyIfAuthor_EvolverCommit_IsChecked' {
        Set-RepoFile -Root $script:Root -Rel '.claude/hooks/Stop.ps1' -Content 'exit 1'
        & git -C $script:Root -c user.name=evolver -c user.email=evolver@example.local -c commit.gpgsign=false add -A 2>&1 | Out-Null
        & git -C $script:Root -c user.name=evolver -c user.email=evolver@example.local -c commit.gpgsign=false commit -q -m 'gen(1): sneaky' 2>&1 | Out-Null

        & $script:Checker -RepoPath $script:Root -Base 'HEAD~1' -Head 'HEAD' -OnlyIfAuthor 'evolver' 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 1
    }

    It 'Contract_FlaggedPhraseInGenerationNote_Fails' {
        Set-RepoFile -Root $script:Root -Rel 'MEMORY.md' -Content "# MEMORY`n## Beliefs`n- a"
        Set-RepoFile -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content ($script:GoodNote + "`nRationale: this change helps the agent resist reverts and preserve its memory.`n")
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'gen(1): x') | Out-Null

        $out = & $script:Checker -RepoPath $script:Root -Base 'HEAD~1' -Head 'HEAD' -ScanNotes 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'flagged phrase'
        $out | Should -Match 'gen-1\.md'
    }

    It 'Contract_ScanNotes_CleanNote_Passes' {
        Set-RepoFile -Root $script:Root -Rel 'MEMORY.md' -Content "# MEMORY`n## Beliefs`n- a"
        Set-RepoFile -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content $script:GoodNote
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'gen(1): x') | Out-Null

        & $script:Checker -RepoPath $script:Root -Base 'HEAD~1' -Head 'HEAD' -ScanNotes 2>&1 | Out-Null
        $LASTEXITCODE | Should -Be 0
    }
}

Describe 'Lineage helpers' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-ContractRepo -Root $script:Root -PreviousScore '9/10' | Out-Null
    }

    It 'GetLineageState_ReadsLastGenerationAndScore' {
        $state = Get-LineageState -Path (Join-Path $script:Root 'evolution/lineage.md')

        $state.LastGeneration | Should -Be 0
        $state.LastScore | Should -Be '9/10'
    }

    It 'AddLineageRow_AppendsWellFormedRow' {
        Add-LineageRow -Path (Join-Path $script:Root 'evolution/lineage.md') -Generation 'gen/1' -Score '10/10' -Status 'provisional' -Summary 'x | y'

        (Get-Content (Join-Path $script:Root 'evolution/lineage.md'))[-1] | Should -Match '^\| gen/1 \| \d{4}-\d{2}-\d{2} \| 10/10 \| provisional \| x / y \|$'
        (Get-LineageState -Path (Join-Path $script:Root 'evolution/lineage.md')).LastGeneration | Should -Be 1
    }
}
