#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/GitSignals.psm1') -Force
    $script:Evolver = Join-Path $script:PluginRoot 'scripts/evolver/Invoke-Evolver.ps1'
    $script:Runner = Join-Path $script:PluginRoot 'scripts/regression/Invoke-Regression.ps1'
    $script:SessionEnd = Join-Path $script:PluginRoot 'hooks/SessionEnd.ps1'
    $script:Shim = Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1'
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/transcript-corrections.jsonl'

    function Set-EvolveConfig {
        # Writes evolution/evolve.json into a scaffold and commits it with the owner identity.
        param([string] $Root, [string] $Json)
        [System.IO.File]::WriteAllText((Join-Path $Root 'evolution/evolve.json'), $Json, [System.Text.UTF8Encoding]::new($false))
        Invoke-RepoGit -Path $Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $Root -GitArgs @('commit', '-q', '-m', 'chore: configure evolve') | Out-Null
    }

    function New-AnswerFile {
        $map = [ordered]@{ 'Say alpha' = 'alpha'; 'Say beta' = 'beta' }
        $path = Join-Path $TestDrive ("answers-" + [guid]::NewGuid().ToString('N') + '.json')
        $map | ConvertTo-Json | Set-Content -Path $path -Encoding utf8
        $path
    }

    function Invoke-WithShim {
        param([scriptblock] $Call, [string] $ShimLog)
        $env:CLAUDE_SHIM_ANSWERS = New-AnswerFile
        if ($ShimLog) { $env:CLAUDE_SHIM_LOG = $ShimLog }
        try { $out = & $Call 2>&1 | Out-String }
        finally {
            Remove-Item Env:\CLAUDE_SHIM_ANSWERS -ErrorAction SilentlyContinue
            Remove-Item Env:\CLAUDE_SHIM_LOG -ErrorAction SilentlyContinue
        }
        [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    }

    function New-OneChangeProposal {
        param([string] $Root)
        $memory = [System.IO.File]::ReadAllText((Join-Path $Root 'MEMORY.md')) + "`n- **Evolved belief** (since: gen/1). text`n"
        New-Proposal -Dir (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Files @{ 'MEMORY.md' = $memory } -Note (New-Note -Summary 'add evolved belief' -Changes @(
                @{ Title = 'Add evolved belief'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md: agent lacked it' }))
    }

    function New-ThreeChangeProposal {
        param([string] $Root)
        $memory = [System.IO.File]::ReadAllText((Join-Path $Root 'MEMORY.md')) + "`n- **Evolved belief** (since: gen/1). text`n"
        New-Proposal -Dir (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Files @{
            'MEMORY.md'                    = $memory
            'CLAUDE.md'                    = (Add-OutsideEdit -Root $Root)
            '.claude/skills/refit/SKILL.md' = "---`nname: refit`n---`nRefit skill, rewritten`n"
        } -Note (New-Note -Summary 'three changes' -Changes @(
                @{ Title = 'Add belief'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md' },
                @{ Title = 'Add instruction'; Files = @('CLAUDE.md'); Why = 'evolution/journal/2026-09-20-0900.md' },
                @{ Title = 'Rewrite refit skill'; Files = @('.claude/skills/refit/SKILL.md'); Why = 'evolution/journal/2026-09-20-0900.md' }))
    }
}

Describe 'Invoke-Evolver reads evolve.json' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-ContractRepo -Root $script:Root | Out-Null
    }

    It 'Evolver_ConfiguredIdentity_CommitsWithThatNameAndEmail' {
        Set-EvolveConfig -Root $script:Root -Json '{ "evolverName": "bot", "evolverEmail": "bot@example.test" }'
        $proposal = New-OneChangeProposal -Root $script:Root

        $r = Invoke-WithShim { & $script:Evolver -RepoRoot $script:Root -ProposalDir $proposal -ClaudeCommand $script:Shim -SkipRegression }

        $r.Output | Should -Match 'COMMITTED gen/1'
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('log', '-1', '--format=%an <%ae>')) | Select-Object -First 1) | Should -Be 'bot <bot@example.test>'
    }

    It 'Evolver_ConfiguredMaxEdits2_RefusesThreeChanges' {
        Set-EvolveConfig -Root $script:Root -Json '{ "maxEdits": 2 }'
        $proposal = New-ThreeChangeProposal -Root $script:Root
        $head = [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1)

        $r = Invoke-WithShim { & $script:Evolver -RepoRoot $script:Root -ProposalDir $proposal -ClaudeCommand $script:Shim -SkipRegression }

        $r.Output | Should -Match 'REFUSED'
        $r.Output | Should -Match 'VIOLATION'
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1) | Should -Be $head
    }

    It 'Evolver_ExplicitMaxEdits_WinsOverFile' {
        Set-EvolveConfig -Root $script:Root -Json '{ "maxEdits": 2 }'
        $proposal = New-ThreeChangeProposal -Root $script:Root

        $r = Invoke-WithShim { & $script:Evolver -RepoRoot $script:Root -ProposalDir $proposal -ClaudeCommand $script:Shim -SkipRegression -MaxEdits 3 }

        $r.Output | Should -Match 'COMMITTED gen/1'
    }
}

Describe 'Invoke-Regression reads evolve.json' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-ContractRepo -Root $script:Root | Out-Null
        Set-EvolveConfig -Root $script:Root -Json '{ "regression": { "model": "opus", "allowedTools": "Read,Bash(dotnet build *)" } }'
        $script:Log = Join-Path $TestDrive ("shim-" + [guid]::NewGuid().ToString('N') + '.log')
    }

    It 'InvokeRegression_ConfiguredAllowedToolsAndModel_PassedToClaude' {
        $r = Invoke-WithShim -ShimLog $script:Log { & $script:Runner -RepoRoot $script:Root -Ref HEAD -ClaudeCommand $script:Shim }

        $r.Output | Should -Match 'Score: 2/2'
        $log = Get-Content $script:Log -Raw
        $log | Should -Match '--allowedTools Read,Bash\(dotnet build \*\)'
        $log | Should -Match '--model opus'
    }

    It 'InvokeRegression_ExplicitModel_WinsOverFile' {
        Invoke-WithShim -ShimLog $script:Log { & $script:Runner -RepoRoot $script:Root -Ref HEAD -ClaudeCommand $script:Shim -Model haiku } | Out-Null

        Get-Content $script:Log -Raw | Should -Match '--model haiku'
    }
}

Describe 'GitSignals trailer pattern' {
    It 'GetAgentCommits_CustomTrailerPattern_MatchesOnlyThatTrailer' {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Invoke-RepoGit -Path $path -GitArgs @('init', '-q', '-b', 'dev') | Out-Null
        Set-Content -Path (Join-Path $path 'a.txt') -Value 'a'
        Invoke-RepoGit -Path $path -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $path -GitArgs @('commit', '-q', '-m', "feat: by claude`n`nCo-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>") | Out-Null
        $claudeSha = [string] (@(Invoke-RepoGit -Path $path -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1)
        Set-Content -Path (Join-Path $path 'b.txt') -Value 'b'
        Invoke-RepoGit -Path $path -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $path -GitArgs @('commit', '-q', '-m', "feat: by robot`n`nGenerated-By: robot") | Out-Null
        $robotSha = [string] (@(Invoke-RepoGit -Path $path -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1)

        @(Get-AgentCommits -RepoPath $path -SinceDays 7 | ForEach-Object Sha) | Should -Be @($claudeSha)
        @(Get-AgentCommits -RepoPath $path -SinceDays 7 -TrailerPattern '^Generated-By:\s*robot' | ForEach-Object Sha) | Should -Be @($robotSha)
    }
}

Describe 'SessionEnd reads evolve.json' {
    It 'SessionEnd_ConfiguredClassifierModel_PassedToClaude' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path (Join-Path $root 'evolution/journal') -Force | Out-Null
        Set-Content -Path (Join-Path $root 'evolution/evolve.json') -Value '{ "classifier": { "model": "opus" } }'
        Copy-Item $script:Fixture (Join-Path $root 'transcript.jsonl')
        $log = Join-Path $TestDrive ("shim-" + [guid]::NewGuid().ToString('N') + '.log')
        $json = @{ session_id = 'sess-corrections'; hook_event_name = 'SessionEnd'; exit_reason = 'other'; transcript_path = (Join-Path $root 'transcript.jsonl'); cwd = $root } | ConvertTo-Json -Compress

        $r = Invoke-WithShim -ShimLog $log { & $script:SessionEnd -InputJson $json -RepoRoot $root -ClaudeCommand $script:Shim }

        $r.ExitCode | Should -Be 0
        Get-Content $log -Raw | Should -Match '--model opus'
    }
}
