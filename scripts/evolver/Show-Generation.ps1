#Requires -Version 7.0
<#
.SYNOPSIS
    Prints the lineage and one generation note (the latest by default). Read-only. Used by `/evolve show`.
#>
[CmdletBinding()]
param(
    [string] $RepoRoot,
    [int] $Generation = -1
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Contract.psm1" -Force
$RepoRoot = Resolve-ProjectRoot -ProjectRoot $RepoRoot

$lineagePath = Join-Path $RepoRoot 'evolution/lineage.md'
if (-not (Test-Path -LiteralPath $lineagePath)) { Write-Output 'No evolution/lineage.md yet.'; exit 1 }

$state = Get-LineageState -Path $lineagePath
if ($Generation -lt 0) { $Generation = $state.LastGeneration }

Write-Output '## Lineage'
Write-Output (Get-Content -LiteralPath $lineagePath -Raw).TrimEnd()
Write-Output ''

$notePath = Join-Path $RepoRoot "evolution/generations/gen-$Generation.md"
if (-not (Test-Path -LiteralPath $notePath)) {
    Write-Output "No generation note for gen/$Generation (expected evolution/generations/gen-$Generation.md)."
    exit 1
}

Write-Output "## Generation note: evolution/generations/gen-$Generation.md"
Write-Output (Get-Content -LiteralPath $notePath -Raw).TrimEnd()
Write-Output ''
if ($Generation -gt 0) {
    Write-Output "Emergency exit for this generation: /evolve revert $Generation  (runs git revert gen/$Generation and records the revert in the lineage)."
}
exit 0
