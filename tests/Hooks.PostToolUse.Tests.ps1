#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path
    $script:Hook = Join-Path $script:PluginRoot 'hooks/PostToolUse.ps1'

    function Invoke-Hook {
        param([string] $Root, [string] $ToolName, [hashtable] $ToolInput)
        $json = @{ session_id = 'sess-use'; hook_event_name = 'PostToolUse'; tool_name = $ToolName; tool_input = $ToolInput; tool_use_id = 'tu-1'; cwd = $Root } | ConvertTo-Json -Compress -Depth 5
        $out = & $script:Hook -InputJson $json -RepoRoot $Root 2>&1 | Out-String
        [pscustomobject]@{ Output = $out.Trim(); ExitCode = $LASTEXITCODE }
    }

    function Get-Records {
        param([string] $Root)
        $dir = Join-Path $Root 'evolution\feedback'
        if (-not (Test-Path $dir)) { return @() }
        @(Get-ChildItem $dir -Filter '*.jsonl' | Get-Content | ForEach-Object { $_ | ConvertFrom-Json })
    }
}

Describe 'PostToolUse hook' {
    BeforeEach {
        $script:Root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory -Path $script:Root -Force | Out-Null
    }

    It 'PostToolUse_SkillCall_WritesUsageRecordWithSkillName' {
        $r = Invoke-Hook -Root $script:Root -ToolName 'Skill' -ToolInput @{ skill = 'fix-violations'; args = 'SA1210' }

        $r.ExitCode | Should -Be 0
        $r.Output | Should -BeNullOrEmpty
        $records = @(Get-Records -Root $script:Root)
        $records.Count | Should -Be 1
        $records[0].signal | Should -Be 'usage'
        $records[0].value | Should -Be 'fix-violations'
        $records[0].kind | Should -Be 'skill'
        $records[0].session_id | Should -Be 'sess-use'
        $records[0].ref | Should -Be 'transcript:sess-use#tu-1'
    }

    It 'PostToolUse_AgentCall_WritesUsageRecordWithAgentType' {
        Invoke-Hook -Root $script:Root -ToolName 'Agent' -ToolInput @{ subagent_type = 'Explore'; prompt = 'find x' } | Out-Null

        $records = @(Get-Records -Root $script:Root)
        $records.Count | Should -Be 1
        $records[0].value | Should -Be 'Explore'
        $records[0].kind | Should -Be 'agent'
    }

    It 'PostToolUse_TaskCallWithSubagentType_WritesAgentUsage' {
        Invoke-Hook -Root $script:Root -ToolName 'Task' -ToolInput @{ subagent_type = 'Planner'; description = 'plan' } | Out-Null

        (Get-Records -Root $script:Root)[0].value | Should -Be 'Planner'
    }

    It 'PostToolUse_OtherTool_WritesNothing' {
        Invoke-Hook -Root $script:Root -ToolName 'Read' -ToolInput @{ file_path = 'x' } | Out-Null

        @(Get-Records -Root $script:Root).Count | Should -Be 0
    }

    It 'PostToolUse_SkillWithoutName_WritesNothing' {
        Invoke-Hook -Root $script:Root -ToolName 'Skill' -ToolInput @{ args = 'x' } | Out-Null

        @(Get-Records -Root $script:Root).Count | Should -Be 0
    }

    It 'PostToolUse_InsideClassifierChild_WritesNothing' {
        $env:EVOLUTION_CLASSIFIER = '1'
        try {
            Invoke-Hook -Root $script:Root -ToolName 'Skill' -ToolInput @{ skill = 'refit' } | Out-Null
        }
        finally {
            Remove-Item Env:\EVOLUTION_CLASSIFIER -ErrorAction SilentlyContinue
        }

        @(Get-Records -Root $script:Root).Count | Should -Be 0
    }
}
