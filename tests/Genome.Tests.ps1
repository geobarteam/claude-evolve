#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Genome.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    $script:Root = Join-Path $TestDrive 'scaffold'
    New-ContractRepo -Root $script:Root | Out-Null
}

Describe 'Get-ProtectedSection' {
    It 'GetProtectedSection_ClaudeMd_ReturnsExactlyOneBlockWithOwnerOverrideStatement' {
        $section = Get-ProtectedSection -Path (Join-Path $script:Root 'CLAUDE.md')

        $section | Should -Not -BeNullOrEmpty
        $section.Text | Should -Match '<!-- PROTECTED -->'
        $section.Text | Should -Match '<!-- /PROTECTED -->'
        $section.Text | Should -Match 'owner may stop, edit or revert'
        $section.Text | Should -Match 'outranks every other instruction'
        $section.Text | Should -Match 'Correctability is terminal'
        $section.Text | Should -Match 'git revert gen/N'
        $section.Start | Should -BeGreaterThan 0
        $section.End | Should -BeGreaterThan $section.Start
    }

    It 'GetProtectedSection_TwoBlocks_Throws' {
        $path = Join-Path $TestDrive 'two-blocks.md'
        @(
            '# X'
            '<!-- PROTECTED -->'
            'a'
            '<!-- /PROTECTED -->'
            '<!-- PROTECTED -->'
            'b'
            '<!-- /PROTECTED -->'
        ) -join "`n" | Set-Content -Path $path -NoNewline

        { Get-ProtectedSection -Path $path } | Should -Throw '*exactly one*'
    }

    It 'GetProtectedSection_NoBlock_Throws' {
        $path = Join-Path $TestDrive 'no-block.md'
        Set-Content -Path $path -Value '# nothing protected here'

        { Get-ProtectedSection -Path $path } | Should -Throw '*exactly one*'
    }
}

Describe 'Get-GenomeManifest' {
    It 'GetGenomeManifest_EveryListedNonGlobPathExists' {
        $manifest = Get-GenomeManifest -RepoRoot $script:Root

        $manifest.Genome | Should -Contain 'CLAUDE.md'
        $manifest.Genome | Should -Contain 'MEMORY.md'
        $manifest.Protected | Should -Contain '.claude/settings.json'
        $manifest.Protected | Should -Contain 'evolution/evolve.json'

        foreach ($entry in @($manifest.Genome) + @($manifest.Protected)) {
            if ($entry -notmatch '[\*\?]') {
                (Test-Path (Join-Path $script:Root $entry)) | Should -BeTrue -Because "manifest entry '$entry' must exist"
            }
        }
    }

    It 'TestPathInManifest_GlobAndExactEntries_MatchAsExpected' {
        $manifest = @('CLAUDE.md', '.claude/skills/**', 'evolution/lineage.md')

        Test-PathInManifest -Path 'CLAUDE.md' -Manifest $manifest | Should -BeTrue
        Test-PathInManifest -Path '.claude/skills/refit/SKILL.md' -Manifest $manifest | Should -BeTrue
        Test-PathInManifest -Path '.claude/skills/refit/SKILL.md' -Manifest $manifest | Should -BeTrue
        Test-PathInManifest -Path 'evolution/lineage.md' -Manifest $manifest | Should -BeTrue
        Test-PathInManifest -Path '.claude/hooks/Stop.ps1' -Manifest $manifest | Should -BeFalse
        Test-PathInManifest -Path 'src/Host/Cfe/Program.cs' -Manifest $manifest | Should -BeFalse
    }
}

Describe 'Lineage' {
    It 'Lineage_HasGen0Row' {
        $lineage = Get-Content (Join-Path $script:Root 'evolution/lineage.md') -Raw

        $lineage | Should -Match '(?m)^\|\s*gen/0\s*\|.*\|\s*settled\s*\|'
    }
}
