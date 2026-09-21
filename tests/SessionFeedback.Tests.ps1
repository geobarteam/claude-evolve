#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Transcript.psm1') -Force
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Feedback.psm1') -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/transcript-corrections.jsonl'
    $script:Shim = Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1'
}

Describe 'Invoke-SessionFeedback' {
    It 'InvokeSessionFeedback_RubricPath_DefaultsToPluginRubric' {
        $root = Join-Path $TestDrive 'no-rubric-project'
        New-Item -ItemType Directory -Path (Join-Path $root 'evolution/journal') -Force | Out-Null
        Test-Path (Join-Path $root 'evolution/evolver/rubric.md') | Should -BeFalse -Because 'the project holds no rubric; the plugin does'

        $log = Join-Path $TestDrive 'shim.log'
        $env:CLAUDE_SHIM_LOG = $log
        try {
            $written = Invoke-SessionFeedback -RepoRoot $root -SessionId 'rubric-default' -TranscriptPath $script:Fixture -ClaudeCommand $script:Shim -ErrorAction Stop
        }
        finally { Remove-Item Env:\CLAUDE_SHIM_LOG -ErrorAction SilentlyContinue }

        $written | Should -BeGreaterThan 0
        Get-Content $log -Raw | Should -Match 'Owner-turn classification rubric' -Because 'the classifier prompt embeds the plugin rubric'
        Get-Content $log -Raw | Should -Match 'Owner-turn classification rubric' -Because 'the classifier prompt embeds the plugin rubric'
        @(Get-ChildItem (Join-Path $root 'evolution/feedback') -Filter '*.jsonl').Count | Should -Be 1
    }
}
