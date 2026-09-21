#Requires -Version 7.0
<#
.SYNOPSIS
    What `/evolve:init` runs: scaffolds a project for the self-evolving agent, one artifact at a time, idempotently.

.DESCRIPTION
    Refuses when CLAUDE.md is missing. Otherwise creates only what is missing: the working-agent duties section
    and the protected block in CLAUDE.md, MEMORY.md, the evolution/ tree (journal template, feedback folder,
    generated gen-0 inventory, lineage with a gen/0 row, both manifests, evolve.json, regression skeletons),
    the .gitignore entries and, with -IncludeCi, the Azure pipeline template. An existing protected block is
    never rewritten (BR-4: a difference from the template is reported). Never runs git add, commit or tag.

.PARAMETER Constraints
    Project-specific hard constraints; placed inside the protected block (-ConstraintPlacement protected, the
    default: the evolver can never touch them) or as a duties line (-ConstraintPlacement duties).

.EXAMPLE
    pwsh "<plugin root>/scripts/Initialize-Project.ps1" -ProjectRoot . -Constraints 'the client never holds tokens'
#>
[CmdletBinding()]
param(
    [string] $ProjectRoot,
    [string[]] $Constraints = @(),
    [ValidateSet('protected', 'duties')] [string] $ConstraintPlacement = 'protected',
    [switch] $IncludeCi
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/lib/Init.psm1" -Force
$ProjectRoot = Resolve-ProjectRoot -ProjectRoot $ProjectRoot

$claudeMd = Join-Path $ProjectRoot 'CLAUDE.md'
if (-not (Test-Path -LiteralPath $claudeMd -PathType Leaf)) {
    Write-Output 'CLAUDE.md not found'
    exit 1
}

$created = [System.Collections.Generic.List[string]]::new()
function Report {
    param([string] $Path, [string] $Status)
    if ($Status -eq 'created') { $created.Add($Path); Write-Output "created $Path" } else { Write-Output "kept $Path" }
}

# 1. Duties section (before the block) and the protected block itself.
$constraintLine = if ($ConstraintPlacement -eq 'duties' -and $Constraints.Count -gt 0) { ($Constraints -join '; ') } else { $null }
Report 'CLAUDE.md (working agent duties)' (Add-DutiesSection -ClaudeMdPath $claudeMd -ConstraintLine $constraintLine)

$blockConstraints = if ($ConstraintPlacement -eq 'protected') { $Constraints } else { @() }
$blockResult = Add-ProtectedBlock -ClaudeMdPath $claudeMd -Text (Get-ProtectedBlockTemplate -Constraints $blockConstraints)
if ($blockResult -eq 'created') {
    Report 'CLAUDE.md (protected block)' 'created'
}
else {
    Write-Output $blockResult
    $difference = Compare-ProtectedBlock -ClaudeMdPath $claudeMd -Template (Get-ProtectedBlockTemplate)
    if ($difference) { Write-Output $difference }
}

# 2. Templates that copy verbatim.
foreach ($item in Copy-ProjectTemplates -ProjectRoot $ProjectRoot) { Report $item.Path $item.Status }

# 3. Generated files: gen-0 inventory, lineage, config.
$inventory = New-GenerationZeroNote -ProjectRoot $ProjectRoot
if ($inventory.Warning) { Write-Output "warning: $($inventory.Warning)" }
$gen0 = Join-Path $ProjectRoot 'evolution/generations/gen-0.md'
if (Test-Path -LiteralPath $gen0) { Report 'evolution/generations/gen-0.md' 'kept' }
else {
    [System.IO.File]::WriteAllText($gen0, $inventory.Text, [System.Text.UTF8Encoding]::new($false))
    Report 'evolution/generations/gen-0.md' 'created'
}
Report 'evolution/lineage.md' (New-LineageFile -ProjectRoot $ProjectRoot -Summary $inventory.Summary)
Report 'evolution/evolve.json' (New-EvolveConfig -ProjectRoot $ProjectRoot)

# 4. Regression skeletons (only when the project has no tasks yet).
$skeletons = @(New-RegressionSkeletons -ProjectRoot $ProjectRoot)
if ($skeletons.Count -eq 0) { Write-Output 'kept evolution/regression/tasks/ (existing tasks)' }
foreach ($rel in $skeletons) { Report $rel 'created' }

# 5. .gitignore entries.
Report '.gitignore (evolution/.state/, evolution/labelled/)' (Add-GitignoreEntries -ProjectRoot $ProjectRoot)

# 6. Optional CI template.
if ($IncludeCi) {
    $ci = Join-Path $ProjectRoot 'azure-pipeline-genome.yml'
    if (Test-Path -LiteralPath $ci) { Report 'azure-pipeline-genome.yml' 'kept' }
    else {
        Copy-Item -LiteralPath (Join-Path (Resolve-Path "$PSScriptRoot/..").Path 'templates/azure-pipeline-genome.yml') -Destination $ci
        Report 'azure-pipeline-genome.yml' 'created'
    }
}

# 7. Warnings about project hooks that duplicate the plugin's.
foreach ($warning in Test-DuplicateHooks -ProjectRoot $ProjectRoot) { Write-Output "warning: $warning" }

if ($created.Count -eq 0) { Write-Output 'already initialised; nothing changed' }
else { Write-Output "initialised $($created.Count) artifact(s); nothing was committed or tagged" }
exit 0
