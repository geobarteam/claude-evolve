#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:HooksJson = Join-Path $script:PluginRoot 'hooks/hooks.json'
    $script:Expected = [ordered]@{ SessionStart = 20; Stop = 20; SessionEnd = 120; UserPromptSubmit = 20; PostToolUse = 20 }
    $script:SavedProjectDir = $env:CLAUDE_PROJECT_DIR

    function New-FakeProject {
        param([string] $Root)
        New-Item -ItemType Directory -Path (Join-Path $Root 'evolution/journal') -Force | Out-Null
        Set-Content -Path (Join-Path $Root 'MEMORY.md') -Value "# MEMORY`n`n## Beliefs`n`n- **Gate belief** (since: gen/0). visible`n"
        Set-Content -Path (Join-Path $Root 'evolution/journal/TEMPLATE.md') -Value '<!-- session: {{session_id}} -->'
        Set-Content -Path (Join-Path $Root 'evolution/journal/2026-09-21-1300.md') -Value "<!-- session: sess-wire -->`n## Task`nx"
    }

    function Invoke-HookWithoutRoot {
        # Runs a hook with only the stdin-style JSON: no -RepoRoot and no CLAUDE_PROJECT_DIR.
        param([string] $Hook, [hashtable] $Fields)   # not $Input: that name is a PowerShell automatic variable
        Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
        $json = $Fields | ConvertTo-Json -Compress
        $out = & (Join-Path $script:PluginRoot "hooks/$Hook.ps1") -InputJson $json 2>&1 | Out-String
        [pscustomobject]@{ Output = $out; ExitCode = $LASTEXITCODE }
    }
}

AfterAll {
    if ($null -eq $script:SavedProjectDir) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $script:SavedProjectDir }
}

Describe 'hooks.json' {
    BeforeAll {
        $script:Wiring = if (Test-Path $script:HooksJson) { Get-Content $script:HooksJson -Raw | ConvertFrom-Json } else { $null }
    }

    It 'HooksJson_FiveEvents_EachCommandRunsPwshFileUnderPluginRootWithExpectedTimeout' {
        $script:Wiring | Should -Not -BeNullOrEmpty -Because 'hooks/hooks.json wires the plugin hooks'
        foreach ($event in $script:Expected.Keys) {
            $entries = @($script:Wiring.hooks.$event)
            $entries.Count | Should -Be 1 -Because "$event has one entry"
            $hook = $entries[0].hooks[0]
            $hook.type | Should -Be 'command'
            $hook.command | Should -Be "pwsh -NoProfile -NonInteractive -File `"`${CLAUDE_PLUGIN_ROOT}/hooks/$event.ps1`""
            $hook.timeout | Should -Be $script:Expected[$event]
        }
    }

    It 'HooksJson_PostToolUse_MatcherIsSkillAgentTask' {
        @($script:Wiring.hooks.PostToolUse)[0].matcher | Should -Be 'Skill|Agent|Task'
        foreach ($event in 'SessionStart', 'Stop', 'SessionEnd', 'UserPromptSubmit') {
            @($script:Wiring.hooks.$event)[0].PSObject.Properties.Name | Should -Not -Contain 'matcher'
        }
    }

    It 'HooksJson_EveryReferencedHookScript_Exists' {
        foreach ($event in $script:Expected.Keys) {
            $command = @($script:Wiring.hooks.$event)[0].hooks[0].command
            $command -match '"\$\{CLAUDE_PLUGIN_ROOT\}/(hooks/[A-Za-z]+\.ps1)"' | Should -BeTrue
            Test-Path (Join-Path $script:PluginRoot $Matches[1]) | Should -BeTrue -Because "$event names an existing script"
        }
    }
}

Describe 'Hooks resolve the project from the hook input' {
    It 'Hook_CwdInInput_UsedAsProjectRootWhenNoRepoRootParameter' {
        $root = Join-Path $TestDrive 'cwd-project'
        New-FakeProject -Root $root

        $r = Invoke-HookWithoutRoot -Hook 'SessionStart' -Fields @{ session_id = 'sess-wire'; cwd = $root; hook_event_name = 'SessionStart'; source = 'startup' }

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Gate belief'
    }

    It 'Hook_NoRootResolvable_ExitsZeroWithoutOutput' {
        $missing = Join-Path $TestDrive 'does-not-exist'

        $r = Invoke-HookWithoutRoot -Hook 'SessionStart' -Fields @{ session_id = 'sess-none'; cwd = $missing; hook_event_name = 'SessionStart'; source = 'startup' }

        $r.ExitCode | Should -Be 0
        $r.Output.Trim() | Should -BeNullOrEmpty
        Test-Path (Join-Path $script:PluginRoot 'evolution') | Should -BeFalse -Because 'the plugin folder is never treated as the project'
    }

    It 'Hook_InternalError_AppendsHookErrorsLogUnderProjectStateAndExitsZero' {
        $root = Join-Path $TestDrive 'broken-project'
        New-FakeProject -Root $root
        Set-Content -Path (Join-Path $root 'evolution/feedback') -Value 'a file where the feedback folder should be'

        $r = Invoke-HookWithoutRoot -Hook 'UserPromptSubmit' -Fields @{ session_id = 'sess-wire'; cwd = $root; hook_event_name = 'UserPromptSubmit'; prompt = '- slow' }

        $r.ExitCode | Should -Be 0
        Test-Path (Join-Path $root 'evolution/.state/hook-errors.log') | Should -BeTrue
        Get-Content (Join-Path $root 'evolution/.state/hook-errors.log') -Raw | Should -Match 'UserPromptSubmit'
    }
}

Describe 'Hook scripts are plugin-relative' {
    It 'Hooks_NoScript_ReferencesEvolutionLibOrParentParent' {
        $offenders = foreach ($file in Get-ChildItem (Join-Path $script:PluginRoot 'hooks') -Filter '*.ps1') {
            $text = Get-Content $file.FullName -Raw
            if ($text -match 'evolution[\\/]lib' -or $text -match "'\.\.[\\/]\.\.'" -or $text -match '-Fallback') { $file.Name }
        }

        @($offenders) | Should -BeNullOrEmpty
    }
}
