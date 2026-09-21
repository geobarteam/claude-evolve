#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path

    function Get-EngineFiles {
        param([string[]] $Folders, [string[]] $Exclude = @())
        foreach ($folder in $Folders) {
            $path = Join-Path $script:PluginRoot $folder
            if (-not (Test-Path $path)) { continue }
            Get-ChildItem $path -Recurse -File | Where-Object {
                $rel = $_.FullName.Substring($script:PluginRoot.Length + 1) -replace '\\', '/'
                -not ($Exclude | Where-Object { $rel -like $_ })
            }
        }
    }
}

Describe 'Plugin manifest' {
    It 'PluginJson_Exists_NamesEvolveWithSemanticVersion' {
        $path = Join-Path $script:PluginRoot '.claude-plugin/plugin.json'
        Test-Path $path | Should -BeTrue

        $manifest = Get-Content $path -Raw | ConvertFrom-Json
        $manifest.name | Should -Be 'evolve'
        $manifest.version | Should -Match '^\d+\.\d+\.\d+$'
        $manifest.description | Should -Not -BeNullOrEmpty
    }
}

Describe 'Engine is project-agnostic' {
    It 'Engine_NoScriptOrModule_UsesPSScriptRootParentParentAsProjectRoot' {
        $pattern = [regex]::Escape('$PSScriptRoot') + "\s*'\.\.[\\/]\.\.'"
        $offenders = foreach ($file in Get-EngineFiles -Folders 'scripts', 'hooks', 'tests') {
            if ((Get-Content $file.FullName -Raw) -match $pattern) { $file.FullName }
        }

        @($offenders) | Should -BeNullOrEmpty -Because 'the project root comes from CLAUDE_PROJECT_DIR, the hook cwd or the current directory, never from the plugin location'
    }

    It 'Engine_NoFile_ContainsRepositoryOrUserSpecificPaths' {
        # tests/Config.Tests.ps1 pins the one verified transcript-folder pair; fixtures are recorded transcripts; this file holds the needles.
        $files = Get-EngineFiles -Folders 'scripts', 'hooks', 'templates', 'tests' -Exclude 'tests/Config.Tests.ps1', 'tests/PluginLayout.Tests.ps1', 'tests/fixtures/*'
        $offenders = foreach ($file in $files) {
            $text = Get-Content $file.FullName -Raw
            foreach ($needle in 'FindMyDoctor', 'd--Data-gv10141', 'gv10141', 'fmd-') {
                if ($text -match [regex]::Escape($needle)) { "$($file.FullName): $needle" }
            }
        }

        @($offenders) | Should -BeNullOrEmpty
    }
}
