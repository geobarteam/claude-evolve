#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Contract.psm1') -Force
    $script:Evolver = Join-Path $script:PluginRoot 'scripts/evolver/Invoke-Evolver.ps1'
    $script:Shim = Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1'

    function Set-RepoFile {
        param([string] $Root, [string] $Rel, [string] $Content)
        $dest = Join-Path $Root $Rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($dest, $Content, [System.Text.UTF8Encoding]::new($false))
    }

    function Add-GoodNote {
        param([string] $Root)
        Set-RepoFile -Root $Root -Rel 'evolution/generations/gen-1.md' -Content (New-Note -Changes @(
                @{ Title = 'Add belief'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md' }))
        Set-RepoFile -Root $Root -Rel 'MEMORY.md' -Content ([System.IO.File]::ReadAllText((Join-Path $Root 'MEMORY.md')) + "`n- **Evolved belief** (since: gen/1). text`n")
    }
}

Describe 'Test-PathInsideProject' {
    It 'TestPathInsideProject_RelativePathWithoutParentSegment_True' {
        Test-PathInsideProject -Path 'MEMORY.md' | Should -BeTrue
        Test-PathInsideProject -Path '.claude/skills/refit/SKILL.md' | Should -BeTrue
        Test-PathInsideProject -Path 'a/..b/c.md' | Should -BeTrue -Because 'only a whole ".." segment escapes'
    }

    It 'TestPathInsideProject_ParentSegment_False' {
        Test-PathInsideProject -Path '../escape.md' | Should -BeFalse
        Test-PathInsideProject -Path ('..' + [char] 92 + 'escape.md') | Should -BeFalse -Because 'a Windows-style parent segment escapes too'
        Test-PathInsideProject -Path 'a/../../escape.md' | Should -BeFalse
        Test-PathInsideProject -Path 'a/..' | Should -BeFalse
    }

    It 'TestPathInsideProject_RootedPath_False' {
        Test-PathInsideProject -Path 'C:\Windows\x.md' | Should -BeFalse
        Test-PathInsideProject -Path '/etc/passwd' | Should -BeFalse
    }
}

Describe 'Contract boundaries' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-ContractRepo -Root $script:Root | Out-Null
    }

    It 'Contract_EvolveJsonChanged_FailsAsProtectedPath' {
        Add-GoodNote -Root $script:Root
        Set-RepoFile -Root $script:Root -Rel 'evolution/evolve.json' -Content '{ "maxEdits": 9 }'

        @(Test-GenomeContract -RepoPath $script:Root -Base 'gen/0' -Worktree $script:Root) | Should -Contain 'protected path changed: evolution/evolve.json'
    }

    It 'Contract_ManifestWithoutEvolveJson_StillProtectsItAtRuntime' {
        $manifest = (Get-Content (Join-Path $script:Root 'evolution/evolver/protected-paths.txt') -Raw) -replace '(?m)^evolution/evolve\.json\r?\n', ''
        (($manifest -split "`n" | Where-Object { $_ -notmatch '^\s*#' }) -join "`n") | Should -Not -Match 'evolve\.json' -Because 'only the header comment may still mention it'
        Set-RepoFile -Root $script:Root -Rel 'evolution/evolver/protected-paths.txt' -Content $manifest
        Invoke-RepoGit -Path $script:Root -GitArgs @('add', '-A') | Out-Null
        Invoke-RepoGit -Path $script:Root -GitArgs @('commit', '-q', '-m', 'chore: manifest without evolve.json') | Out-Null
        Add-GoodNote -Root $script:Root
        Set-RepoFile -Root $script:Root -Rel 'evolution/evolve.json' -Content '{ "maxEdits": 9 }'

        @(Test-GenomeContract -RepoPath $script:Root -Base 'HEAD' -Worktree $script:Root) | Should -Contain 'protected path changed: evolution/evolve.json'
    }

    It 'Contract_PluginRootInsideProject_FileUnderItFailsAsProtectedPath' {
        Add-GoodNote -Root $script:Root
        Set-RepoFile -Root $script:Root -Rel 'tools/evolve-plugin/scripts/lib/Contract.psm1' -Content '# tampered'

        $violations = @(Test-GenomeContract -RepoPath $script:Root -Base 'gen/0' -Worktree $script:Root -PluginRoot (Join-Path $script:Root 'tools/evolve-plugin'))

        $violations | Should -Contain 'protected path changed: tools/evolve-plugin/scripts/lib/Contract.psm1'
    }

    It 'Contract_PluginRootOutsideProject_AddsNothingAndPasses' {
        Add-GoodNote -Root $script:Root

        @(Test-GenomeContract -RepoPath $script:Root -Base 'gen/0' -Worktree $script:Root -PluginRoot $script:PluginRoot) | Should -BeNullOrEmpty
    }

    It 'Checker_PluginRootParameter_PassedThrough' {
        Add-GoodNote -Root $script:Root
        Set-RepoFile -Root $script:Root -Rel 'tools/evolve-plugin/hooks/Stop.ps1' -Content 'exit 1'

        $out = & (Join-Path $script:PluginRoot 'scripts/evolver/Test-GenomeContract.ps1') -RepoPath $script:Root -Base 'gen/0' -Worktree $script:Root -PluginRoot (Join-Path $script:Root 'tools/evolve-plugin') 2>&1 | Out-String

        $LASTEXITCODE | Should -Be 1
        $out | Should -Match 'VIOLATION: protected path changed: tools/evolve-plugin/hooks/Stop\.ps1'
    }
}

Describe 'Evolver evidence bundle' {
    It 'Evolver_EvidenceBundle_ListsEvolveJsonAndPluginRootAsProtected' {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-ContractRepo -Root $root | Out-Null
        $memory = [System.IO.File]::ReadAllText((Join-Path $root 'MEMORY.md')) + "`n- **Evolved belief** (since: gen/1). text`n"
        $map = [ordered]@{
            'MEMORY.md'                       = $memory
            'evolution/generations/gen-1.md' = (New-Note -Summary 'add belief' -Changes @(@{ Title = 'Add belief'; Files = @('MEMORY.md'); Why = 'evolution/journal/2026-09-20-0900.md' }))
        }
        $mapPath = Join-Path $TestDrive ("proposal-" + [guid]::NewGuid().ToString('N') + '.json')
        $map | ConvertTo-Json -Depth 3 | Set-Content -Path $mapPath -Encoding utf8
        $env:CLAUDE_SHIM_PROPOSAL = $mapPath
        try {
            & $script:Evolver -RepoRoot $root -ClaudeCommand $script:Shim -Force -SkipRegression 2>&1 | Out-Null
        }
        finally { Remove-Item Env:\CLAUDE_SHIM_PROPOSAL -ErrorAction SilentlyContinue }

        $evidence = Get-ChildItem (Join-Path $root 'evolution/.state/evolver') -Filter '*-evidence.md' | Sort-Object Name | Select-Object -Last 1
        $evidence | Should -Not -BeNullOrEmpty
        $text = Get-Content $evidence.FullName -Raw
        $text | Should -Match 'evolution/evolve\.json'
        $text | Should -Match ([regex]::Escape($script:PluginRoot))
    }
}
