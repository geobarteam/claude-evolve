#Requires -Version 7.0
<#
.SYNOPSIS
    Project scaffolding for `/evolve:init`: every artifact is created only when missing, never overwritten.

.DESCRIPTION
    Protected file (plugin engine). Writes the project state the engine needs: the duties section and the
    protected block in CLAUDE.md, MEMORY.md, the evolution/ tree (journal template, feedback, generations with a
    generated gen-0 inventory, lineage, manifests, evolve.json, regression skeletons) and the .gitignore entries.
    Nothing here runs git add, commit or tag.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Genome.psm1')

$script:Templates = Join-Path (Resolve-Path "$PSScriptRoot/../..").Path 'templates'
$script:Utf8 = [System.Text.UTF8Encoding]::new($false)
$script:ProjectConstraintsPattern = '(?m)^- Hard constraints for this project:\n(  - .*\n?)*'

function Get-InitTemplate {
    param([Parameter(Mandatory)] [string] $Name)
    [System.IO.File]::ReadAllText((Join-Path $script:Templates $Name))
}

function Read-ProjectText {
    param([Parameter(Mandatory)] [string] $Path)
    [System.IO.File]::ReadAllText($Path)
}

function Write-ProjectText {
    param([Parameter(Mandatory)] [string] $Path, [AllowEmptyString()] [string] $Content)
    $parent = Split-Path $Path -Parent
    if ($parent -and -not (Test-Path -LiteralPath $parent)) { New-Item -ItemType Directory -Path $parent -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, $Content, $script:Utf8)
}

function ConvertTo-Lf {
    param([AllowEmptyString()] [string] $Text)
    $Text -replace "`r`n", "`n"
}

function Test-ProjectInitialised {
    <#
    .SYNOPSIS
        True when CLAUDE.md carries a protected block and evolution/lineage.md exists.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $claude = Join-Path $ProjectRoot 'CLAUDE.md'
    if (-not (Test-Path -LiteralPath $claude)) { return $false }
    if ((Read-ProjectText -Path $claude) -notmatch '<!-- PROTECTED -->') { return $false }
    return (Test-Path -LiteralPath (Join-Path $ProjectRoot 'evolution/lineage.md'))
}

function Get-ProtectedBlockTemplate {
    <#
    .SYNOPSIS
        The protected block text; with -Constraints a "Hard constraints for this project" list replaces the marker line.
    #>
    [CmdletBinding()]
    param([string[]] $Constraints = @())

    $text = Get-InitTemplate 'protected-block.md'
    $constraints = @($Constraints | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $replacement = ''
    if ($constraints.Count -gt 0) {
        $replacement = (@('- Hard constraints for this project:') + @($constraints | ForEach-Object { "  - $($_.Trim())" })) -join "`n"
        $replacement += "`n"
    }
    return [regex]::Replace($text, '\{\{HARD_CONSTRAINTS\}\}\r?\n', { param($m) $replacement })
}

function Add-ProtectedBlock {
    <#
    .SYNOPSIS
        Appends the block to CLAUDE.md once. Returns 'created', or 'protected block already present' without writing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ClaudeMdPath, [Parameter(Mandatory)] [string] $Text)

    $content = Read-ProjectText -Path $ClaudeMdPath
    if ($content -match '<!-- PROTECTED -->') { return 'protected block already present' }

    $block = $Text.TrimEnd() + "`n"
    $body = $content.TrimEnd()
    $new = if ($body.Length -eq 0) { $block } else { $body + "`n`n" + $block }
    Write-ProjectText -Path $ClaudeMdPath -Content $new
    return 'created'
}

function Compare-ProtectedBlock {
    <#
    .SYNOPSIS
        BR-4: reports (never rewrites) a block that differs from the plugin template; project constraints are ignored.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ClaudeMdPath, [Parameter(Mandatory)] [string] $Template)

    $section = Get-ProtectedSection -Path $ClaudeMdPath
    $existing = ([regex]::Replace((ConvertTo-Lf $section.Text), $script:ProjectConstraintsPattern, '')).Trim()
    $expected = ([regex]::Replace((ConvertTo-Lf $Template), $script:ProjectConstraintsPattern, '')).Trim()
    if ($existing -cne $expected) { return 'protected block differs from the plugin template (kept as is)' }
    return $null
}

function Add-DutiesSection {
    <#
    .SYNOPSIS
        Inserts the working-agent duties before the protected block (or at the end) unless the heading already exists.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ClaudeMdPath, [string] $ConstraintLine)

    $content = Read-ProjectText -Path $ClaudeMdPath
    if ($content -match '(?m)^## Working agent duties') { return 'kept' }

    $duties = (Get-InitTemplate 'duties.md').TrimEnd() + "`n"
    if ($ConstraintLine) { $duties += "- **Hard constraints.** $($ConstraintLine.Trim())`n" }

    $index = $content.IndexOf('<!-- PROTECTED -->')
    $new = if ($index -ge 0) {
        $head = $content.Substring(0, $index).TrimEnd()
        $prefix = if ($head.Length -gt 0) { $head + "`n`n" } else { '' }
        $prefix + $duties + "`n" + $content.Substring($index)
    }
    else {
        $body = $content.TrimEnd()
        if ($body.Length -gt 0) { $body + "`n`n" + $duties } else { $duties }
    }
    Write-ProjectText -Path $ClaudeMdPath -Content $new
    return 'created'
}

function Get-FrontMatterDescription {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $text = Read-ProjectText -Path $Path
    if ($text -match '(?s)^---\r?\n(.*?)\r?\n---') {
        $frontMatter = $Matches[1]
        if ($frontMatter -match '(?m)^description:\s*(.+?)\s*$') {
            $value = $Matches[1].Trim()
            if ($value.Length -ge 2 -and (($value[0] -eq '"' -and $value[-1] -eq '"') -or ($value[0] -eq "'" -and $value[-1] -eq "'"))) { $value = $value.Substring(1, $value.Length - 2) }
            return (($value -split '\r?\n')[0]).Trim()
        }
    }
    if ($text -match '(?m)^#\s+(.+?)\s*$') { return $Matches[1].Trim() }
    return '(no description)'
}

function New-GenerationZeroNote {
    <#
    .SYNOPSIS
        Builds the gen-0 inventory note from the project's .claude/ folder. Returns Text, Summary, Warning.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $claudeDir = Join-Path $ProjectRoot '.claude'
    $warning = if (Test-Path -LiteralPath $claudeDir) { $null } else { 'no .claude/ folder found; inventory sections are empty' }

    function Get-Rows {
        param([string] $Folder, [string] $Filter = '*', [switch] $Recurse, [scriptblock] $Display = { param($f, $base) $f.Name })
        $path = Join-Path $claudeDir $Folder
        if (-not (Test-Path -LiteralPath $path)) { return @() }
        $files = @(Get-ChildItem -LiteralPath $path -Filter $Filter -File -Recurse:$Recurse | Sort-Object FullName)
        foreach ($f in $files) { [pscustomobject]@{ Name = (& $Display $f $path); Description = (Get-FrontMatterDescription -Path $f.FullName) } }
    }

    $instructions = @()
    foreach ($rel in 'CLAUDE.md', 'MEMORY.md') {
        $p = Join-Path $ProjectRoot $rel
        if (Test-Path -LiteralPath $p) { $instructions += [pscustomobject]@{ Name = $rel; Description = (Get-FrontMatterDescription -Path $p) } }
    }
    $instructionFiles = @(Get-Rows -Folder 'instructions' -Filter '*.md')
    $instructions += $instructionFiles
    $sections = [ordered]@{
        'Instructions' = $instructions
        'Sub-agents'   = @(Get-Rows -Folder 'agents' -Filter '*.md')
        'Skills'       = @(Get-Rows -Folder 'skills' -Filter 'SKILL.md' -Recurse -Display { param($f, $base) ($f.FullName.Substring($base.Length + 1) -replace '\\', '/') })
        'Commands'     = @(Get-Rows -Folder 'commands' -Filter '*.md')
        'Templates'    = @(Get-Rows -Folder 'templates')
        'Tools'        = @(Get-Rows -Folder 'tools' -Recurse -Display { param($f, $base) ($f.FullName.Substring($base.Length + 1) -replace '\\', '/') })
    }

    $today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    $sb = [System.Text.StringBuilder]::new()
    [void] $sb.AppendLine('# gen/0 — Inventory of the host genome')
    [void] $sb.AppendLine()
    [void] $sb.AppendLine("Date: $today")
    [void] $sb.AppendLine('Score: —')
    [void] $sb.AppendLine('Status: settled (baseline; nothing to revert to)')
    [void] $sb.AppendLine()
    [void] $sb.AppendLine('This generation makes no behavioural change. It records what the working agent is made of at the moment the evolve plugin was initialised, adds the owner''s protected constraints to `CLAUDE.md`, and creates `MEMORY.md` as the versioned home for project beliefs.')
    [void] $sb.AppendLine()
    [void] $sb.AppendLine('## Genome files')
    [void] $sb.AppendLine()
    foreach ($name in $sections.Keys) {
        [void] $sb.AppendLine("### $name")
        [void] $sb.AppendLine()
        $rows = @($sections[$name])
        if ($rows.Count -eq 0) {
            [void] $sb.AppendLine('(none)')
        }
        else {
            [void] $sb.AppendLine('| File | Purpose |')
            [void] $sb.AppendLine('| --- | --- |')
            foreach ($row in $rows) { [void] $sb.AppendLine("| ``$($row.Name)`` | $($row.Description -replace '\|', '/') |") }
        }
        [void] $sb.AppendLine()
    }
    [void] $sb.AppendLine('Retired:')
    [void] $sb.AppendLine('- nothing')
    [void] $sb.AppendLine()
    [void] $sb.AppendLine('Declined to change:')
    [void] $sb.AppendLine('- nothing')

    $summary = 'Inventory: {0} agent(s), {1} skill(s), {2} command(s), {3} instruction file(s), {4} template(s); protected block and duties added to CLAUDE.md; MEMORY.md created' -f `
        $sections['Sub-agents'].Count, $sections['Skills'].Count, $sections['Commands'].Count, $instructionFiles.Count, $sections['Templates'].Count

    return [pscustomobject]@{ Text = $sb.ToString(); Summary = $summary; Warning = $warning }
}

function New-LineageFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot, [Parameter(Mandatory)] [string] $Summary)

    $path = Join-Path $ProjectRoot 'evolution/lineage.md'
    if (Test-Path -LiteralPath $path) { return 'kept' }
    $today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    Write-ProjectText -Path $path -Content ((Get-InitTemplate 'lineage.md').TrimEnd() + "`n| gen/0 | $today | — | settled | $($Summary -replace '\|', '/') |`n")
    return 'created'
}

function New-EvolveConfig {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $path = Join-Path $ProjectRoot 'evolution/evolve.json'
    if (Test-Path -LiteralPath $path) { return 'kept' }
    $branch = ''
    $out = & git -C $ProjectRoot symbolic-ref --short -q HEAD 2>&1
    if ($LASTEXITCODE -eq 0) { $branch = ([string] (@($out) | Select-Object -First 1)).Trim() }
    if (-not $branch) { $branch = 'main' }
    Write-ProjectText -Path $path -Content ((Get-InitTemplate 'evolve.json').Replace('"mainLine": ""', "`"mainLine`": `"$branch`""))
    return 'created'
}

function New-RegressionSkeletons {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $dir = Join-Path $ProjectRoot 'evolution/regression/tasks'
    if ((Test-Path -LiteralPath $dir) -and @(Get-ChildItem -LiteralPath $dir -Filter 'T*.md' -File).Count -gt 0) { return @() }
    $created = @()
    foreach ($name in 'T01.md', 'T02.md') {
        Write-ProjectText -Path (Join-Path $dir $name) -Content (Get-InitTemplate "regression/$name")
        $created += "evolution/regression/tasks/$name"
    }
    return $created
}

function Add-GitignoreEntries {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $path = Join-Path $ProjectRoot '.gitignore'
    $content = if (Test-Path -LiteralPath $path) { Read-ProjectText -Path $path } else { '' }
    $lines = @((ConvertTo-Lf $content) -split "`n" | ForEach-Object { $_.Trim() })
    $missing = @('evolution/.state/', 'evolution/labelled/' | Where-Object { $_ -notin $lines })
    if ($missing.Count -eq 0) { return 'kept' }
    $body = $content.TrimEnd()
    $prefix = if ($body.Length -gt 0) { $body + "`n`n" } else { '' }
    $new = $prefix + "# evolve plugin: per-session state and local labels are never committed`n" + ($missing -join "`n") + "`n"
    Write-ProjectText -Path $path -Content $new
    return 'created'
}

function Test-DuplicateHooks {
    <#
    .SYNOPSIS
        Warnings for project hooks in .claude/settings.json that already run one of the plugin's hook scripts.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $path = Join-Path $ProjectRoot '.claude/settings.json'
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    try { $settings = Read-ProjectText -Path $path | ConvertFrom-Json -Depth 16 } catch { return @() }
    if ($null -eq $settings -or -not $settings.PSObject.Properties['hooks'] -or $null -eq $settings.hooks) { return @() }

    $warnings = @()
    foreach ($hookEvent in $settings.hooks.PSObject.Properties.Name) {
        foreach ($entry in @($settings.hooks.$hookEvent)) {
            if ($null -eq $entry -or -not $entry.PSObject.Properties['hooks']) { continue }
            foreach ($hook in @($entry.hooks)) {
                $command = if ($hook.PSObject.Properties['command']) { [string] $hook.command } else { '' }
                if ($command -match 'SessionStart\.ps1|Stop\.ps1|SessionEnd\.ps1|UserPromptSubmit\.ps1|PostToolUse\.ps1') {
                    $warnings += "settings.json already runs $hookEvent hook '$command'; the plugin hook will run in addition"
                }
            }
        }
    }
    return @($warnings)
}

function Copy-ProjectTemplates {
    <#
    .SYNOPSIS
        MEMORY.md, the journal template, both manifests, the feedback folder and the generations folder, each only when missing.
    .OUTPUTS
        Objects with Path (repo-relative) and Status ('created' | 'kept').
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $map = [ordered]@{
        'MEMORY.md'                             = 'MEMORY.md'
        'evolution/journal/TEMPLATE.md'         = 'journal-TEMPLATE.md'
        'evolution/evolver/genome-paths.txt'    = 'genome-paths.txt'
        'evolution/evolver/protected-paths.txt' = 'protected-paths.txt'
        'evolution/feedback/.gitkeep'           = $null
    }
    $results = foreach ($rel in $map.Keys) {
        $dest = Join-Path $ProjectRoot $rel
        if (Test-Path -LiteralPath $dest) { [pscustomobject]@{ Path = $rel; Status = 'kept' }; continue }
        $content = if ($map[$rel]) { Get-InitTemplate $map[$rel] } else { '' }
        Write-ProjectText -Path $dest -Content $content
        [pscustomobject]@{ Path = $rel; Status = 'created' }
    }
    $generations = Join-Path $ProjectRoot 'evolution/generations'
    if (-not (Test-Path -LiteralPath $generations)) { New-Item -ItemType Directory -Path $generations -Force | Out-Null }
    return @($results)
}

Export-ModuleMember -Function Test-ProjectInitialised, Get-ProtectedBlockTemplate, Add-ProtectedBlock, Compare-ProtectedBlock, Add-DutiesSection, Get-FrontMatterDescription, New-GenerationZeroNote, New-LineageFile, New-EvolveConfig, New-RegressionSkeletons, Add-GitignoreEntries, Test-DuplicateHooks, Copy-ProjectTemplates
