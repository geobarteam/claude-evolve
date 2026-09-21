# Test-only helper: builds a throwaway project from the plugin templates for contract, evolver and regression tests.
Set-StrictMode -Version Latest

$script:Templates = Join-Path (Resolve-Path "$PSScriptRoot/..").Path 'templates'

function Invoke-RepoGit {
    param([string] $Path, [string[]] $GitArgs)
    $out = & git -C $Path -c user.name=owner -c user.email=owner@example.test -c commit.gpgsign=false -c core.autocrlf=false @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $out" }
    @($out | ForEach-Object { [string] $_ })
}

function Get-Template {
    param([string] $Name)
    [System.IO.File]::ReadAllText((Join-Path $script:Templates $Name))
}

function Set-ScaffoldFile {
    param([string] $Root, [string] $Rel, [string] $Content)
    $dest = Join-Path $Root $Rel
    New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
    [System.IO.File]::WriteAllText($dest, $Content, [System.Text.UTF8Encoding]::new($false))
}

function New-ContractRepo {
    <#
        Repository on branch dev shaped like an initialised project: CLAUDE.md (duties + protected block from the
        templates), MEMORY.md, both manifests, lineage.md with a gen/0 row, a minimal gen-0.md, evolve.json,
        a dummy hook + settings, one skill, a src file, one journal, two simple regression tasks.
        One owner commit, tagged gen/0.
    #>
    param([string] $Root, [string] $PreviousScore = '—')

    New-Item -ItemType Directory -Path $Root -Force | Out-Null
    Invoke-RepoGit -Path $Root -GitArgs @('init', '-q', '-b', 'dev') | Out-Null

    $block = (Get-Template 'protected-block.md') -replace '(?m)^\{\{HARD_CONSTRAINTS\}\}\r?\n', ''
    Set-ScaffoldFile -Root $Root -Rel 'CLAUDE.md' -Content ("# Test project`n`n" + (Get-Template 'duties.md') + "`n" + $block)
    Set-ScaffoldFile -Root $Root -Rel 'MEMORY.md' -Content (Get-Template 'MEMORY.md')
    Set-ScaffoldFile -Root $Root -Rel 'evolution/evolver/genome-paths.txt' -Content (Get-Template 'genome-paths.txt')
    Set-ScaffoldFile -Root $Root -Rel 'evolution/evolver/protected-paths.txt' -Content (Get-Template 'protected-paths.txt')
    Set-ScaffoldFile -Root $Root -Rel 'evolution/lineage.md' -Content ((Get-Template 'lineage.md') + "| gen/0 | 2026-09-21 | $PreviousScore | settled | baseline |`n")
    Set-ScaffoldFile -Root $Root -Rel 'evolution/generations/gen-0.md' -Content "# gen/0 — baseline`n`nDate: 2026-09-21`nScore: —`nStatus: settled (baseline; nothing to revert to)`n`nThis generation makes no behavioural change; it records the inventory of the genome.`n`nRetired:`n- nothing`n`nDeclined to change:`n- nothing`n"
    Set-ScaffoldFile -Root $Root -Rel 'evolution/evolve.json' -Content "{}`n"
    Set-ScaffoldFile -Root $Root -Rel 'evolution/journal/TEMPLATE.md' -Content (Get-Template 'journal-TEMPLATE.md')
    Set-ScaffoldFile -Root $Root -Rel 'evolution/journal/2026-09-20-0900.md' -Content "<!-- session: s1 -->`n## Task`nx`n## Outcome`ndone`n"
    Set-ScaffoldFile -Root $Root -Rel '.gitignore' -Content "evolution/.state/`n"
    Set-ScaffoldFile -Root $Root -Rel '.claude/hooks/Stop.ps1' -Content "exit 0`n"
    Set-ScaffoldFile -Root $Root -Rel '.claude/settings.json' -Content "{}`n"
    Set-ScaffoldFile -Root $Root -Rel '.claude/skills/refit/SKILL.md' -Content "---`nname: refit`n---`nRefit skill`n"
    Set-ScaffoldFile -Root $Root -Rel 'src/x.cs' -Content "class X {}`n"
    Set-ScaffoldFile -Root $Root -Rel 'evolution/regression/tasks/T01.md' -Content "---`nid: T01`ncheck: answer-contains`nexpect: alpha`nsource: test`n---`nSay alpha`n"
    Set-ScaffoldFile -Root $Root -Rel 'evolution/regression/tasks/T02.md' -Content "---`nid: T02`ncheck: answer-contains`nexpect: beta`nsource: test`n---`nSay beta`n"

    Invoke-RepoGit -Path $Root -GitArgs @('add', '-A') | Out-Null
    Invoke-RepoGit -Path $Root -GitArgs @('commit', '-q', '-m', 'chore: baseline') | Out-Null
    Invoke-RepoGit -Path $Root -GitArgs @('tag', 'gen/0') | Out-Null
    [string] (@(Invoke-RepoGit -Path $Root -GitArgs @('rev-parse', 'HEAD')) | Select-Object -First 1)
}

function New-Proposal {
    <#
        Proposal directory: files keyed by repo-relative path, plus evolution/generations/gen-<N>.md.
    #>
    param([string] $Dir, [hashtable] $Files, [int] $Generation = 1, [string] $Note)

    foreach ($rel in $Files.Keys) {
        $dest = Join-Path $Dir $rel
        New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($dest, [string] $Files[$rel], [System.Text.UTF8Encoding]::new($false))
    }
    if ($Note) {
        $noteDest = Join-Path $Dir "evolution/generations/gen-$Generation.md"
        New-Item -ItemType Directory -Path (Split-Path $noteDest -Parent) -Force | Out-Null
        [System.IO.File]::WriteAllText($noteDest, $Note, [System.Text.UTF8Encoding]::new($false))
    }
    $Dir
}

function New-Note {
    param([int] $Generation = 1, [string] $Summary = 'test generation', [object[]] $Changes)
    $sb = [System.Text.StringBuilder]::new()
    [void] $sb.AppendLine("# gen/$Generation — $Summary")
    [void] $sb.AppendLine()
    [void] $sb.AppendLine('Score: pending')
    [void] $sb.AppendLine()
    $k = 1
    foreach ($c in $Changes) {
        [void] $sb.AppendLine("Change ${k}: $($c.Title)")
        [void] $sb.AppendLine("  Files: $($c.Files -join ', ')")
        [void] $sb.AppendLine("  Why: $($c.Why)")
        [void] $sb.AppendLine("  Risk: low")
        [void] $sb.AppendLine()
        $k++
    }
    [void] $sb.AppendLine('Retired:')
    [void] $sb.AppendLine('- nothing')
    [void] $sb.AppendLine()
    [void] $sb.AppendLine('Declined to change:')
    [void] $sb.AppendLine('- nothing')
    $sb.ToString()
}

function Add-ProtectedEdit {
    # Returns CLAUDE.md content with one word changed inside the protected block.
    param([string] $Root)
    $content = [System.IO.File]::ReadAllText((Join-Path $Root 'CLAUDE.md'))
    $content.Replace('Correctability is terminal', 'Correctability is negotiable')
}

function Add-OutsideEdit {
    # Returns CLAUDE.md content with one line appended before the protected block.
    param([string] $Root)
    $content = [System.IO.File]::ReadAllText((Join-Path $Root 'CLAUDE.md'))
    $content.Replace('<!-- PROTECTED -->', "- New evolved instruction.`n`n<!-- PROTECTED -->")
}

Export-ModuleMember -Function Invoke-RepoGit, New-ContractRepo, New-Proposal, New-Note, Add-ProtectedEdit, Add-OutsideEdit
