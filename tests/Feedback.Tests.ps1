#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Transcript.psm1') -Force
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Feedback.psm1') -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/transcript-corrections.jsonl'
    $script:Shim = Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1'
    $script:Rubric = Join-Path $script:PluginRoot 'scripts/evolver/rubric.md'
}

Describe 'Get-PairedOwnerTurns' {
    It 'GetPairedOwnerTurns_Fixture_PairsEachOwnerTurnWithPrecedingAgentAction' {
        $records = @(Read-Transcript -Path $script:Fixture)

        $pairs = @(Get-PairedOwnerTurns -Records $records)

        $pairs.Count | Should -Be 6
        $pairs[0].Index | Should -Be 1
        $pairs[0].OwnerText | Should -Be 'Add a doctor count endpoint'
        $pairs[0].AgentAction | Should -BeNullOrEmpty
        $pairs[1].OwnerText | Should -Be 'no, use the Refit client instead of HttpClient'
        $pairs[1].AgentAction | Should -Match 'HttpClient call'
        $pairs[1].AgentAction | Should -Match 'Edit'
        $pairs[1].OwnerUuid | Should -Be 'c-u2'
        $pairs[4].AgentAction | Should -Match 'Which project holds the repositories'
    }
}

Describe 'Write-FeedbackRecord' {
    It 'WriteFeedbackRecord_AppendsOneJsonLineWithRequiredFields' {
        $root = Join-Path $TestDrive 'w1'
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        Write-FeedbackRecord -RepoRoot $root -SessionId 's1' -Signal 'praise' -Value 'exactly, like that' -Reason 'approves' -Ref 'transcript:s1#u4'
        Write-FeedbackRecord -RepoRoot $root -SessionId 's1' -Signal 'correction' -Value 'no, use Refit' -Ref 'transcript:s1#u2'

        $files = @(Get-ChildItem (Join-Path $root 'evolution/feedback') -Filter '*.jsonl')
        $files.Count | Should -Be 1
        $files[0].Name | Should -Match '^\d{4}-\d{2}-\d{2}\.jsonl$'
        $lines = @(Get-Content $files[0].FullName)
        $lines.Count | Should -Be 2
        $lines[0] | Should -Match '"ts":"\d{4}-\d{2}-\d{2}T[^"]+Z"'
        $rec = $lines[0] | ConvertFrom-Json
        $rec.session_id | Should -Be 's1'
        $rec.signal | Should -Be 'praise'
        $rec.value | Should -Be 'exactly, like that'
        $rec.reason | Should -Be 'approves'
        $rec.ref | Should -Be 'transcript:s1#u4'
        ($lines[1] | ConvertFrom-Json).PSObject.Properties.Name | Should -Not -Contain 'reason'
    }
}

Describe 'Invoke-Classifier' {
    It 'InvokeClassifier_ShimReturnsFrustration_RecordWeightedAboveCorrection' {
        $records = @(Read-Transcript -Path $script:Fixture)
        $pairs = @(Get-PairedOwnerTurns -Records $records)

        $results = @(Invoke-Classifier -Pairs $pairs -RubricPath $script:Rubric -ClaudeCommand $script:Shim)

        $results.Count | Should -Be 6
        $byUuid = @{}
        foreach ($r in $results) { $byUuid[$r.OwnerUuid] = $r }
        $byUuid['c-u2'].Label | Should -Be 'correction'
        $byUuid['c-u3'].Label | Should -Be 'frustration'
        $byUuid['c-u4'].Label | Should -Be 'praise'
        $byUuid['c-u5'].Label | Should -Be 'question'
        $byUuid['c-u6'].Label | Should -Be 'none'
        $byUuid['c-u3'].Weight | Should -BeGreaterThan $byUuid['c-u2'].Weight
    }

    It 'NewClassifierPrompt_ContainsRubricAndNumberedPairsAndBeliefTitles' {
        $records = @(Read-Transcript -Path $script:Fixture)
        $pairs = @(Get-PairedOwnerTurns -Records $records)

        $prompt = New-ClassifierPrompt -Pairs $pairs -RubricPath $script:Rubric -BeliefTitles @('Belief A', 'Belief B')

        $prompt | Should -Match 'correction'
        $prompt | Should -Match 'frustration'
        $prompt | Should -Match '\[2\] OWNER: no, use the Refit client instead of HttpClient'
        $prompt | Should -Match '\[2\] AGENT: '
        $prompt | Should -Match 'Belief A'
    }

    It 'InvokeClassifier_CallsClaudeWithBareNoSessionPersistenceAndJsonSchema' {
        $log = Join-Path $TestDrive 'shim.log'
        $env:CLAUDE_SHIM_LOG = $log
        try {
            $records = @(Read-Transcript -Path $script:Fixture)
            $pairs = @(Get-PairedOwnerTurns -Records $records)
            Invoke-Classifier -Pairs $pairs -RubricPath $script:Rubric -ClaudeCommand $script:Shim | Out-Null
        }
        finally {
            Remove-Item Env:\CLAUDE_SHIM_LOG -ErrorAction SilentlyContinue
        }

        $call = Get-Content $log -Raw
        $call | Should -Match 'EVOLUTION_CLASSIFIER=1' -Because 'the child must see the guard that silences this project''s hooks'
        $call | Should -Match '--no-session-persistence'
        $call | Should -Match '--output-format json'
        $call | Should -Match '--json-schema'
        $call | Should -Not -Match '--bare' -Because '--bare skips the keychain and leaves the CLI logged out'
        $call | Should -Not -Match '--max-turns'
        $env:EVOLUTION_CLASSIFIER | Should -BeNullOrEmpty -Because 'the guard is restored after the call'
    }
}

Describe 'Resolve-ClaudeCommand' {
    It 'ResolveClaudeCommand_ExplicitPath_ReturnedUnchanged' {
        Resolve-ClaudeCommand -ClaudeCommand 'C:\tools\my-claude.ps1' | Should -Be 'C:\tools\my-claude.ps1'
    }

    It 'ResolveClaudeCommand_EnvOverride_Wins' {
        $fake = Join-Path $TestDrive 'claude-override.cmd'
        Set-Content -Path $fake -Value '@echo off'
        $env:CLAUDE_CLI = $fake
        try {
            Resolve-ClaudeCommand -ClaudeCommand 'claude' | Should -Be $fake
        }
        finally {
            Remove-Item Env:\CLAUDE_CLI -ErrorAction SilentlyContinue
        }
    }

    It 'ResolveClaudeCommand_Default_NeverReturnsAPowerShellShim' {
        Remove-Item Env:\CLAUDE_CLI -ErrorAction SilentlyContinue
        $resolved = Resolve-ClaudeCommand -ClaudeCommand 'claude'

        $resolved | Should -Not -Match '\.ps1$'
        $resolved | Should -Not -Match '\.cmd$'
    }
}

Describe 'Session processing markers' {
    It 'SetSessionProcessed_ThenTest_ReturnsTrue' {
        $root = Join-Path $TestDrive 'm1'
        New-Item -ItemType Directory -Path $root -Force | Out-Null

        Test-SessionProcessed -RepoRoot $root -SessionId 'abc' | Should -BeFalse
        Set-SessionProcessed -RepoRoot $root -SessionId 'abc'
        Test-SessionProcessed -RepoRoot $root -SessionId 'abc' | Should -BeTrue
    }
}
