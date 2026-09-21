#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Config.psm1') -Force
    $script:SavedProjectDir = $env:CLAUDE_PROJECT_DIR
}

AfterAll {
    if ($null -eq $script:SavedProjectDir) { Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue } else { $env:CLAUDE_PROJECT_DIR = $script:SavedProjectDir }
}

Describe 'Resolve-ProjectRoot' {
    BeforeEach {
        $script:A = Join-Path $TestDrive 'a'
        $script:B = Join-Path $TestDrive 'b'
        New-Item -ItemType Directory -Path $script:A, $script:B -Force | Out-Null
        Remove-Item Env:\CLAUDE_PROJECT_DIR -ErrorAction SilentlyContinue
    }

    It 'ResolveProjectRoot_ExplicitParameter_WinsOverEnvironment' {
        $env:CLAUDE_PROJECT_DIR = $script:A

        Resolve-ProjectRoot -ProjectRoot $script:B | Should -Be (Resolve-Path $script:B).Path
    }

    It 'ResolveProjectRoot_ClaudeProjectDirSet_ReturnsIt' {
        $env:CLAUDE_PROJECT_DIR = $script:A

        Resolve-ProjectRoot | Should -Be (Resolve-Path $script:A).Path
    }

    It 'ResolveProjectRoot_HookInputCwd_UsedWhenNoEnvironment' {
        $hookInput = [pscustomobject]@{ cwd = $script:B; session_id = 's' }

        Resolve-ProjectRoot -HookInput $hookInput | Should -Be (Resolve-Path $script:B).Path
    }

    It 'ResolveProjectRoot_NothingSet_ReturnsCurrentDirectory' {
        Push-Location $script:A
        try {
            Resolve-ProjectRoot | Should -Be (Get-Location).Path
        }
        finally { Pop-Location }
    }

    It 'ResolveProjectRoot_Never_ReturnsPluginRoot' {
        Push-Location $script:B
        try {
            Resolve-ProjectRoot | Should -Not -Be $script:PluginRoot
        }
        finally { Pop-Location }
    }

    It 'ResolveProjectRoot_ExplicitMissingFolder_Throws' {
        { Resolve-ProjectRoot -ProjectRoot (Join-Path $TestDrive 'missing') } | Should -Throw '*Unable to resolve the project root*'
    }
}

Describe 'Get-PluginRoot' {
    It 'GetPluginRoot_NoEnvironment_ReturnsFolderAboveScripts' {
        $saved = $env:CLAUDE_PLUGIN_ROOT
        Remove-Item Env:\CLAUDE_PLUGIN_ROOT -ErrorAction SilentlyContinue
        try {
            Get-PluginRoot | Should -Be $script:PluginRoot
        }
        finally { if ($null -ne $saved) { $env:CLAUDE_PLUGIN_ROOT = $saved } }
    }
}

Describe 'ConvertTo-ClaudeProjectFolderName' {
    It 'ConvertToClaudeProjectFolderName_KnownWindowsPath_MatchesClaudeCodeEncoding' {
        # Verified pair: the transcript folder Claude Code created for this path on the owner's machine.
        ConvertTo-ClaudeProjectFolderName -Path 'D:\Data\gv10141\Repos\Common\FindMyDoctor-Wasm' | Should -Be 'd--Data-gv10141-Repos-Common-FindMyDoctor-Wasm'
    }

    It 'ConvertToClaudeProjectFolderName_PosixPath_ReplacesSlashesAndDots' {
        ConvertTo-ClaudeProjectFolderName -Path '/home/owner/repos/my.project' | Should -Be '-home-owner-repos-my-project'
    }
}

Describe 'Get-TranscriptDir' {
    It 'GetTranscriptDir_Configured_ReturnsConfiguredValue' {
        Get-TranscriptDir -ProjectRoot $TestDrive -Configured 'C:\transcripts\here' | Should -Be 'C:\transcripts\here'
    }

    It 'GetTranscriptDir_NotConfigured_DerivesFromProjectRootUnderHome' {
        $dir = Get-TranscriptDir -ProjectRoot 'D:\Data\gv10141\Repos\Common\FindMyDoctor-Wasm'

        $dir | Should -Match 'd--Data-gv10141-Repos-Common-FindMyDoctor-Wasm$'
        $dir | Should -Match '[\\/]\.claude[\\/]projects[\\/]'
    }
}
