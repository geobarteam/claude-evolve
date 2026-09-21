#Requires -Version 7.0
<#
.SYNOPSIS
    Disposable git worktrees under the temp folder, shared by the regression harness and the evolver runner.
    Protected file.
#>

Set-StrictMode -Version Latest

function New-DisposableWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $Ref,
        [string] $Prefix = 'evolve-wt'
    )

    $path = Join-Path ([System.IO.Path]::GetTempPath()) ("{0}-{1:yyyyMMdd-HHmmss}-{2}" -f $Prefix, [datetime]::UtcNow, [guid]::NewGuid().ToString('N').Substring(0, 6))
    $out = & git -C $RepoPath worktree add --detach -q $path $Ref 2>&1
    if ($LASTEXITCODE -ne 0) { throw "git worktree add failed: $($out -join "`n")" }
    return $path
}

function Remove-DisposableWorktree {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Path
    )

    if (-not $Path -or -not (Test-Path -LiteralPath $Path)) { return }
    & git -C $RepoPath worktree remove --force $Path 2>&1 | Out-Null
    & git -C $RepoPath worktree prune 2>&1 | Out-Null
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function New-DisposableWorktree, Remove-DisposableWorktree
