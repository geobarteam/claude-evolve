#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:Hook = Join-Path $script:PluginRoot 'hooks/SessionStart.ps1'

    function New-FakeRepo {
        param([string] $Root)
        New-Item -ItemType Directory -Path (Join-Path $Root 'evolution\journal') -Force | Out-Null
        Set-Content -Path (Join-Path $Root 'MEMORY.md') -Value "# MEMORY`n`n## Beliefs`n`n- belief-one"
        Set-Content -Path (Join-Path $Root 'evolution\journal\TEMPLATE.md') -Value '<!-- session: {{session_id}} -->'
        foreach ($name in '2026-09-17-0900', '2026-09-18-0900', '2026-09-19-0900', '2026-09-20-0900') {
            Set-Content -Path (Join-Path $Root "evolution\journal\$name.md") -Value "<!-- session: s-$name -->`n## Task`njournal $name"
        }
    }

    function Invoke-Hook {
        param([string] $Root, [hashtable] $HookInput)
        $json = $HookInput | ConvertTo-Json -Compress
        & $script:Hook -InputJson $json -RepoRoot $Root 2>&1 | Out-String
    }
}

Describe 'SessionStart hook' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-FakeRepo -Root $script:Root
    }

    It 'SessionStart_Startup_PrintsMemoryAndThreeNewestJournals' {
        $out = Invoke-Hook -Root $script:Root -HookInput @{ session_id = 'sess-1'; source = 'startup'; hook_event_name = 'SessionStart'; cwd = $script:Root }

        $out | Should -Match 'belief-one'
        $out | Should -Match 'journal 2026-09-20-0900'
        $out | Should -Match 'journal 2026-09-19-0900'
        $out | Should -Match 'journal 2026-09-18-0900'
        $out | Should -Not -Match 'journal 2026-09-17-0900'
        $out | Should -Not -Match '\{\{session_id\}\}'
        $out | Should -Match 'Journal duty'
        $out | Should -Match 'sess-1'
    }

    It 'SessionStart_Startup_WritesSessionStateFile' {
        Invoke-Hook -Root $script:Root -HookInput @{ session_id = 'sess-2'; source = 'startup'; hook_event_name = 'SessionStart'; cwd = $script:Root } | Out-Null

        $state = Join-Path $script:Root 'evolution\.state\sess-2.json'
        Test-Path $state | Should -BeTrue
        (Get-Content $state -Raw | ConvertFrom-Json).source | Should -Be 'startup'
    }

    It 'SessionStart_Compact_PrintsMemoryOnly' {
        $out = Invoke-Hook -Root $script:Root -HookInput @{ session_id = 'sess-3'; source = 'compact'; hook_event_name = 'SessionStart'; cwd = $script:Root }

        $out | Should -Match 'belief-one'
        $out | Should -Not -Match 'journal 2026-09-20-0900'
        Test-Path (Join-Path $script:Root 'evolution\.state\sess-3.json') | Should -BeFalse
    }

    It 'SessionStart_InsideClassifierChild_PrintsNothingAndWritesNoState' {
        $env:EVOLUTION_CLASSIFIER = '1'
        try {
            $out = Invoke-Hook -Root $script:Root -HookInput @{ session_id = 'sess-child'; source = 'startup'; hook_event_name = 'SessionStart'; cwd = $script:Root }
        }
        finally {
            Remove-Item Env:\EVOLUTION_CLASSIFIER -ErrorAction SilentlyContinue
        }

        $out.Trim() | Should -BeNullOrEmpty
        Test-Path (Join-Path $script:Root 'evolution\.state\sess-child.json') | Should -BeFalse
    }

    It 'SessionStart_NoJournalsYet_StillPrintsMemory' {
        Get-ChildItem (Join-Path $script:Root 'evolution\journal') -Filter '2026-*.md' | Remove-Item
        $out = Invoke-Hook -Root $script:Root -HookInput @{ session_id = 'sess-4'; source = 'resume'; hook_event_name = 'SessionStart'; cwd = $script:Root }

        $out | Should -Match 'belief-one'
        $LASTEXITCODE | Should -Be 0
    }
}
