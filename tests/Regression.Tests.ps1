#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    Import-Module (Join-Path $script:PluginRoot 'scripts/lib/Regression.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'ContractRepo.psm1') -Force
    $script:Runner = Join-Path $script:PluginRoot 'scripts/regression/Invoke-Regression.ps1'
    $script:Shim = Join-Path $PSScriptRoot 'fixtures/claude-shim.ps1'
    $script:Root = Join-Path $TestDrive 'scaffold'
    New-ContractRepo -Root $script:Root | Out-Null
    $script:TasksDir = Join-Path $script:Root 'evolution/regression/tasks'
    $script:Tasks = @(Get-RegressionTasks -TasksDir $script:TasksDir)

    function New-AnswerFile {
        # Canned shim answers keyed on each task's prompt; -Omit leaves tasks unanswered so they fail.
        param([string[]] $Omit = @())
        $answers = [ordered]@{}
        foreach ($task in $script:Tasks) {
            if ($task.Id -in $Omit) { continue }
            $answers[$task.Prompt] = 'Answer: ' + ($task.Expect -join ', ')
        }
        $path = Join-Path $TestDrive ("answers-" + [guid]::NewGuid().ToString('N') + '.json')
        $answers | ConvertTo-Json -Depth 3 | Set-Content -Path $path -Encoding utf8
        $path
    }

    function Invoke-Runner {
        param([string] $AnswerFile, [string] $Root = $script:Root)
        $env:CLAUDE_SHIM_ANSWERS = $AnswerFile
        try {
            $out = & $script:Runner -RepoRoot $Root -Ref HEAD -ClaudeCommand $script:Shim 2>&1 | Out-String
        }
        finally {
            Remove-Item Env:\CLAUDE_SHIM_ANSWERS -ErrorAction SilentlyContinue
        }
        $out
    }

    function Get-LatestResult {
        param([string] $Root = $script:Root)
        $dir = Join-Path $Root 'evolution/.state/regression'
        Get-ChildItem $dir -Filter '*.json' | Sort-Object Name | Select-Object -Last 1 | Get-Content -Raw | ConvertFrom-Json
    }
}

Describe 'Task files' {
    It 'Regression_TaskFilesOfScaffold_HaveIdPromptCheckExpect' {
        $script:Tasks.Count | Should -Be 2
        ($script:Tasks | ForEach-Object Id) | Should -Be @('T01', 'T02')
        foreach ($task in $script:Tasks) {
            $task.Prompt | Should -Not -BeNullOrEmpty -Because "$($task.Id) needs a prompt"
            $task.Check | Should -BeIn @('answer-contains', 'script') -Because "$($task.Id) needs a known check"
            $task.Expect.Count | Should -BeGreaterThan 0 -Because "$($task.Id) needs an expectation"
        }
    }

    It 'TestRegressionAnswer_ContainsAndNotContains_Evaluated' {
        $task = $script:Tasks | Where-Object Id -EQ 'T01'

        (Test-RegressionAnswer -Task $task -Answer 'The word is alpha.' -Worktree $TestDrive).Passed | Should -BeTrue
        (Test-RegressionAnswer -Task $task -Answer 'no idea' -Worktree $TestDrive).Passed | Should -BeFalse
        (Test-RegressionAnswer -Task $task -Answer 'no idea' -Worktree $TestDrive).Detail | Should -Match "missing 'alpha'"
    }
}

Describe 'Invoke-Regression' {
    It 'InvokeRegression_ShimAnswersAllTasks_ScoresTwoOfTwo' {
        $out = Invoke-Runner -AnswerFile (New-AnswerFile)

        $out | Should -Match 'Score: 2/2'
        $result = Get-LatestResult
        $result.score | Should -Be 2
        $result.total | Should -Be 2
        $result.sha | Should -Match '^[0-9a-f]{40}$'
    }

    It 'InvokeRegression_ShimFailsOne_ScoresOneOfTwoAndListsFailingId' {
        $out = Invoke-Runner -AnswerFile (New-AnswerFile -Omit 'T02')

        $out | Should -Match 'Score: 1/2'
        $out | Should -Match 'Failed: T02'
        (Get-LatestResult).failed | Should -Be @('T02')
    }

    It 'InvokeRegression_ScriptCheck_RunsSiblingCheckScriptInsideWorktree' {
        $root = Join-Path $TestDrive 'scaffold-script'
        New-ContractRepo -Root $root | Out-Null
        $tasks = Join-Path $root 'evolution/regression/tasks'
        Set-Content -Path (Join-Path $tasks 'T03.md') -Value "---`nid: T03`ncheck: script`nscript: T03.check.ps1`nexpect: edited`nsource: test`n---`nAdd the evolved marker to src/x.cs"
        Set-Content -Path (Join-Path $tasks 'T03.check.ps1') -Value @'
param([Parameter(Mandatory)] [string] $Worktree)
$content = Get-Content -LiteralPath (Join-Path $Worktree 'src/x.cs') -Raw
if ($content -notmatch 'evolved') { Write-Output 'marker missing'; exit 1 }
Write-Output 'marker present in the worktree'
exit 0
'@
        $answers = [ordered]@{ 'Say alpha' = 'Answer: alpha'; 'Say beta' = 'Answer: beta'; 'Add the evolved marker' = 'EDIT:src/x.cs| /* evolved */ ' }
        $answerFile = Join-Path $TestDrive 'answers-script.json'
        $answers | ConvertTo-Json -Depth 3 | Set-Content -Path $answerFile -Encoding utf8

        $out = Invoke-Runner -AnswerFile $answerFile -Root $root

        $out | Should -Match 'Score: 3/3'
        $out | Should -Match 'marker present in the worktree'
        Get-Content (Join-Path $root 'src/x.cs') -Raw | Should -Not -Match 'evolved' -Because 'the edit happened in the worktree, not in the owner checkout'
    }

    It 'InvokeRegression_Always_RemovesWorktree' {
        Invoke-Runner -AnswerFile (New-AnswerFile) | Out-Null

        $worktrees = @(& git -C $script:Root worktree list)
        ($worktrees | Where-Object { $_ -match 'evolve-regression-' }).Count | Should -Be 0
        @(Get-ChildItem ([System.IO.Path]::GetTempPath()) -Directory -Filter 'evolve-regression-*').Count | Should -Be 0
    }

    It 'InvokeRegression_RunAsScriptFile_ScoresLikeInProcess' {
        # `pwsh -File` runs the script at global scope, where automatic variables such as $Error are read-only.
        $env:CLAUDE_SHIM_ANSWERS = New-AnswerFile
        try {
            $out = & pwsh -NoProfile -File $script:Runner -RepoRoot $script:Root -Ref HEAD -ClaudeCommand $script:Shim 2>&1 | Out-String
        }
        finally { Remove-Item Env:\CLAUDE_SHIM_ANSWERS -ErrorAction SilentlyContinue }

        $LASTEXITCODE | Should -Be 0
        $out | Should -Match 'Score: 2/2'
        $out | Should -Not -Match 'read-only'
    }

    It 'InvokeRegression_Never_ModifiesOwnerCheckout' {
        $before = @(& git -C $script:Root status --porcelain) -join "`n"

        Invoke-Runner -AnswerFile (New-AnswerFile) | Out-Null

        (@(& git -C $script:Root status --porcelain) -join "`n") | Should -Be $before
    }
}
