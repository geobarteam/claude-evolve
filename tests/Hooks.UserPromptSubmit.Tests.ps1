#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:Hook = Join-Path $script:PluginRoot 'hooks/UserPromptSubmit.ps1'

    function New-FakeRepo {
        param([string] $Root)
        New-Item -ItemType Directory -Path (Join-Path $Root 'evolution/journal') -Force | Out-Null
        Set-Content -Path (Join-Path $Root 'evolution/journal/2026-09-21-1300.md') -Value "<!-- session: sess-rate -->`n## Task`nx"
    }

    function Invoke-Hook {
        param([string] $Root, [string] $Prompt, [string] $SessionId = 'sess-rate')
        $json = @{ session_id = $SessionId; hook_event_name = 'UserPromptSubmit'; prompt = $Prompt; cwd = $Root } | ConvertTo-Json -Compress
        $out = & $script:Hook -InputJson $json -RepoRoot $Root 2>&1 | Out-String
        [pscustomobject]@{ Output = $out.Trim(); ExitCode = $LASTEXITCODE }
    }

    function Get-Records {
        param([string] $Root)
        $dir = Join-Path $Root 'evolution/feedback'
        if (-not (Test-Path $dir)) { return @() }
        @(Get-ChildItem $dir -Filter '*.jsonl' | Get-Content | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'UserPromptSubmit hook' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-FakeRepo -Root $script:Root
    }

    It 'UserPromptSubmit_PlusOnly_WritesPositiveRating' {
        $r = Invoke-Hook -Root $script:Root -Prompt '+'

        $r.ExitCode | Should -Be 0
        $r.Output | Should -Match 'Rating recorded'
        $records = @(Get-Records -Root $script:Root)
        $records.Count | Should -Be 1
        $records[0].signal | Should -Be 'rating'
        $records[0].value | Should -Be '+'
        $records[0].session_id | Should -Be 'sess-rate'
        $records[0].ref | Should -Match '2026-09-21-1300\.md'
        $records[0].PSObject.Properties.Name | Should -Not -Contain 'reason'
    }

    It 'UserPromptSubmit_MinusWithReason_WritesNegativeRatingWithReason' {
        $r = Invoke-Hook -Root $script:Root -Prompt '- too slow and too verbose'

        $records = @(Get-Records -Root $script:Root)
        $records.Count | Should -Be 1
        $records[0].value | Should -Be '-'
        $records[0].reason | Should -Be 'too slow and too verbose'
        $records[0].weight | Should -Be 2
    }

    It 'UserPromptSubmit_MinusOnly_WritesNegativeRatingWithoutReason' {
        Invoke-Hook -Root $script:Root -Prompt ' - ' | Out-Null

        $records = @(Get-Records -Root $script:Root)
        $records.Count | Should -Be 1
        $records[0].value | Should -Be '-'
        $records[0].PSObject.Properties.Name | Should -Not -Contain 'reason'
    }

    It 'UserPromptSubmit_OrdinaryPrompt_WritesNothing' {
        $r = Invoke-Hook -Root $script:Root -Prompt 'Add a doctor page'

        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeNullOrEmpty
        @(Get-Records -Root $script:Root).Count | Should -Be 0
    }

    It 'UserPromptSubmit_MinusOneDoctor_IsNotARating' {
        Invoke-Hook -Root $script:Root -Prompt '-1 doctor' | Out-Null

        @(Get-Records -Root $script:Root).Count | Should -Be 0
    }

    It 'UserPromptSubmit_PlusFollowedByText_IsNotARating' {
        Invoke-Hook -Root $script:Root -Prompt '+ Add doctor page' | Out-Null

        @(Get-Records -Root $script:Root).Count | Should -Be 0
    }

    It 'UserPromptSubmit_NoJournalYet_RefersToTranscript' {
        Remove-Item (Join-Path $script:Root 'evolution/journal/2026-09-21-1300.md')

        Invoke-Hook -Root $script:Root -Prompt '+' | Out-Null

        (Get-Records -Root $script:Root)[0].ref | Should -Be 'transcript:sess-rate'
    }

    It 'UserPromptSubmit_InsideClassifierChild_WritesNothing' {
        $env:EVOLUTION_CLASSIFIER = '1'
        try {
            Invoke-Hook -Root $script:Root -Prompt '+' | Out-Null
        }
        finally {
            Remove-Item Env:\EVOLUTION_CLASSIFIER -ErrorAction SilentlyContinue
        }

        @(Get-Records -Root $script:Root).Count | Should -Be 0
    }
}
