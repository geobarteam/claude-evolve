#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Transcript.psm1') -Force
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/transcript-basic.jsonl'
}

Describe 'Read-Transcript' {
    It 'ReadTranscript_Fixture_SkipsUnparsableLinesAndKeepsUnknownTypes' {
        $records = Read-Transcript -Path $script:Fixture

        $records.Count | Should -Be 11
        ($records | Where-Object type -EQ 'queue-operation').Count | Should -Be 1
    }
}

Describe 'Get-UserTurns' {
    It 'ReadTranscript_Fixture_ReturnsThreeUserTurnsAndIgnoresThinking' {
        $records = Read-Transcript -Path $script:Fixture

        $users = @(Get-UserTurns -Records $records)
        $assistants = @(Get-AssistantTurns -Records $records)

        $users.Count | Should -Be 3 -Because 'tool_result and isMeta records are not owner prompts'
        $users[0].Text | Should -Be 'Add a GetDoctorCount method to the doctor client'
        $users[1].Text | Should -Be 'no, use the existing Get pattern, not a new base call'
        $users[2].Text | Should -Be 'exactly, like that'
        $users[2].Uuid | Should -Be 'u4'

        ($assistants | ForEach-Object Text) -join ' ' | Should -Not -Match 'private reasoning'
        ($assistants | Where-Object Uuid -EQ 'a2').ToolUses | Should -Contain 'Read'
    }
}

Describe 'Get-LastUserTimestamp' {
    It 'GetLastUserTimestamp_Fixture_ReturnsTimestampOfLastOwnerPromptInUtc' {
        $ts = Get-LastUserTimestamp -Path $script:Fixture

        $ts | Should -BeOfType [datetime]
        $ts.Kind | Should -Be ([System.DateTimeKind]::Utc)
        $ts | Should -Be ([datetime]::Parse('2026-09-21T09:04:00Z', $null, [System.Globalization.DateTimeStyles]::AdjustToUniversal))
    }

    It 'GetLastUserTimestamp_MissingFile_ReturnsNull' {
        Get-LastUserTimestamp -Path (Join-Path $TestDrive 'missing.jsonl') | Should -BeNullOrEmpty
    }
}
