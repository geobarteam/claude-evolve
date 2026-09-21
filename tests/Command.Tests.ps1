#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    $script:Skills = 'init', 'propose', 'show', 'revert', 'collect', 'score'
    $script:Shim = Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1'
    $script:Daily = Join-Path $script:PluginRoot 'scripts/feedback/Collect-DailyFeedback.ps1'

    function Get-Skill {
        param([string] $Name)
        $path = Join-Path $script:PluginRoot "skills/$Name/SKILL.md"
        if (-not (Test-Path $path)) { return $null }
        $text = [System.IO.File]::ReadAllText($path)
        $frontMatter = if ($text -match '(?s)^---\r?\n(.*?)\r?\n---') { $Matches[1] } else { '' }
        [pscustomobject]@{ Name = $Name; Path = $path; Text = $text; FrontMatter = $frontMatter }
    }
}

Describe 'evolve skills' {
    It 'EvolveSkills_SixSubcommands_EachHasNameAndDescriptionFrontMatter' {
        foreach ($name in $script:Skills) {
            $skill = Get-Skill -Name $name
            $skill | Should -Not -BeNullOrEmpty -Because "skills/$name/SKILL.md gives /evolve:$name"
            $skill.FrontMatter | Should -Match "(?m)^name:\s*$name\s*$"
            $skill.FrontMatter | Should -Match '(?m)^description:\s*\S'
        }
    }

    It 'EvolveSkills_EveryScriptTheyName_ExistsUnderPluginScripts' {
        foreach ($name in $script:Skills) {
            $skill = Get-Skill -Name $name
            $scripts = @([regex]::Matches($skill.Text, 'scripts/[A-Za-z0-9_/.-]+\.ps1') | ForEach-Object { $_.Value } | Sort-Object -Unique)
            $scripts.Count | Should -BeGreaterThan 0 -Because "/evolve:$name runs an engine script"
            foreach ($rel in $scripts) { Test-Path (Join-Path $script:PluginRoot $rel) | Should -BeTrue -Because "/evolve:$name names $rel" }
            $skill.Text | Should -Match '\$\{CLAUDE_PLUGIN_ROOT\}' -Because 'the script path must carry the substituted plugin root'
        }
    }

    It 'EvolveSkills_NeverReferenceProjectRelativeEnginePaths' {
        foreach ($name in $script:Skills) {
            $text = (Get-Skill -Name $name).Text
            $text | Should -Not -Match 'evolution/evolver/[A-Za-z-]+\.ps1'
            $text | Should -Not -Match 'evolution/lib'
            $text | Should -Not -Match '\.claude/hooks'
            $text | Should -Not -Match 'evolution/feedback/Collect'
        }
    }

    It 'EvolveSkills_RevertSection_RequiresExplicitYesBeforeRunning' {
        $text = (Get-Skill -Name 'revert').Text
        $text.IndexOf('explicit yes') | Should -BeGreaterThan 0
        $text.IndexOf('Revert-Generation.ps1') | Should -BeGreaterThan 0
        $text.IndexOf('explicit yes') | Should -BeLessThan $text.IndexOf('Revert-Generation.ps1')
        $text | Should -Match '-Confirm:\$false'
    }

    It 'EvolveSkills_ContainNoPushOrScheduleInstruction' {
        foreach ($name in $script:Skills) {
            $text = (Get-Skill -Name $name).Text
            $text | Should -Not -Match '(?m)^\s*git push'
            $text | Should -Match '[Nn]ever push'
            $text | Should -Not -Match 'schtasks|cron\b|Register-ScheduledJob'
        }
    }

    It 'EvolveSkills_ProposeAndScore_DoNotHardCodeTheTaskCount' {
        (Get-Skill -Name 'propose').Text | Should -Not -Match 'ten tasks'
        (Get-Skill -Name 'score').Text | Should -Match 'evolution/regression/tasks'
    }
}

Describe 'Collect-DailyFeedback transcript folder report' {
    BeforeAll {
        $script:Root = Join-Path $TestDrive 'collect-scaffold'
        New-ContractRepo -Root $script:Root | Out-Null
        $script:EmptyTranscripts = Join-Path $TestDrive 'no-transcripts'
        New-Item -ItemType Directory -Path $script:EmptyTranscripts -Force | Out-Null
    }

    It 'CollectDaily_ExplicitTranscriptDir_PrintsItAsConfigured' {
        $out = & $script:Daily -RepoRoot $script:Root -TranscriptDir $script:EmptyTranscripts -ClaudeCommand $script:Shim 2>&1 | Out-String

        $out | Should -Match ('(?m)^Transcripts: ' + [regex]::Escape($script:EmptyTranscripts) + ' \(configured\)')
    }

    It 'CollectDaily_NoTranscriptDir_PrintsTheDerivedFolder' {
        $out = & $script:Daily -RepoRoot $script:Root -ClaudeCommand $script:Shim 2>&1 | Out-String

        $out | Should -Match '(?m)^Transcripts: .*[\\/]\.claude[\\/]projects[\\/].* \(derived\)'
    }
}
