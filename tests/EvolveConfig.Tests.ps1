#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Config.psm1') -Force

    function New-Project {
        param([string] $Name = 'My-Project', [string] $ConfigJson)
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $root = Join-Path $root $Name
        New-Item -ItemType Directory -Path (Join-Path $root 'evolution') -Force | Out-Null
        if ($PSBoundParameters.ContainsKey('ConfigJson')) { Set-Content -Path (Join-Path $root 'evolution/evolve.json') -Value $ConfigJson -NoNewline }
        $root
    }
}

Describe 'Get-EvolveConfig' {
    It 'GetEvolveConfig_NoFile_ReturnsEverySpecDefault' {
        $c = Get-EvolveConfig -ProjectRoot (New-Project)

        $c.EvolverName | Should -Be 'evolver'
        $c.MaxEdits | Should -Be 3
        $c.SettleAfterDays | Should -Be 14
        $c.RetireAfterDays | Should -Be 30
        $c.Regression.Model | Should -Be 'sonnet'
        $c.Regression.AllowedTools | Should -Be 'Read,Glob,Grep,Edit,Write'
        $c.Proposal.Model | Should -Be 'sonnet'
        $c.Proposal.MaxBudgetUsd | Should -Be 3
        $c.Classifier.Model | Should -Be 'haiku'
        $c.AgentTrailerPattern | Should -Be '^Co-Authored-By:\s*Claude\b'
        $c.MainLine | Should -Be ''
        $c.TranscriptDir | Should -Match 'My-Project$'
        $c.Source | Should -Be 'defaults'
    }

    It 'GetEvolveConfig_DefaultEvolverEmail_UsesLowerCaseProjectFolderName' {
        (Get-EvolveConfig -ProjectRoot (New-Project -Name 'My-Project')).EvolverEmail | Should -Be 'evolver@my-project.local'
    }

    It 'GetEvolveConfig_PartialFile_OverridesOnlyGivenKeys' {
        $root = New-Project -ConfigJson '{ "maxEdits": 2, "regression": { "allowedTools": "Read,Bash(dotnet build *)" } }'

        $c = Get-EvolveConfig -ProjectRoot $root

        $c.MaxEdits | Should -Be 2
        $c.Regression.AllowedTools | Should -Be 'Read,Bash(dotnet build *)'
        $c.Regression.Model | Should -Be 'sonnet'
        $c.EvolverName | Should -Be 'evolver'
        $c.Proposal.MaxBudgetUsd | Should -Be 3
        $c.Source | Should -Be 'evolution/evolve.json'
    }

    It 'GetEvolveConfig_EmptyStringsInFile_FallBackToDefaults' {
        $root = New-Project -ConfigJson '{ "evolverEmail": "", "transcriptDir": "", "mainLine": "" }'

        $c = Get-EvolveConfig -ProjectRoot $root

        $c.EvolverEmail | Should -Be 'evolver@my-project.local'
        $c.TranscriptDir | Should -Match 'My-Project$'
    }

    It 'GetEvolveConfig_TranscriptDirKey_Wins' {
        $root = New-Project -ConfigJson '{ "transcriptDir": "C:\\transcripts\\elsewhere" }'

        (Get-EvolveConfig -ProjectRoot $root).TranscriptDir | Should -Be 'C:\transcripts\elsewhere'
    }

    It 'GetEvolveConfig_InvalidJson_ThrowsNamingTheFile' {
        $root = New-Project -ConfigJson '{ not json'

        { Get-EvolveConfig -ProjectRoot $root } | Should -Throw '*evolution/evolve.json is not valid JSON*'
    }

    It 'GetEvolveConfig_TemplateFile_ParsesToTheDefaults' {
        $root = New-Project -ConfigJson ([System.IO.File]::ReadAllText((Join-Path $script:PluginRoot 'templates/evolve.json')))

        $c = Get-EvolveConfig -ProjectRoot $root

        $c.MaxEdits | Should -Be 3
        $c.AgentTrailerPattern | Should -Be '^Co-Authored-By:\s*Claude\b'
        $c.EvolverEmail | Should -Be 'evolver@my-project.local'
    }
}
