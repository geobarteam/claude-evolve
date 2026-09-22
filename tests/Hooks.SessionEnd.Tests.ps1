#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:Hook = Join-Path $script:PluginRoot 'hooks/SessionEnd.ps1'
    $script:Daily = Join-Path $script:PluginRoot 'scripts/feedback/Collect-DailyFeedback.ps1'
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/transcript-corrections.jsonl'
    $script:Shim = Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1'

    function New-FakeRepo {
        param([string] $Root)
        New-Item -ItemType Directory -Path (Join-Path $Root 'evolution/journal') -Force | Out-Null
        Set-Content -Path (Join-Path $Root 'MEMORY.md') -Value "# MEMORY`n`n## Beliefs`n`n- **Belief A** (since: gen/0). text"
        Copy-Item $script:Fixture (Join-Path $Root 'transcript.jsonl')
    }

    function New-Journal {
        param([string] $Root, [string] $SessionId, [string] $Outcome)
        $body = "<!-- session: $SessionId -->`n## Task`nx`n"
        if ($null -ne $Outcome) { $body += "## Outcome`n$Outcome`n" }
        Set-Content -Path (Join-Path $Root 'evolution/journal/2026-09-21-1200.md') -Value $body
    }

    function Invoke-Hook {
        param([string] $Root, [hashtable] $HookInput)
        $json = $HookInput | ConvertTo-Json -Compress
        $out = & $script:Hook -InputJson $json -RepoRoot $Root -ClaudeCommand $script:Shim 2>&1 | Out-String
        [pscustomobject]@{ Output = $out.Trim(); ExitCode = $LASTEXITCODE }
    }

    function Get-Records {
        param([string] $Root)
        $dir = Join-Path $Root 'evolution/feedback'
        if (-not (Test-Path $dir)) { return @() }
        @(Get-ChildItem $dir -Filter '*.jsonl' | Get-Content | ForEach-Object { $_ | ConvertFrom-Json })
    }

    function Get-BaseInput {
        param([string] $Root)
        @{
            session_id      = 'sess-corrections'
            hook_event_name = 'SessionEnd'
            exit_reason     = 'other'
            transcript_path = (Join-Path $Root 'transcript.jsonl')
            cwd             = $Root
        }
    }
}

Describe 'SessionEnd hook' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-FakeRepo -Root $script:Root
    }

    It 'SessionEnd_UnprocessedSession_WritesCorrectionFrustrationPraiseQuestionRecords' {
        New-Journal -Root $script:Root -SessionId 'sess-corrections' -Outcome 'done — endpoint added'

        $r = Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root)

        $r.ExitCode | Should -Be 0
        $records = Get-Records -Root $script:Root
        ($records | ForEach-Object signal) | Should -Contain 'correction'
        ($records | ForEach-Object signal) | Should -Contain 'frustration'
        ($records | ForEach-Object signal) | Should -Contain 'praise'
        ($records | ForEach-Object signal) | Should -Contain 'question'
        ($records | ForEach-Object signal) | Should -Not -Contain 'none'
        ($records | ForEach-Object signal) | Should -Not -Contain 'abandonment'
        $correction = $records | Where-Object signal -EQ 'correction'
        $correction.value | Should -Be 'no, use the Refit client instead of HttpClient'
        $correction.agent_action | Should -Match 'HttpClient call'
        $correction.ref | Should -Match '2026-09-21-1200\.md'
        $correction.session_id | Should -Be 'sess-corrections'
        Test-Path (Join-Path $script:Root 'evolution\.state\processed\sess-corrections') | Should -BeTrue
    }

    It 'SessionEnd_JournalWithoutOutcome_WritesAbandonmentRecord' {
        New-Journal -Root $script:Root -SessionId 'sess-corrections' -Outcome $null

        Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root) | Out-Null

        $abandon = @(Get-Records -Root $script:Root | Where-Object signal -EQ 'abandonment')
        $abandon.Count | Should -Be 1
        $abandon[0].value | Should -Match "You're welcome"
    }

    It 'SessionEnd_NoJournalAtAll_WritesAbandonmentRecord' {
        Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root) | Out-Null

        @(Get-Records -Root $script:Root | Where-Object signal -EQ 'abandonment').Count | Should -Be 1
    }

    It 'SessionEnd_AlreadyProcessed_WritesNothing' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'evolution\.state\processed') -Force | Out-Null
        Set-Content -Path (Join-Path $script:Root 'evolution\.state\processed\sess-corrections') -Value 'x'

        $r = Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root)

        $r.ExitCode | Should -Be 0
        @(Get-Records -Root $script:Root).Count | Should -Be 0
    }

    It 'SessionEnd_InsideClassifierChild_WritesNothing' {
        New-Journal -Root $script:Root -SessionId 'sess-corrections' -Outcome 'done — x'
        $env:EVOLUTION_CLASSIFIER = '1'
        try {
            $r = Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root)
        }
        finally {
            Remove-Item Env:\EVOLUTION_CLASSIFIER -ErrorAction SilentlyContinue
        }

        $r.ExitCode | Should -Be 0
        @(Get-Records -Root $script:Root).Count | Should -Be 0
        Test-Path (Join-Path $script:Root 'evolution\.state\processed\sess-corrections') | Should -BeFalse
    }

    It 'SessionEnd_ClassifierFails_ExitsZeroAndLogsError' {
        New-Journal -Root $script:Root -SessionId 'sess-corrections' -Outcome 'done — x'
        $hookInput = Get-BaseInput -Root $script:Root
        $json = $hookInput | ConvertTo-Json -Compress

        & $script:Hook -InputJson $json -RepoRoot $script:Root -ClaudeCommand (Join-Path $TestDrive 'does-not-exist.ps1') 2>&1 | Out-Null

        $LASTEXITCODE | Should -Be 0
        Test-Path (Join-Path $script:Root 'evolution\.state\hook-errors.log') | Should -BeTrue
    }
}

Describe 'Collect-DailyFeedback' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-FakeRepo -Root $script:Root
        $script:TranscriptDir = Join-Path $script:Root 'transcripts'
        New-Item -ItemType Directory -Path $script:TranscriptDir -Force | Out-Null
        Copy-Item $script:Fixture (Join-Path $script:TranscriptDir 'sess-corrections.jsonl')
        Copy-Item (Join-Path $PSScriptRoot 'fixtures/transcript-basic.jsonl') (Join-Path $script:TranscriptDir 'sess-basic.jsonl')
        $old = Join-Path $script:TranscriptDir 'sess-old.jsonl'
        Copy-Item $script:Fixture $old
        (Get-Item $old).LastWriteTimeUtc = [datetime]::UtcNow.AddDays(-10)
    }

    It 'CollectDaily_SkipsProcessedAndProcessesNew' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'evolution\.state\processed') -Force | Out-Null
        Set-Content -Path (Join-Path $script:Root 'evolution\.state\processed\sess-basic') -Value 'x'

        & $script:Daily -RepoRoot $script:Root -TranscriptDir $script:TranscriptDir -ClaudeCommand $script:Shim 2>&1 | Out-Null

        $records = Get-Records -Root $script:Root
        ($records | ForEach-Object session_id | Sort-Object -Unique) | Should -Be @('sess-corrections')
        Test-Path (Join-Path $script:Root 'evolution\.state\processed\sess-corrections') | Should -BeTrue
        Test-Path (Join-Path $script:Root 'evolution\.state\processed\sess-old') | Should -BeFalse -Because 'older than the look-back window'
    }

    It 'CollectDaily_SecondRun_WritesNoDuplicateRecords' {
        & $script:Daily -RepoRoot $script:Root -TranscriptDir $script:TranscriptDir -ClaudeCommand $script:Shim 2>&1 | Out-Null
        $first = @(Get-Records -Root $script:Root).Count

        & $script:Daily -RepoRoot $script:Root -TranscriptDir $script:TranscriptDir -ClaudeCommand $script:Shim 2>&1 | Out-Null

        $first | Should -BeGreaterThan 0
        @(Get-Records -Root $script:Root).Count | Should -Be $first
    }
}
