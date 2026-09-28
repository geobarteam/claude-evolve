#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Memory.psm1') -Force
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Contract.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    $script:Limits = [pscustomobject]@{ MaxLines = 200; MaxBytes = 25600; Decay = 0.5; ForgetAfterCycles = 3; ForgetBelow = 1.0 }
    $script:ShortTermTemplate = [System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'templates/memory-short-term.md'))

    function Set-File {
        param([string] $Root, [string] $Rel, [string] $Content)
        $dest = Join-Path $Root $Rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($dest, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    function New-Topic {
        param([string] $Slug, [string] $Counters = '')
        "---`nname: $Slug`ndescription: $Slug memory`n$Counters---`nThe $Slug fact.`n"
    }

    function New-MemoryRoot {
        # Long-term memory with three memories: used (recalled), idle (about to be forgotten), fresh (no counters yet).
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Set-File -Root $root -Rel 'memory/long-term.md' -Content "# Long-term memory`n`n- [Used](long-term/used.md) — when building`n- [Idle](long-term/idle.md) — never needed`n- [Fresh](long-term/fresh.md) — new`n"
        Set-File -Root $root -Rel 'memory/long-term/used.md' -Content (New-Topic -Slug 'used' -Counters "since: 2026-09-01`nrecalls: 4`nlast_recalled: 2026-09-10`nstrength: 2`nidle_cycles: 1`n")
        Set-File -Root $root -Rel 'memory/long-term/idle.md' -Content (New-Topic -Slug 'idle' -Counters "since: 2026-08-01`nrecalls: 1`nlast_recalled: 2026-08-02`nstrength: 0.5`nidle_cycles: 2`n")
        Set-File -Root $root -Rel 'memory/long-term/fresh.md' -Content (New-Topic -Slug 'fresh')
        Set-File -Root $root -Rel 'memory/short-term.md' -Content "# Short-term memory`n`n- 2026-09-27 the build needs -NoProfile`n"
        $root
    }
}

Describe 'Memory limits' {
    It 'MeasureMemoryText_CountsLinesAndUtf8Bytes' {
        $m = Measure-MemoryText -Text "a`nbé`n"
        $m.Lines | Should -Be 2
        $m.Bytes | Should -Be 6
    }

    It 'LimitMemoryText_OverLineLimit_CutsWholeLinesAndSaysSo' {
        $text = (1..10 | ForEach-Object { "line $_" }) -join "`n"
        $cut = Limit-MemoryText -Text $text -Limits ([pscustomobject]@{ MaxLines = 3; MaxBytes = 25600 })
        $cut.Truncated | Should -BeTrue
        $cut.Text | Should -Be "line 1`nline 2`nline 3"
    }

    It 'LimitMemoryText_OverByteLimit_Cuts' {
        $cut = Limit-MemoryText -Text ("x" * 50 + "`n" + "y" * 50) -Limits ([pscustomobject]@{ MaxLines = 200; MaxBytes = 60 })
        $cut.Truncated | Should -BeTrue
        $cut.Text | Should -Not -Match 'y'
    }

    It 'TestShortTermEmpty_TemplateIsEmpty_BulletIsNot' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Set-File -Root $root -Rel 'memory/short-term.md' -Content $script:ShortTermTemplate
        Test-ShortTermEmpty -RepoRoot $root | Should -BeTrue
        Set-File -Root $root -Rel 'memory/short-term.md' -Content ($script:ShortTermTemplate + "`n- 2026-09-28 a fact`n")
        Test-ShortTermEmpty -RepoRoot $root | Should -BeFalse
    }
}

Describe 'Long-term index and recalls' {
    It 'GetLongTermIndex_ParsesTitleLinkAndHook' {
        $root = New-MemoryRoot
        $entries = @(Get-LongTermIndex -RepoRoot $root)
        $entries.Count | Should -Be 3
        $entries[0].Title | Should -Be 'Used'
        $entries[0].Link | Should -Be 'memory/long-term/used.md'
        $entries[0].Hook | Should -Be 'when building'
    }

    It 'ConvertToMemoryRelativePath_OnlyTopicFilesInsideTheProject' {
        $root = New-MemoryRoot
        ConvertTo-MemoryRelativePath -Path (Join-Path $root 'memory/long-term/used.md') -RepoRoot $root | Should -Be 'memory/long-term/used.md'
        ConvertTo-MemoryRelativePath -Path 'memory/long-term/used.md' -RepoRoot $root | Should -Be 'memory/long-term/used.md'
        ConvertTo-MemoryRelativePath -Path (Join-Path $root 'memory/long-term.md') -RepoRoot $root | Should -BeNullOrEmpty
        ConvertTo-MemoryRelativePath -Path (Join-Path $root 'src/x.cs') -RepoRoot $root | Should -BeNullOrEmpty
        ConvertTo-MemoryRelativePath -Path (Join-Path $TestDrive 'elsewhere/memory/long-term/used.md') -RepoRoot $root | Should -BeNullOrEmpty
    }

    It 'GetRecallCounts_CountsRecallRecordsAfterSinceOnly' {
        $root = New-MemoryRoot
        $today = [datetime]::UtcNow
        $old = $today.AddDays(-3).ToString('o')
        $now = $today.ToString('o')
        $lines = @(
            (@{ ts = $old; signal = 'recall'; value = 'memory/long-term/used.md' } | ConvertTo-Json -Compress),
            (@{ ts = $now; signal = 'recall'; value = 'memory/long-term/used.md' } | ConvertTo-Json -Compress),
            (@{ ts = $now; signal = 'recall'; value = 'memory/long-term/used.md' } | ConvertTo-Json -Compress),
            (@{ ts = $now; signal = 'usage'; value = 'refit' } | ConvertTo-Json -Compress)
        )
        Set-File -Root $root -Rel ("evolution/feedback/{0:yyyy-MM-dd}.jsonl" -f $today) -Content (($lines -join "`n") + "`n")

        $counts = Get-RecallCounts -RepoRoot $root -Since $today.AddDays(-1)
        $counts['memory/long-term/used.md'] | Should -Be 2
        $counts.ContainsKey('refit') | Should -BeFalse
    }
}

Describe 'Consolidation' {
    It 'InvokeMemoryDecay_RecalledStrengthens_IdleDecays_IdleWeakIsForgotten' {
        $root = New-MemoryRoot

        $result = Invoke-MemoryDecay -Root $root -Recalls @{ 'memory/long-term/used.md' = 3 } -Limits $script:Limits -Today '2026-09-28'

        $used = (Read-MemoryTopic -Path (Join-Path $root 'memory/long-term/used.md')).Front
        $used['strength'] | Should -Be '4' -Because '2 * 0.5 + 3 recalls'
        $used['recalls'] | Should -Be '7'
        $used['last_recalled'] | Should -Be '2026-09-28'
        $used['idle_cycles'] | Should -Be '0'

        $fresh = (Read-MemoryTopic -Path (Join-Path $root 'memory/long-term/fresh.md')).Front
        $fresh['strength'] | Should -Be '0.5' -Because 'a memory without counters starts at 1 and decays once'
        $fresh['idle_cycles'] | Should -Be '1'
        $fresh['since'] | Should -Be '2026-09-28'

        Test-Path (Join-Path $root 'memory/long-term/idle.md') | Should -BeFalse -Because 'three idle cycles below strength 1'
        (Get-Content (Join-Path $root 'memory/long-term.md') -Raw) | Should -Not -Match 'idle\.md'
        $result.Forgotten.Link | Should -Be @('memory/long-term/idle.md')
        $result.Recalled.Link | Should -Be @('memory/long-term/used.md')
    }

    It 'InvokeMemoryDecay_StrongIdleMemory_IsKept' {
        $root = New-MemoryRoot
        Set-File -Root $root -Rel 'memory/long-term/idle.md' -Content (New-Topic -Slug 'idle' -Counters "since: 2026-08-01`nrecalls: 30`nlast_recalled: 2026-08-02`nstrength: 12`nidle_cycles: 5`n")

        $result = Invoke-MemoryDecay -Root $root -Recalls @{} -Limits $script:Limits

        Test-Path (Join-Path $root 'memory/long-term/idle.md') | Should -BeTrue -Because 'a much-used memory survives a long idle stretch'
        $result.Forgotten.Count | Should -Be 0
    }

    It 'CompleteMemoryConsolidation_GivesNewMemoriesCountersAndClearsShortTerm' {
        $root = New-MemoryRoot
        $existing = @(Get-LongTermIndex -RepoRoot $root | ForEach-Object Link)
        Set-File -Root $root -Rel 'memory/long-term/build.md' -Content "---`nname: build`ndescription: build flag`n---`nThe build needs -NoProfile.`n"
        Add-Content -Path (Join-Path $root 'memory/long-term.md') -Value '- [Build](long-term/build.md) — when running pwsh builds'

        $result = Complete-MemoryConsolidation -Root $root -Limits $script:Limits -ShortTermTemplate $script:ShortTermTemplate -ExistingLinks $existing -Today '2026-09-28'

        $result.New | Should -Be @('memory/long-term/build.md')
        $front = (Read-MemoryTopic -Path (Join-Path $root 'memory/long-term/build.md')).Front
        $front['strength'] | Should -Be '1'
        $front['recalls'] | Should -Be '0'
        $front['since'] | Should -Be '2026-09-28'
        [System.IO.File]::ReadAllText((Join-Path $root 'memory/short-term.md')) | Should -Be $script:ShortTermTemplate
    }

    It 'CompleteMemoryConsolidation_IndexOverLimit_ForgetsWeakestOldMemoryButKeepsNewOnes' {
        $root = New-MemoryRoot
        $existing = @(Get-LongTermIndex -RepoRoot $root | ForEach-Object Link)
        Set-File -Root $root -Rel 'memory/long-term/new.md' -Content (New-Topic -Slug 'new')
        Add-Content -Path (Join-Path $root 'memory/long-term.md') -Value '- [New](long-term/new.md) — just learned'
        $lines = @(Get-Content (Join-Path $root 'memory/long-term.md')).Count

        $result = Complete-MemoryConsolidation -Root $root -Limits ([pscustomobject]@{ MaxLines = $lines - 1; MaxBytes = 25600; Decay = 0.5; ForgetAfterCycles = 3; ForgetBelow = 1 }) -ShortTermTemplate $script:ShortTermTemplate -ExistingLinks $existing

        $result.Forgotten.Link | Should -Be @('memory/long-term/idle.md') -Because 'idle has the lowest strength (0.5)'
        Test-Path (Join-Path $root 'memory/long-term/new.md') | Should -BeTrue
        Test-Path (Join-Path $root 'memory/long-term/used.md') | Should -BeTrue
    }

    It 'TestMemoryShape_ReportsMissingFileOrphanAndOverLimit' {
        $root = New-MemoryRoot
        Test-MemoryShape -Root $root -Limits $script:Limits | Should -BeNullOrEmpty

        Remove-Item (Join-Path $root 'memory/long-term/fresh.md')
        Set-File -Root $root -Rel 'memory/long-term/orphan.md' -Content (New-Topic -Slug 'orphan')
        Set-File -Root $root -Rel 'memory/short-term.md' -Content ((1..201 | ForEach-Object { "- note $_" }) -join "`n")

        $violations = @(Test-MemoryShape -Root $root -Limits $script:Limits)
        $violations | Should -Contain 'memory/long-term.md links to a missing memory: memory/long-term/fresh.md'
        $violations | Should -Contain 'memory memory/long-term/orphan.md has no line in memory/long-term.md'
        ($violations -join "`n") | Should -Match 'memory/short-term.md is 201 line\(s\)'
    }
}

Describe 'Memory hooks' {
    BeforeEach {
        $script:Root = New-MemoryRoot
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'evolution/feedback') -Force | Out-Null
    }

    It 'PostToolUse_ReadOfLongTermMemory_WritesRecallRecord' {
        $json = @{ session_id = 'sess-r'; hook_event_name = 'PostToolUse'; tool_name = 'Read'; tool_input = @{ file_path = (Join-Path $script:Root 'memory/long-term/used.md') }; tool_use_id = 'tu-9'; cwd = $script:Root } | ConvertTo-Json -Compress -Depth 5
        & (Join-Path $script:PluginRoot 'hooks/PostToolUse.ps1') -InputJson $json -RepoRoot $script:Root | Out-Null

        $records = @(Get-ChildItem (Join-Path $script:Root 'evolution/feedback') -Filter '*.jsonl' | Get-Content | ConvertFrom-Json)
        $records.Count | Should -Be 1
        $records[0].signal | Should -Be 'recall'
        $records[0].value | Should -Be 'memory/long-term/used.md'
        $records[0].ref | Should -Be 'transcript:sess-r#tu-9'
    }

    It 'PostToolUse_ReadOfOtherFile_WritesNothing' {
        $json = @{ session_id = 'sess-r'; hook_event_name = 'PostToolUse'; tool_name = 'Read'; tool_input = @{ file_path = (Join-Path $script:Root 'memory/long-term.md') }; cwd = $script:Root } | ConvertTo-Json -Compress -Depth 5
        & (Join-Path $script:PluginRoot 'hooks/PostToolUse.ps1') -InputJson $json -RepoRoot $script:Root | Out-Null

        @(Get-ChildItem (Join-Path $script:Root 'evolution/feedback') -Filter '*.jsonl').Count | Should -Be 0
    }

    It 'Stop_ShortTermOverLimit_BlocksAskingToCompress' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'evolution/journal') -Force | Out-Null
        Set-File -Root $script:Root -Rel 'evolution/journal/2026-09-28-0900.md' -Content "<!-- session: sess-s -->`n## Task`nx`n"
        Set-File -Root $script:Root -Rel 'memory/short-term.md' -Content ((1..250 | ForEach-Object { "- note $_" }) -join "`n")
        $json = @{ session_id = 'sess-s'; hook_event_name = 'Stop'; stop_hook_active = $false; cwd = $script:Root } | ConvertTo-Json -Compress

        $out = & (Join-Path $script:PluginRoot 'hooks/Stop.ps1') -InputJson $json -RepoRoot $script:Root | Out-String

        ($out | ConvertFrom-Json).decision | Should -Be 'block'
        $out | Should -Match 'short-term.md is 250 lines'
    }

    It 'SessionStart_LongTermIndexOverLimit_IsCutAndSaysSo' {
        Set-File -Root $script:Root -Rel 'evolution/evolve.json' -Content '{ "memory": { "maxLines": 3 } }'
        $json = @{ session_id = 'sess-t'; source = 'compact'; hook_event_name = 'SessionStart'; cwd = $script:Root } | ConvertTo-Json -Compress

        $out = & (Join-Path $script:PluginRoot 'hooks/SessionStart.ps1') -InputJson $json -RepoRoot $script:Root | Out-String

        $out | Should -Match 'Used'
        $out | Should -Not -Match 'Fresh'
        $out | Should -Match 'cut at 3 lines'
    }
}

Describe 'Memory in the genome contract' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $script:Base = New-ContractRepo -Root $script:Root
    }

    It 'Contract_MemoryEdits_DoNotCountAgainstTheBudget' {
        Set-File -Root $script:Root -Rel 'memory/long-term/a.md' -Content (New-Topic -Slug 'a')
        Set-File -Root $script:Root -Rel 'memory/long-term/b.md' -Content (New-Topic -Slug 'b')
        Add-Content -Path (Join-Path $script:Root 'memory/long-term.md') -Value "- [A](long-term/a.md) — a`n- [B](long-term/b.md) — b"
        Set-File -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content (New-Note -Summary 'memory only' -Changes @())

        Test-GenomeContract -RepoPath $script:Root -Base $script:Base -Worktree $script:Root -MaxEdits 1 | Should -BeNullOrEmpty
    }

    It 'Contract_BrokenMemoryShape_IsAViolation' {
        Add-Content -Path (Join-Path $script:Root 'memory/long-term.md') -Value '- [Ghost](long-term/ghost.md) — nothing behind it'
        Set-File -Root $script:Root -Rel 'evolution/generations/gen-1.md' -Content (New-Note -Summary 'bad memory' -Changes @())

        Test-GenomeContract -RepoPath $script:Root -Base $script:Base -Worktree $script:Root | Should -Contain 'memory/long-term.md links to a missing memory: memory/long-term/ghost.md'
    }
}

Describe 'Invoke-Evolver consolidation' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-ContractRepo -Root $script:Root | Out-Null
        Set-File -Root $script:Root -Rel 'memory/long-term.md' -Content ([System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'templates/memory-long-term.md')) + "`n- [Used](long-term/used.md) — when building`n- [Idle](long-term/idle.md) — never needed`n")
        Set-File -Root $script:Root -Rel 'memory/long-term/used.md' -Content (New-Topic -Slug 'used' -Counters "since: 2026-09-01`nrecalls: 4`nlast_recalled: 2026-09-10`nstrength: 2`nidle_cycles: 1`n")
        Set-File -Root $script:Root -Rel 'memory/long-term/idle.md' -Content (New-Topic -Slug 'idle' -Counters "since: 2026-08-01`nrecalls: 1`nlast_recalled: 2026-08-02`nstrength: 0.5`nidle_cycles: 2`n")
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'memory baseline') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('tag', '-f', 'gen/0') | Out-Null
        Start-Sleep -Seconds 2
        # A session since: one recall, a short-term note left uncommitted by the working agent.
        Set-File -Root $script:Root -Rel ("evolution/feedback/{0:yyyy-MM-dd}.jsonl" -f [datetime]::UtcNow) -Content ((@{ ts = [datetime]::UtcNow.ToString('o'); session_id = 's2'; signal = 'recall'; value = 'memory/long-term/used.md'; ref = 'transcript:s2#u1' } | ConvertTo-Json -Compress) + "`n")
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'feedback: session s2') | Out-Null
        Set-File -Root $script:Root -Rel 'memory/short-term.md' -Content ([System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'templates/memory-short-term.md')) + "`n- 2026-09-28 the build needs -NoProfile`n")

        $index = [System.IO.File]::ReadAllText((Join-Path $script:Root 'memory/long-term.md')) -replace '(?m)^- \[Idle\].*\r?\n', ''
        $proposal = [ordered]@{
            'memory/long-term/build.md'      = "---`nname: build`ndescription: build flag`n---`nThe build needs -NoProfile.`n"
            'memory/long-term.md'            = $index + "- [Build](long-term/build.md) — when running pwsh builds`n"
            'evolution/generations/gen-1.md' = "# gen/1 — remember the build flag`n`nScore: pending`n`nRemembered:`n- memory/long-term/build.md — new: the build needs -NoProfile`n`nRetired:`n- nothing`n`nDeclined to change:`n- nothing`n"
        }
        $script:ProposalJson = Join-Path $TestDrive ("proposal-" + [guid]::NewGuid().ToString('N') + '.json')
        $proposal | ConvertTo-Json -Depth 3 | Set-Content -Path $script:ProposalJson -Encoding utf8
        $script:Answers = Join-Path $TestDrive ("answers-" + [guid]::NewGuid().ToString('N') + '.json')
        [ordered]@{ 'Say alpha' = 'alpha'; 'Say beta' = 'beta' } | ConvertTo-Json | Set-Content -Path $script:Answers -Encoding utf8
    }

    It 'Evolver_ShortTermNoteAndRecall_CommitsConsolidatedMemory' {
        $env:CLAUDE_SHIM_PROPOSAL = $script:ProposalJson
        $env:CLAUDE_SHIM_ANSWERS = $script:Answers
        try {
            $out = & (Join-Path $script:PluginRoot 'scripts/evolver/Invoke-Evolver.ps1') -RepoRoot $script:Root -ClaudeCommand (Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1') 2>&1 | Out-String
        }
        finally {
            Remove-Item Env:\CLAUDE_SHIM_PROPOSAL, Env:\CLAUDE_SHIM_ANSWERS -ErrorAction SilentlyContinue
        }

        $out | Should -Match 'COMMITTED gen/1'
        $changed = @(Invoke-RepoGit -Path $script:Root -GitArgs @('diff', '--name-only', 'HEAD~1', 'HEAD')) | Sort-Object
        $changed | Should -Be (@('evolution/generations/gen-1.md', 'evolution/lineage.md', 'memory/long-term.md', 'memory/long-term/build.md', 'memory/long-term/idle.md', 'memory/long-term/used.md') | Sort-Object) -Because 'the committed short-term memory was already the template; only the working copy held the note'
        Test-Path (Join-Path $script:Root 'memory/long-term/idle.md') | Should -BeFalse -Because 'the idle weak memory was forgotten and its deletion committed'
        (Read-MemoryTopic -Path (Join-Path $script:Root 'memory/long-term/used.md')).Front['strength'] | Should -Be '2'
        (Read-MemoryTopic -Path (Join-Path $script:Root 'memory/long-term/build.md')).Front['strength'] | Should -Be '1'
        Test-ShortTermEmpty -RepoRoot $script:Root | Should -BeTrue
        @(Invoke-RepoGit -Path $script:Root -GitArgs @('status', '--porcelain')) | Where-Object { $_ -match 'memory/' } | Should -BeNullOrEmpty
        $note = Get-Content (Join-Path $script:Root 'evolution/generations/gen-1.md') -Raw
        $note | Should -Match '(?m)^Recalled:\s*\n- memory/long-term/used.md x1'
        $note | Should -Match '(?m)^Forgotten:\s*\n- memory/long-term/idle.md'
    }

    It 'Evolver_ShortTermChangedDuringRun_RefusesInsteadOfOverwriting' {
        # The owner's short-term memory differs from the proposal's snapshot: a proposal folder written by hand.
        $dir = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Set-File -Root $dir -Rel 'memory/short-term.md' -Content $script:ShortTermTemplate
        Set-File -Root $dir -Rel 'evolution/generations/gen-1.md' -Content (New-Note -Summary 'clear' -Changes @())

        $out = & (Join-Path $script:PluginRoot 'scripts/evolver/Invoke-Evolver.ps1') -RepoRoot $script:Root -ProposalDir $dir -SkipRegression 2>&1 | Out-String

        $out | Should -Match 'REFUSED: the owner has uncommitted changes'
    }
}

Describe 'Init migration' {
    It 'ConvertLegacyMemory_EveryBulletBecomesALongTermMemory' {
        Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Init.psm1') -Force
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Set-File -Root $root -Rel 'MEMORY.md' -Content "# MEMORY`n`n## Beliefs`n`n- **Persistence lives in Core.Persistence** (since: gen/0). Every repository class is there.`n  Use it for new stores.`n- plain bullet about the build`n`n## Conventions`n`n_(evolver-owned; empty at gen/0)_`n"

        Convert-LegacyMemory -ProjectRoot $root | Should -Be 2

        $entries = @(Get-LongTermIndex -RepoRoot $root)
        $entries.Title | Should -Be @('Persistence lives in Core.Persistence', 'plain bullet about the build')
        Test-MemoryShape -Root $root -Limits $script:Limits | Should -BeNullOrEmpty
        Get-Content (Join-Path $root $entries[0].Link) -Raw | Should -Match 'Use it for new stores'
        Convert-LegacyMemory -ProjectRoot $root | Should -Be -1 -Because 'a second run changes nothing'
    }
}
