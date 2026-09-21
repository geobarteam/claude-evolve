#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Contract.psm1') -Force
    $script:Evolver = Join-Path $script:PluginRoot 'scripts/evolver/Invoke-Evolver.ps1'
    $script:Show = Join-Path $script:PluginRoot 'scripts/evolver/Show-Generation.ps1'
    $script:Revert = Join-Path $script:PluginRoot 'scripts/evolver/Revert-Generation.ps1'

    function New-RepoWithGen1 {
        param([string] $Root)
        New-ContractRepo -Root $Root | Out-Null
        $memory = [System.IO.File]::ReadAllText((Join-Path $Root 'MEMORY.md')) + "`n- **Evolved belief** (since: gen/1). text`n"
        $proposal = New-Proposal -Dir (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) -Files @{ 'MEMORY.md' = $memory } -Note (New-Note -Summary 'add evolved belief' -Changes @(
                @{ Title = 'Add evolved belief'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md' }))
        & $script:Evolver -RepoRoot $Root -ProposalDir $proposal -SkipRegression 2>&1 | Out-Null
    }
}

Describe 'Add-LineageRow' {
    It 'AddLineageRow_Reverted_AppendsWellFormedRow' {
        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString('N') + '.md')
        Set-Content -Path $path -Value "| Generation | Date | Score | Status | Summary |`n| --- | --- | --- | --- | --- |`n| gen/0 | 2026-09-21 | — | settled | baseline |"

        Add-LineageRow -Path $path -Generation 'gen/1' -Score '—' -Status 'reverted' -Summary 'reverted by the owner'

        (Get-Content $path)[-1] | Should -Match '^\| gen/1 \| \d{4}-\d{2}-\d{2} \| — \| reverted \| reverted by the owner \|$'
        (Get-LineageState -Path $path).LastScore | Should -Be '—' -Because 'a reverted row carries no score'
    }
}

Describe 'Show-Generation' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-RepoWithGen1 -Root $script:Root
    }

    It 'ShowGeneration_PrintsLineageAndLatestNote' {
        $out = & $script:Show -RepoRoot $script:Root 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        $out | Should -Match '\| gen/1 \|.*\| provisional \|'
        $out | Should -Match '# gen/1 — add evolved belief'
        $out | Should -Match 'Change 1: Add evolved belief'
        $out | Should -Match 'git revert gen/1'
    }

    It 'ShowGeneration_SpecificGeneration_PrintsThatNote' {
        $out = & $script:Show -RepoRoot $script:Root -Generation 0 2>&1 | Out-String

        $out | Should -Match 'gen/0'
        $out | Should -Not -Match 'Change 1: Add evolved belief'
    }
}

Describe 'Revert-Generation' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-RepoWithGen1 -Root $script:Root
    }

    It 'RevertGeneration_ExistingTag_RevertsCommitAndAppendsRevertedRow' {
        $out = & $script:Revert -RepoRoot $script:Root -Generation 1 -Confirm:$false 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 0
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('log', '-1', '--format=%s')) | Select-Object -First 1) | Should -Match '^Revert "gen\(1\): add evolved belief"'
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('log', '-1', '--format=%an')) | Select-Object -First 1) | Should -Not -Be 'evolver' -Because 'a revert is the owner''s act, made with the caller''s own git identity'
        Get-Content (Join-Path $script:Root 'MEMORY.md') -Raw | Should -Not -Match 'Evolved belief'
        (Get-Content (Join-Path $script:Root 'evolution/lineage.md'))[-1] | Should -Match '^\| gen/1 \| .* \| — \| reverted \|'
        (Invoke-RepoGit -Path $script:Root -GitArgs @('status', '--porcelain')) | Should -BeNullOrEmpty
        (Invoke-RepoGit -Path $script:Root -GitArgs @('tag', '-l', 'gen/1')) | Should -Contain 'gen/1' -Because 'history is kept; the tag still marks the generation'
        $out | Should -Match 'gen/1 reverted'
    }

    It 'RevertGeneration_UnknownGeneration_RefusesWithoutCommit' {
        $head = [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1)

        $out = & $script:Revert -RepoRoot $script:Root -Generation 7 -Confirm:$false 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'gen/7'
        [string] (@(Invoke-RepoGit -Path $script:Root -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1) | Should -Be $head
    }

    It 'RevertGeneration_DirtyLineage_Refuses' {
        Add-Content -Path (Join-Path $script:Root 'evolution/lineage.md') -Value '| — | 2026-09-22 | 1/2 | rejected | owner is mid-edit |'

        & $script:Revert -RepoRoot $script:Root -Generation 1 -Confirm:$false 2>&1 | Out-Null

        $LASTEXITCODE | Should -Be 1
        Get-Content (Join-Path $script:Root 'MEMORY.md') -Raw | Should -Match 'Evolved belief'
    }
}
