#Requires -Version 7.0
<#
.SYNOPSIS
    The owner's emergency exit: `git revert gen/N` plus a `reverted` row in the lineage, in one commit.

.DESCRIPTION
    Protected file. Used by `/evolve revert N` after the owner confirmed in the session (the command passes
    -Confirm:$false); by hand it asks for confirmation. The revert commit is made with the caller's own git
    identity, because reverting is the owner's act, not the evolver's. The tag gen/N is kept: history stays
    readable and the next evolver run treats every change of that generation as rejected.
    Refuses when the tag does not exist, when evolution/lineage.md has uncommitted changes, or when the index
    already holds staged changes (the lineage row is amended into the revert commit).
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [string] $RepoRoot,
    [Parameter(Mandatory)] [int] $Generation
)

$ErrorActionPreference = 'Stop'
Import-Module "$PSScriptRoot/../lib/Config.psm1" -Force
Import-Module "$PSScriptRoot/../lib/Contract.psm1" -Force
$RepoRoot = Resolve-ProjectRoot -ProjectRoot $RepoRoot

function Invoke-OwnerGit {
    param([string[]] $GitArgs)
    $out = & git -C $RepoRoot @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git $($GitArgs -join ' ') failed: $($out -join "`n")" }
    return @($out | ForEach-Object { [string] $_ })
}

$tag = "gen/$Generation"
& git -C $RepoRoot rev-parse -q --verify "refs/tags/$tag" 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Output "REFUSED: no tag $tag in this repository."
    exit 1
}

$lineagePath = Join-Path $RepoRoot 'evolution/lineage.md'
if (@(Invoke-OwnerGit -GitArgs @('status', '--porcelain', '--', 'evolution/lineage.md')).Count -gt 0) {
    Write-Output 'REFUSED: evolution/lineage.md has uncommitted changes; commit or discard them first.'
    exit 1
}
& git -C $RepoRoot diff --cached --quiet 2>&1 | Out-Null
if ($LASTEXITCODE -ne 0) {
    Write-Output 'REFUSED: the index already holds staged changes; commit or unstage them first.'
    exit 1
}

$subject = [string] (@(Invoke-OwnerGit -GitArgs @('log', '-1', '--format=%s', $tag)) | Select-Object -First 1)
if (-not $PSCmdlet.ShouldProcess("$tag ($subject)", 'git revert and record the revert in evolution/lineage.md')) {
    Write-Output 'Cancelled.'
    exit 0
}

Invoke-OwnerGit -GitArgs @('revert', '--no-edit', $tag) | Out-Null
Add-LineageRow -Path $lineagePath -Generation $tag -Score '—' -Status 'reverted' -Summary "reverted by the owner: $subject"
Invoke-OwnerGit -GitArgs @('add', '--', 'evolution/lineage.md') | Out-Null
Invoke-OwnerGit -GitArgs @('commit', '-q', '--amend', '--no-edit') | Out-Null

$sha = [string] (@(Invoke-OwnerGit -GitArgs @('rev-parse', '--short=12', 'HEAD')) | Select-Object -First 1)
Write-Output "$tag reverted in commit $sha; lineage row appended. The tag $tag is kept for history. Nothing was pushed."
exit 0
