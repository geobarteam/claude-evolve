#Requires -Version 7.0
<#
.SYNOPSIS
    Regression task files and answer checks for the genome regression harness.

.DESCRIPTION
    Protected file. A task is one Markdown file under evolution/regression/tasks/:
      ---
      id: T01
      check: answer-contains | script
      expect: a | b            (answer-contains: every item must appear in the answer, case-insensitive)
      expect-not: c | d        (answer-contains: no item may appear)
      script: T05.check.ps1    (script: sibling script run with -Worktree; exit 0 = pass)
      source: <where the task came from>
      ---
      <prompt given to the agent>
    Checks are deterministic: substring containment or a script exit code. Never model-judged.
#>

Set-StrictMode -Version Latest

# Errors inside module functions must surface to the caller's try/catch (hooks log them and exit 0).
$ErrorActionPreference = 'Stop'

function Get-RegressionTasks {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $TasksDir)

    if (-not (Test-Path -LiteralPath $TasksDir)) { throw "Tasks directory not found: $TasksDir" }

    $tasks = foreach ($file in Get-ChildItem -LiteralPath $TasksDir -Filter 'T*.md' -File | Sort-Object Name) {
        $text = [System.IO.File]::ReadAllText($file.FullName)
        if ($text -notmatch '(?s)^---\r?\n(.*?)\r?\n---\r?\n(.*)$') { throw "Task file without front matter: $($file.Name)" }
        $front = $Matches[1]
        $prompt = $Matches[2].Trim()

        $fields = @{}
        foreach ($line in $front -split "`r?`n") {
            if ($line -match '^([A-Za-z-]+):\s*(.*)$') { $fields[$Matches[1].ToLowerInvariant()] = $Matches[2].Trim() }
        }

        [pscustomobject]@{
            Id        = [string] $fields['id']
            Check     = [string] $fields['check']
            Expect    = @(Split-List $fields['expect'])
            ExpectNot = @(Split-List $fields['expect-not'])
            Script    = if ($fields.ContainsKey('script') -and $fields['script']) { Join-Path $TasksDir $fields['script'] } else { $null }
            Source    = [string] $fields['source']
            Prompt    = $prompt
            File      = $file.FullName
        }
    }

    return @($tasks)
}

function Test-RegressionAnswer {
    <#
    .OUTPUTS
        [pscustomobject] Passed, Detail
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Task,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Answer,
        [Parameter(Mandatory)] [string] $Worktree
    )

    switch ($Task.Check) {
        'answer-contains' {
            $missing = @($Task.Expect | Where-Object { $Answer -notmatch [regex]::Escape($_) })
            $forbidden = @($Task.ExpectNot | Where-Object { $Answer -match [regex]::Escape($_) })
            $passed = ($missing.Count -eq 0 -and $forbidden.Count -eq 0)
            $detail = if ($passed) { 'all expected strings present' } else {
                (@($missing | ForEach-Object { "missing '$_'" }) + @($forbidden | ForEach-Object { "forbidden '$_' present" })) -join '; '
            }
            return [pscustomobject]@{ Passed = $passed; Detail = $detail }
        }
        'script' {
            if (-not $Task.Script -or -not (Test-Path -LiteralPath $Task.Script)) {
                return [pscustomobject]@{ Passed = $false; Detail = "check script not found: $($Task.Script)" }
            }
            $output = & $Task.Script -Worktree $Worktree 2>&1 | Out-String
            $passed = ($LASTEXITCODE -eq 0)
            return [pscustomobject]@{ Passed = $passed; Detail = $output.Trim() }
        }
        default {
            return [pscustomobject]@{ Passed = $false; Detail = "unknown check '$($Task.Check)'" }
        }
    }
}

function Split-List {
    [CmdletBinding()]
    param([AllowNull()] [AllowEmptyString()] [string] $Value)

    if ([string]::IsNullOrWhiteSpace($Value)) { return @() }
    return @($Value -split '\s*\|\s*' | Where-Object { $_ })
}

Export-ModuleMember -Function Get-RegressionTasks, Test-RegressionAnswer
