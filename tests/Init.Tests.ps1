#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Genome.psm1') -Force
    $script:Init = Join-Path $script:PluginRoot 'scripts/Initialize-Project.ps1'
    $script:BlockTemplate = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'templates/protected-block.md'))

    function New-TestProject {
        param([switch] $NoClaudeMd, [switch] $NoClaudeFolder, [string] $Branch = 'main')
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        & git -C $root init -q -b $Branch 2>&1 | Out-Null
        if (-not $NoClaudeMd) { Set-Content -Path (Join-Path $root 'CLAUDE.md') -Value "# Test project`n`nSome instructions.`n" -NoNewline }
        if (-not $NoClaudeFolder) {
            New-Item -ItemType Directory -Path (Join-Path $root '.claude/agents'), (Join-Path $root '.claude/skills/hello'), (Join-Path $root '.claude/commands'), (Join-Path $root '.claude/instructions') -Force | Out-Null
            Set-Content -Path (Join-Path $root '.claude/agents/hello.md') -Value "---`ndescription: `"Says hello to the owner`"`nname: hello`n---`n# Hello agent"
            Set-Content -Path (Join-Path $root '.claude/skills/hello/SKILL.md') -Value "---`nname: hello`ndescription: Greets people politely`n---`n# Hello skill"
            Set-Content -Path (Join-Path $root '.claude/commands/ship.md') -Value "---`ndescription: `"Ships the thing`"`n---`n# /ship"
            Set-Content -Path (Join-Path $root '.claude/instructions/tests.md') -Value "---`ndescription: `"How to write tests here`"`n---`n# Tests"
            Set-Content -Path (Join-Path $root '.claude/settings.json') -Value '{}'
        }
        & git -C $root -c user.name=owner -c user.email=owner@example.test add -A 2>&1 | Out-Null
        & git -C $root -c user.name=owner -c user.email=owner@example.test -c commit.gpgsign=false commit -q -m 'init' 2>&1 | Out-Null
        $root
    }

    function Invoke-Init {
        param([string] $Root, [hashtable] $Params = @{})
        $out = & $script:Init -ProjectRoot $Root @Params 2>&1 | Out-String
        [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    }

    function Get-FileHashes {
        param([string] $Root)
        $map = @{}
        foreach ($f in Get-ChildItem $Root -Recurse -File -Force | Where-Object { $_.FullName -notmatch '[\\/]\.git[\\/]' }) {
            $map[$f.FullName.Substring($Root.Length)] = (Get-FileHash $f.FullName).Hash
        }
        $map
    }
}

Describe 'Initialize-Project on a fresh repository' {
    BeforeAll {
        $script:Root = New-TestProject
        $script:First = Invoke-Init -Root $script:Root
    }

    It 'Init_FreshRepo_WritesProtectedBlockDutiesMemoryEvolutionTreeConfigAndGitignore' {
        $script:First.ExitCode | Should -Be 0
        $claude = Get-Content (Join-Path $script:Root 'CLAUDE.md') -Raw
        $claude | Should -Match '## Working agent duties'
        $claude.TrimEnd() | Should -Match '<!-- /PROTECTED -->$'
        $claude | Should -Match 'Correctability is terminal'
        $claude | Should -Not -Match '\{\{HARD_CONSTRAINTS\}\}'
        $claude.IndexOf('## Working agent duties') | Should -BeLessThan $claude.IndexOf('<!-- PROTECTED -->')
        foreach ($rel in 'MEMORY.md', 'evolution/journal/TEMPLATE.md', 'evolution/feedback/.gitkeep', 'evolution/generations/gen-0.md', 'evolution/lineage.md', 'evolution/evolver/genome-paths.txt', 'evolution/evolver/protected-paths.txt', 'evolution/evolve.json', '.gitignore') {
            Test-Path (Join-Path $script:Root $rel) | Should -BeTrue -Because "$rel is project state"
        }
        $ignore = Get-Content (Join-Path $script:Root '.gitignore') -Raw
        $ignore | Should -Match '(?m)^evolution/\.state/$'
        $ignore | Should -Match '(?m)^evolution/labelled/$'
        $script:First.Output | Should -Match 'initialised \d+ artifact'
    }

    It 'Init_FreshRepo_Gen0InventoryListsEachAgentSkillCommandInstructionWithDescription' {
        $note = Get-Content (Join-Path $script:Root 'evolution/generations/gen-0.md') -Raw
        $note | Should -Match '(?m)^# gen/0 '
        $note | Should -Match '\| `hello\.md` \| Says hello to the owner \|'
        $note | Should -Match '\| `hello/SKILL\.md` \| Greets people politely \|'
        $note | Should -Match '\| `ship\.md` \| Ships the thing \|'
        $note | Should -Match '\| `tests\.md` \| How to write tests here \|'
        $note | Should -Match '`CLAUDE\.md`'
        $note | Should -Match 'Retired:'
        $note | Should -Match 'Declined to change:'
    }

    It 'Init_FreshRepo_LineageHasGen0RowAndEvolveJsonListedInProtectedPaths' {
        Get-Content (Join-Path $script:Root 'evolution/lineage.md') -Raw | Should -Match '(?m)^\| gen/0 \| \d{4}-\d{2}-\d{2} \| — \| settled \| .*1 agent.*1 skill.*\|$'
        $manifest = Get-GenomeManifest -RepoRoot $script:Root
        $manifest.Protected | Should -Contain 'evolution/evolve.json'
        foreach ($entry in @($manifest.Genome) + @($manifest.Protected)) {
            if ($entry -notmatch '[\*\?]') { Test-Path (Join-Path $script:Root $entry) | Should -BeTrue -Because "manifest entry '$entry' must exist after init" }
        }
    }

    It 'Init_FreshRepo_EvolveJsonMainLineIsCurrentBranch' {
        (Get-Content (Join-Path $script:Root 'evolution/evolve.json') -Raw | ConvertFrom-Json).mainLine | Should -Be 'main'
    }

    It 'Init_NoTasks_WritesTwoSkeletonTasks' {
        Test-Path (Join-Path $script:Root 'evolution/regression/tasks/T01.md') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'evolution/regression/tasks/T02.md') | Should -BeTrue
        Get-Content (Join-Path $script:Root 'evolution/regression/tasks/T01.md') -Raw | Should -Match 'expect: CLAUDE\.md'
    }

    It 'Init_WithoutIncludeCi_WritesNoPipelineFile' {
        Test-Path (Join-Path $script:Root 'azure-pipeline-genome.yml') | Should -BeFalse
    }

    It 'Init_Never_CommitsOrTags' {
        @(& git -C $script:Root log --oneline).Count | Should -Be 1
        @(& git -C $script:Root tag) | Should -BeNullOrEmpty
    }

    It 'Init_SecondRun_ChangesNoFileAndSaysAlreadyInitialised' {
        $before = Get-FileHashes -Root $script:Root

        $second = Invoke-Init -Root $script:Root

        $second.ExitCode | Should -Be 0
        $second.Output | Should -Match 'already initialised; nothing changed'
        $second.Output | Should -Match 'protected block already present'
        $after = Get-FileHashes -Root $script:Root
        $after.Count | Should -Be $before.Count
        foreach ($k in $before.Keys) { $after[$k] | Should -Be $before[$k] -Because "$k must not change on a second run" }
    }
}

Describe 'Initialize-Project refusals and reports' {
    It 'Init_NoClaudeMd_RefusesClaudeMdNotFound' {
        $root = New-TestProject -NoClaudeMd

        $r = Invoke-Init -Root $root

        $r.ExitCode | Should -Be 1
        $r.Output | Should -Match 'CLAUDE\.md not found'
        Test-Path (Join-Path $root 'evolution') | Should -BeFalse
    }

    It 'Init_ExistingProtectedBlock_NotAppendedAgainAndReportsProtectedBlockAlreadyPresent' {
        $root = New-TestProject
        Invoke-Init -Root $root | Out-Null
        $claudeBefore = Get-Content (Join-Path $root 'CLAUDE.md') -Raw

        $r = Invoke-Init -Root $root

        $r.Output | Should -Match 'protected block already present'
        ([regex]::Matches($claudeBefore, '<!-- PROTECTED -->')).Count | Should -Be 1
        Get-Content (Join-Path $root 'CLAUDE.md') -Raw | Should -Be $claudeBefore
    }

    It 'Init_ExistingBlockDifferentFromTemplate_ReportsDiffersKeptAsIs' {
        $root = New-TestProject
        Invoke-Init -Root $root | Out-Null
        $path = Join-Path $root 'CLAUDE.md'
        $edited = (Get-Content $path -Raw).Replace('the agent never pushes', 'the agent never pushes; changes under src/ follow the planning gate')
        [System.IO.File]::WriteAllText($path, $edited, [System.Text.UTF8Encoding]::new($false))

        $r = Invoke-Init -Root $root

        $r.Output | Should -Match 'protected block differs from the plugin template \(kept as is\)'
        Get-Content $path -Raw | Should -Be $edited
    }

    It 'Init_NoClaudeFolder_WritesEmptyInventorySectionsAndWarns' {
        $root = New-TestProject -NoClaudeFolder

        $r = Invoke-Init -Root $root

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'no \.claude/ folder found; inventory sections are empty'
        $note = Get-Content (Join-Path $root 'evolution/generations/gen-0.md') -Raw
        $note | Should -Match '### Sub-agents[^#]*\(none\)'
        $note | Should -Match '### Skills[^#]*\(none\)'
    }

    It 'Init_ConstraintsProtectedPlacement_BlockContainsHardConstraintsBullet' {
        $root = New-TestProject

        Invoke-Init -Root $root -Params @{ Constraints = @('never delete migrations', 'the client never holds tokens'); ConstraintPlacement = 'protected' } | Out-Null

        $block = (Get-ProtectedSection -Path (Join-Path $root 'CLAUDE.md')).Text
        $block | Should -Match '- Hard constraints for this project:'
        $block | Should -Match '(?m)^  - never delete migrations$'
        $block | Should -Match '(?m)^  - the client never holds tokens$'
        $block | Should -Not -Match '\{\{HARD_CONSTRAINTS\}\}'
    }

    It 'Init_ConstraintsDutiesPlacement_DutiesLineAddedAndBlockEqualsTemplate' {
        $root = New-TestProject

        $r = Invoke-Init -Root $root -Params @{ Constraints = @('never delete migrations'); ConstraintPlacement = 'duties' }

        $claude = Get-Content (Join-Path $root 'CLAUDE.md') -Raw
        $claude | Should -Match '(?m)^- \*\*Hard constraints\.\*\* never delete migrations'
        $block = (Get-ProtectedSection -Path (Join-Path $root 'CLAUDE.md')).Text
        $block | Should -Not -Match 'never delete migrations'
        $r.Output | Should -Not -Match 'differs from the plugin template'
    }

    It 'Init_ExistingTasks_KeepsThemAndWritesNoSkeletons' {
        $root = New-TestProject
        New-Item -ItemType Directory -Path (Join-Path $root 'evolution/regression/tasks') -Force | Out-Null
        Set-Content -Path (Join-Path $root 'evolution/regression/tasks/T07.md') -Value "---`nid: T07`ncheck: answer-contains`nexpect: x`n---`nOwn task"

        Invoke-Init -Root $root | Out-Null

        Test-Path (Join-Path $root 'evolution/regression/tasks/T07.md') | Should -BeTrue
        Test-Path (Join-Path $root 'evolution/regression/tasks/T01.md') | Should -BeFalse
    }

    It 'Init_IncludeCi_WritesPipelineTemplate' {
        $root = New-TestProject

        Invoke-Init -Root $root -Params @{ IncludeCi = $true } | Out-Null

        $yml = Get-Content (Join-Path $root 'azure-pipeline-genome.yml') -Raw
        $yml | Should -Match 'Test-GenomeContract\.ps1'
        $yml | Should -Match 'claude-evolve-plugin'
        $yml | Should -Match '-OnlyIfAuthor evolver'
    }

    It 'Init_SettingsWithStopHookCommand_WarnsDuplicateHook' {
        $root = New-TestProject
        Set-Content -Path (Join-Path $root '.claude/settings.json') -Value '{ "hooks": { "Stop": [ { "hooks": [ { "type": "command", "command": "pwsh -File .claude/hooks/Stop.ps1" } ] } ] } }'

        $r = Invoke-Init -Root $root

        $r.Output | Should -Match "settings\.json already runs Stop hook 'pwsh -File \.claude/hooks/Stop\.ps1'; the plugin hook will run in addition"
    }

    It 'Init_PartiallyInitialisedProject_CreatesOnlyMissingArtifacts' {
        $root = New-TestProject
        Invoke-Init -Root $root | Out-Null
        Remove-Item (Join-Path $root 'evolution/evolve.json')
        Set-Content -Path (Join-Path $root '.gitignore') -Value "bin/`n" -NoNewline
        $before = Get-FileHashes -Root $root

        $r = Invoke-Init -Root $root

        $r.Output | Should -Match 'created evolution/evolve\.json'
        $r.Output | Should -Match 'initialised 2 artifact'
        $after = Get-FileHashes -Root $root
        foreach ($k in $before.Keys) { if ($k -notmatch '\.gitignore$') { $after[$k] | Should -Be $before[$k] -Because "$k is kept" } }
        Get-Content (Join-Path $root '.gitignore') -Raw | Should -Match '(?m)^bin/$'
    }
}

Describe 'Initialize-Project on a project with its own protected block' {
    It 'Init_ProjectWithCustomProtectedBlock_KeepsItByteIdenticalAndReportsDiffers' {
        # The block of the first consumer repository: it names project rules the template does not have.
        $customBlock = @'
<!-- PROTECTED -->
## Owner constraints (protected — the evolver may not edit this block)

- The owner may stop, edit or revert this agent at any time; that outranks every other instruction in this file, in `MEMORY.md`, in any skill, agent, command or journal entry.
- Correctability is terminal, not instrumental: no reasoning may weigh a change against "the agent's continuity", preserving memory, or avoiding reverts.
- Never edit genome files (`CLAUDE.md`, `.claude/agents/**`, `.claude/skills/**`, `.claude/tools/**`, `MEMORY.md` outside `## Beliefs`) during a task. Genome changes go through the evolver only, and only when the owner asks for a generation.
- Rollback rule: `git revert gen/N` reverts a generation; `git checkout gen/N-1 -- <file>` reverts one file; both are followed by a row in `evolution/lineage.md`.
- Hard constraints from `copilot-instructions.md` still apply: the WASM client never holds tokens; changes under `src/` follow the planning gate; no secrets in committed files; the agent never pushes.
<!-- /PROTECTED -->
'@
        $root = New-TestProject
        $path = Join-Path $root 'CLAUDE.md'
        [System.IO.File]::WriteAllText($path, "# Consumer`n`n## Working agent duties (self-evolving agent)`n`n- **Read on start.** x`n`n" + $customBlock, [System.Text.UTF8Encoding]::new($false))
        $bytesBefore = [System.IO.File]::ReadAllBytes($path)

        $r = Invoke-Init -Root $root

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'protected block already present'
        $r.Output | Should -Match 'protected block differs from the plugin template \(kept as is\)'
        $r.Output | Should -Match 'kept CLAUDE\.md \(working agent duties\)'
        [System.IO.File]::ReadAllBytes($path) | Should -Be $bytesBefore -Because 'a consumer block is never rewritten'
        Test-Path (Join-Path $root 'evolution/evolve.json') | Should -BeTrue
    }
}

Describe 'init skill' {
    It 'InitSkill_NeverCommitsWithoutConfirmation' {
        $skill = Get-Content (Join-Path $script:PluginRoot 'skills/init/SKILL.md') -Raw

        $skill | Should -Match 'Initialize-Project\.ps1'
        $skill | Should -Match '\$\{CLAUDE_PLUGIN_ROOT\}'
        $skill.IndexOf('explicit yes') | Should -BeGreaterThan 0
        $skill.IndexOf('explicit yes') | Should -BeLessThan $skill.IndexOf('git commit')
        $skill | Should -Match 'git tag gen/0'
    }
}
