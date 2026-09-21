#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Feedback.psm1') -Force
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/GitSignals.psm1') -Force
    $script:Daily = Join-Path $script:PluginRoot 'scripts/feedback/Collect-DailyFeedback.ps1'
    $script:Trailer = 'Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>'

    function Invoke-TestGit {
        param([string] $Path, [string[]] $GitArgs)
        $out = & git -C $Path -c user.name=owner -c user.email=owner@example.test -c commit.gpgsign=false -c core.autocrlf=false @GitArgs 2>&1
        if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $out" }
        $out
    }

    function New-Commit {
        param([string] $Path, [string] $Message)
        Invoke-TestGit -Path $Path -GitArgs @('add', '-A') | Out-Null
        Invoke-TestGit -Path $Path -GitArgs @('commit', '-q', '-m', $Message) | Out-Null
        (Invoke-TestGit -Path $Path -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1
    }

    function New-TestRepo {
        <#
            Builds a repository with this history (oldest first):
              1 owner : a.txt (4 lines)
              2 agent : b.txt (4 lines)                          [trailer]
              3 owner : replaces b.txt lines 2-3     "fix(b): correct names #agent-bad: wrong names"
              4 agent : c.txt (2 lines)                          [trailer]
              5 owner : git revert of 4                          -> code-revert
              6 owner : d.txt                                     "gen(1): tighten refit skill"
              7 owner : git revert of 6                          -> generation-revert
              8 owner : e.txt                                     "docs: notes #agent-good"
        #>
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $path -Force | Out-Null
        Invoke-TestGit -Path $path -GitArgs @('init', '-q', '-b', 'dev') | Out-Null

        $shas = @{}
        Set-Content -Path (Join-Path $path 'a.txt') -Value "owner 1`nowner 2`nowner 3`nowner 4" -NoNewline
        $shas.owner1 = New-Commit -Path $path -Message 'chore: initial'

        Set-Content -Path (Join-Path $path 'b.txt') -Value "agent line 1`nagent line 2`nagent line 3`nagent line 4" -NoNewline
        $shas.agent2 = New-Commit -Path $path -Message "feat(b): add b`n`n$script:Trailer"

        Set-Content -Path (Join-Path $path 'b.txt') -Value "agent line 1`nowner fixed 2`nowner fixed 3`nagent line 4" -NoNewline
        $shas.owner3 = New-Commit -Path $path -Message 'fix(b): correct names #agent-bad: wrong names'

        Set-Content -Path (Join-Path $path 'c.txt') -Value "agent c1`nagent c2" -NoNewline
        $shas.agent4 = New-Commit -Path $path -Message "feat(c): add c`n`n$script:Trailer"

        Invoke-TestGit -Path $path -GitArgs @('revert', '--no-edit', $shas.agent4) | Out-Null
        $shas.owner5 = (Invoke-TestGit -Path $path -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1

        Set-Content -Path (Join-Path $path 'd.txt') -Value 'genome change' -NoNewline
        $shas.gen6 = New-Commit -Path $path -Message 'gen(1): tighten refit skill'

        Invoke-TestGit -Path $path -GitArgs @('revert', '--no-edit', $shas.gen6) | Out-Null
        $shas.owner7 = (Invoke-TestGit -Path $path -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1

        Set-Content -Path (Join-Path $path 'e.txt') -Value 'notes' -NoNewline
        $shas.owner8 = New-Commit -Path $path -Message 'docs: notes #agent-good'

        [pscustomobject]@{ Path = $path; Shas = $shas }
    }

    function Get-Records {
        param([string] $Root)
        $dir = Join-Path $Root 'evolution\feedback'
        if (-not (Test-Path $dir)) { return @() }
        @(Get-ChildItem $dir -Filter '*.jsonl' | Get-Content | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'GitSignals' {
    BeforeAll {
        $script:Repo = New-TestRepo
    }

    It 'GetAgentCommits_TrailerPresent_ReturnsOnlyAgentCommits' {
        $agents = @(Get-AgentCommits -RepoPath $script:Repo.Path -SinceDays 7)

        ($agents | ForEach-Object Sha) | Sort-Object | Should -Be (@($script:Repo.Shas.agent2, $script:Repo.Shas.agent4) | Sort-Object)
    }

    It 'GetCodeCorrections_OwnerEditsAgentLine_RecordsVerbatimDiffAndAgentRef' {
        $signals = @(Get-CodeCorrections -RepoPath $script:Repo.Path -SinceDays 7)

        $correction = @($signals | Where-Object Signal -EQ 'code-correction')
        $correction.Count | Should -Be 1
        $correction[0].Ref | Should -Be $script:Repo.Shas.agent2
        $correction[0].Value | Should -Match '-agent line 2'
        $correction[0].Value | Should -Match '\+owner fixed 2'
        $correction[0].Extra.owner_commit | Should -Be $script:Repo.Shas.owner3
        $correction[0].Extra.file | Should -Be 'b.txt'
    }

    It 'GetCodeCorrections_FullRevert_RecordsCodeRevert' {
        $signals = @(Get-CodeCorrections -RepoPath $script:Repo.Path -SinceDays 7)

        $revert = @($signals | Where-Object Signal -EQ 'code-revert')
        $revert.Count | Should -Be 1
        $revert[0].Ref | Should -Be $script:Repo.Shas.agent4
        $revert[0].Extra.owner_commit | Should -Be $script:Repo.Shas.owner5
        $revert[0].Extra.weight | Should -Be 2
    }

    It 'GetBugAttributions_FixCommitTouchingAgentLines_RecordsAgentRef' {
        $signals = @(Get-BugAttributions -RepoPath $script:Repo.Path -SinceDays 7)

        $signals.Count | Should -Be 1
        $signals[0].Signal | Should -Be 'bug-attribution'
        $signals[0].Ref | Should -Be $script:Repo.Shas.agent2
        $signals[0].Extra.owner_commit | Should -Be $script:Repo.Shas.owner3
    }

    It 'GetCommitMarkers_AgentBadWithReason_RecordsReason' {
        $signals = @(Get-CommitMarkers -RepoPath $script:Repo.Path -SinceDays 7)

        $bad = @($signals | Where-Object { $_.Value -eq 'bad' })
        $bad.Count | Should -Be 1
        $bad[0].Signal | Should -Be 'commit-marker'
        $bad[0].Reason | Should -Be 'wrong names'
        $bad[0].Ref | Should -Be $script:Repo.Shas.owner3
        $good = @($signals | Where-Object { $_.Value -eq 'good' })
        $good[0].Ref | Should -Be $script:Repo.Shas.owner8
    }

    It 'GetDiffSurvival_HalfLinesReplaced_ReturnsPointFive' {
        $signals = @(Get-DiffSurvival -RepoPath $script:Repo.Path -MinAgeDays 0)

        $b = @($signals | Where-Object Ref -EQ $script:Repo.Shas.agent2)
        $b.Count | Should -Be 1
        $b[0].Signal | Should -Be 'diff-survival'
        [double] $b[0].Value | Should -Be 0.5
        $b[0].Extra.added | Should -Be 4
        $b[0].Extra.surviving | Should -Be 2
        $c = @($signals | Where-Object Ref -EQ $script:Repo.Shas.agent4)
        [double] $c[0].Value | Should -Be 0
    }

    It 'GetGenerationReverts_RevertOfGenCommit_RecordsGeneration' {
        $signals = @(Get-GenerationReverts -RepoPath $script:Repo.Path -SinceDays 7)

        $signals.Count | Should -Be 1
        $signals[0].Signal | Should -Be 'generation-revert'
        $signals[0].Value | Should -Be 'gen/1'
        $signals[0].Ref | Should -Be $script:Repo.Shas.owner7
    }
}

Describe 'Invoke-GitSignals and daily collection' {
    BeforeEach {
        $script:Repo = New-TestRepo
        $script:Root = $script:Repo.Path
    }

    It 'InvokeGitSignals_FirstRun_WritesAllSignalsAndSecondRunWritesNone' {
        $first = Invoke-GitSignals -RepoRoot $script:Root -RepoPath $script:Repo.Path -SinceDays 7 -MinSurvivalAgeDays 0
        $countAfterFirst = @(Get-Records -Root $script:Root).Count

        $second = Invoke-GitSignals -RepoRoot $script:Root -RepoPath $script:Repo.Path -SinceDays 7 -MinSurvivalAgeDays 0

        $first | Should -BeGreaterThan 0
        $second | Should -Be 0
        @(Get-Records -Root $script:Root).Count | Should -Be $countAfterFirst
        $signals = @(Get-Records -Root $script:Root | ForEach-Object signal | Sort-Object -Unique)
        $signals | Should -Contain 'code-correction'
        $signals | Should -Contain 'code-revert'
        $signals | Should -Contain 'bug-attribution'
        $signals | Should -Contain 'commit-marker'
        $signals | Should -Contain 'diff-survival'
        $signals | Should -Contain 'generation-revert'
    }

    It 'InvokeGitSignals_NotAGitRepo_ReturnsZeroWithoutThrowing' {
        $plain = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $plain -Force | Out-Null

        { Invoke-GitSignals -RepoRoot $plain -RepoPath $plain } | Should -Not -Throw
        Invoke-GitSignals -RepoRoot $plain -RepoPath $plain | Should -Be 0
    }

    It 'CollectDaily_RunsGitSignals_WritesCommitMarkerRecord' {
        New-Item -ItemType Directory -Path (Join-Path $script:Root 'evolution\evolver') -Force | Out-Null
        Copy-Item (Join-Path $script:PluginRoot 'scripts/evolver/rubric.md') (Join-Path $script:Root 'evolution\evolver\rubric.md')
        $emptyTranscripts = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $emptyTranscripts -Force | Out-Null

        & $script:Daily -RepoRoot $script:Root -TranscriptDir $emptyTranscripts -ClaudeCommand (Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1') -MinSurvivalAgeDays 0 2>&1 | Out-Null

        @(Get-Records -Root $script:Root | Where-Object signal -EQ 'commit-marker').Count | Should -Be 2
    }
}
