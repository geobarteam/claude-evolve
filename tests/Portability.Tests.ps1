#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Feedback.psm1') -Force

    function Get-CodeFiles {
        foreach ($folder in 'hooks', 'scripts', 'tests') {
            Get-ChildItem (Join-Path $script:PluginRoot $folder) -Recurse -File -Include '*.ps1', '*.psm1'
        }
    }
}

Describe 'Path hygiene for Linux and macOS' {
    It 'Engine_NoBackslashPathLiteral_InHooksScriptsOrTests' {
        # A quoted relative path with a backslash separator: 'evolution/feedback', '../lib/X.psm1'. Regex escapes
        # (\s, \d, \., \\) and rooted Windows paths ('C:\...') are not paths of the engine and are not matched.
        $pattern = "'(?:\.\.|[A-Za-z0-9_.-]+)(?:\\(?:\.\.|[A-Za-z0-9_][A-Za-z0-9_.-]*))+'"
        $offenders = foreach ($file in Get-CodeFiles) {
            foreach ($m in [regex]::Matches((Get-Content $file.FullName -Raw), $pattern)) {
                if ($m.Value -notmatch '^\x27[A-Za-z]:') { "$($file.Name): $($m.Value)" }
            }
        }

        @($offenders) | Should -BeNullOrEmpty
    }

    It 'Hooks_EveryScript_StartsWithPwshShebang' {
        foreach ($hook in Get-ChildItem (Join-Path $script:PluginRoot 'hooks') -Filter '*.ps1') {
            (Get-Content $hook.FullName -First 1) | Should -Be '#!/usr/bin/env pwsh' -Because "$($hook.Name) may be executed directly on Linux"
        }
    }

    It 'GitAttributes_ForcesLfForScripts' {
        $text = Get-Content (Join-Path $script:PluginRoot '.gitattributes') -Raw
        $text | Should -Match '(?m)^\* text=auto eol=lf'
        $text | Should -Match '(?m)^\*\.ps1 text eol=lf'
    }
}

Describe 'Resolve-ClaudeCommand' {
    It 'ResolveClaudeCommand_ExplicitCommand_ReturnedUnchanged' {
        Resolve-ClaudeCommand -ClaudeCommand 'C:\tools\claude-shim.ps1' | Should -Be 'C:\tools\claude-shim.ps1'
    }

    It 'ResolveClaudeCommand_ClaudeCliEnvSet_Wins' {
        $saved = $env:CLAUDE_CLI
        $fake = Join-Path $TestDrive 'claude-fake.cmd'
        Set-Content -Path $fake -Value '@echo off'
        $env:CLAUDE_CLI = $fake
        try { Resolve-ClaudeCommand | Should -Be $fake }
        finally { if ($null -eq $saved) { Remove-Item Env:\CLAUDE_CLI -ErrorAction SilentlyContinue } else { $env:CLAUDE_CLI = $saved } }
    }

    It 'ResolveClaudeCommand_ExeFilter_OnlyOnWindows' {
        $source = (Get-Command Resolve-ClaudeCommand).Definition
        $source | Should -Match '\$IsWindows'
        $source | Should -Match "\*\.exe"
    }
}

Describe 'Distribution' {
    It 'MarketplaceJson_ListsEvolvePluginWithOwnerAndSource' {
        $m = Get-Content (Join-Path $script:PluginRoot '.claude-plugin/marketplace.json') -Raw | ConvertFrom-Json
        $m.name | Should -Be 'claude-evolve-plugin'
        $m.owner.name | Should -Not -BeNullOrEmpty
        @($m.plugins).Count | Should -Be 1
        $m.plugins[0].name | Should -Be 'evolve'
        $m.plugins[0].source | Should -Be './'
    }

    It 'Workflow_RunsPesterOnWindowsAndUbuntuWithPwsh' {
        $yml = Get-Content (Join-Path $script:PluginRoot '.github/workflows/pester.yml') -Raw
        $yml | Should -Match 'windows-latest'
        $yml | Should -Match 'ubuntu-latest'
        $yml | Should -Match 'shell: pwsh'
        $yml | Should -Match 'Install-Module Pester'
        $yml | Should -Match 'Invoke-Pester -Path tests -CI'
        $yml | Should -Match '(?m)^on:'
    }

    It 'License_IsMit' {
        Get-Content (Join-Path $script:PluginRoot 'LICENSE') -Raw | Should -Match 'MIT License'
    }

    It 'ReadmeInstallSection_NamesMarketplaceAndPluginAndConfigKeys' {
        $readme = Get-Content (Join-Path $script:PluginRoot 'README.md') -Raw
        $readme | Should -Match '/plugin marketplace add geobarteam/claude-evolve-plugin'
        $readme | Should -Match '/plugin install evolve@claude-evolve-plugin'
        $readme | Should -Match '/evolve:init'
        $readme | Should -Match 'pwsh'
        foreach ($key in 'evolverName', 'evolverEmail', 'transcriptDir', 'maxEdits', 'settleAfterDays', 'retireAfterDays', 'allowedTools', 'maxBudgetUsd', 'agentTrailerPattern', 'mainLine') {
            $readme | Should -Match ([regex]::Escape($key)) -Because "the README documents evolve.json key $key"
        }
    }
}
