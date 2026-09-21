#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:Hook = Join-Path $script:PluginRoot 'hooks/Stop.ps1'
    $script:Fixture = Join-Path $PSScriptRoot 'fixtures/transcript-basic.jsonl'
    # Last owner prompt in the fixture is at 2026-09-21T09:04:00Z.
    $script:LastUserUtc = [datetime]::new(2026, 9, 21, 9, 4, 0, [System.DateTimeKind]::Utc)

    function New-FakeRepo {
        param([string] $Root)
        New-Item -ItemType Directory -Path (Join-Path $Root 'evolution\journal') -Force | Out-Null
        New-Item -ItemType Directory -Path (Join-Path $Root 'evolution\.state') -Force | Out-Null
        Set-Content -Path (Join-Path $Root 'evolution\journal\TEMPLATE.md') -Value '<!-- session: {{session_id}} -->'
        Copy-Item $script:Fixture (Join-Path $Root 'transcript.jsonl')
    }

    function New-Journal {
        param([string] $Root, [string] $SessionId, [datetime] $LastWriteUtc)
        $path = Join-Path $Root "evolution\journal\2026-09-21-1100.md"
        Set-Content -Path $path -Value "<!-- session: $SessionId -->`n## Task`nx`n## Outcome`ndone — x"
        (Get-Item $path).LastWriteTimeUtc = $LastWriteUtc
        $path
    }

    function Invoke-Hook {
        param([string] $Root, [hashtable] $HookInput)
        $json = $HookInput | ConvertTo-Json -Compress
        $out = & $script:Hook -InputJson $json -RepoRoot $Root 2>&1 | Out-String
        [pscustomobject]@{ Output = $out.Trim(); ExitCode = $LASTEXITCODE }
    }

    function Get-BaseInput {
        param([string] $Root, [bool] $Active = $false)
        @{
            session_id       = 'sess-basic'
            hook_event_name  = 'Stop'
            stop_hook_active = $Active
            transcript_path  = (Join-Path $Root 'transcript.jsonl')
            cwd              = $Root
        }
    }
}

Describe 'Stop hook' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-FakeRepo -Root $script:Root
    }

    It 'Stop_StopHookActive_ExitsZeroSilently' {
        $r = Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root -Active $true)

        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeNullOrEmpty
    }

    It 'Stop_NoJournalForSession_EmitsBlockDecisionNamingTemplate' {
        $r = Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root)

        $r.ExitCode | Should -Be 0
        $decision = $r.Output | ConvertFrom-Json
        $decision.decision | Should -Be 'block'
        $decision.reason | Should -Match 'evolution/journal/TEMPLATE.md'
        $decision.reason | Should -Match 'evolution/journal/\d{4}-\d{2}-\d{2}-\d{4}\.md'
        $decision.reason | Should -Match '<!-- session: sess-basic -->'
    }

    It 'Stop_JournalOlderThanLastUserTurn_EmitsBlock' {
        New-Journal -Root $script:Root -SessionId 'sess-basic' -LastWriteUtc $script:LastUserUtc.AddMinutes(-5) | Out-Null

        $r = Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root)

        ($r.Output | ConvertFrom-Json).decision | Should -Be 'block'
        ($r.Output | ConvertFrom-Json).reason | Should -Match '2026-09-21-1100\.md'
    }

    It 'Stop_CurrentJournal_NoOutput' {
        New-Journal -Root $script:Root -SessionId 'sess-basic' -LastWriteUtc $script:LastUserUtc.AddMinutes(5) | Out-Null

        $r = Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root)

        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeNullOrEmpty
    }

    It 'Stop_JournalForOtherSessionOnly_EmitsBlock' {
        New-Journal -Root $script:Root -SessionId 'someone-else' -LastWriteUtc $script:LastUserUtc.AddMinutes(5) | Out-Null

        $r = Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root)

        ($r.Output | ConvertFrom-Json).decision | Should -Be 'block'
    }

    It 'Stop_InsideClassifierChild_NeverBlocks' {
        $env:EVOLUTION_CLASSIFIER = '1'
        try {
            $r = Invoke-Hook -Root $script:Root -HookInput (Get-BaseInput -Root $script:Root)
        }
        finally {
            Remove-Item Env:\EVOLUTION_CLASSIFIER -ErrorAction SilentlyContinue
        }

        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeNullOrEmpty
    }

    It 'Stop_TranscriptMissing_RequiresJournalExistenceOnly' {
        $hookInput = Get-BaseInput -Root $script:Root
        $hookInput.transcript_path = Join-Path $script:Root 'missing.jsonl'
        New-Journal -Root $script:Root -SessionId 'sess-basic' -LastWriteUtc ([datetime]::UtcNow.AddDays(-1)) | Out-Null

        $r = Invoke-Hook -Root $script:Root -HookInput $hookInput

        $r.Output | Should -BeNullOrEmpty
    }
}
