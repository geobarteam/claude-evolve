#Requires -Version 7.0
<#
.SYNOPSIS
    Shared plumbing for the Claude Code hooks under .claude/hooks/.

.DESCRIPTION
    Protected file. Hooks receive one JSON object on stdin (session_id, transcript_path, cwd, hook_event_name, ...).
    For tests they accept the same JSON through -InputJson and the repo root through -RepoRoot.
    Hooks must never break a session: errors are appended to evolution/.state/hook-errors.log and the hook exits 0.
#>

Set-StrictMode -Version Latest

function Read-HookInput {
    <#
    .SYNOPSIS
        Parses the hook input from -InputJson or, when absent, from stdin.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyString()]
        [string] $InputJson
    )

    if ([string]::IsNullOrWhiteSpace($InputJson)) {
        try {
            $InputJson = [Console]::In.ReadToEnd()
        }
        catch {
            $InputJson = ''
        }
    }

    if ([string]::IsNullOrWhiteSpace($InputJson)) {
        return [pscustomobject]@{}
    }

    return ($InputJson | ConvertFrom-Json -Depth 32)
}

function Resolve-RepoRoot {
    <#
    .SYNOPSIS
        Repo root precedence: explicit -RepoRoot, CLAUDE_PROJECT_DIR, the hook input's cwd, then the fallback.
    #>
    [CmdletBinding()]
    param(
        [AllowNull()] [AllowEmptyString()] [string] $RepoRoot,
        [AllowNull()] $HookInput,
        [Parameter(Mandatory)] [string] $Fallback
    )

    foreach ($candidate in @($RepoRoot, $env:CLAUDE_PROJECT_DIR, (Get-HookProperty -Object $HookInput -Name 'cwd'), $Fallback)) {
        if (-not [string]::IsNullOrWhiteSpace($candidate) -and (Test-Path -LiteralPath $candidate)) {
            return (Resolve-Path -LiteralPath $candidate).Path
        }
    }

    throw 'Unable to resolve the repository root for the hook.'
}

function Get-HookProperty {
    [CmdletBinding()]
    param(
        [AllowNull()] $Object,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property -or $null -eq $property.Value) { return $Default }
    if ($property.Value -is [System.Collections.IList]) {
        Write-Output -NoEnumerate $property.Value
    }
    else {
        return $property.Value
    }
}

function Get-StateDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $dir = Join-Path $RepoRoot 'evolution/.state'
    if (-not (Test-Path -LiteralPath $dir)) {
        New-Item -ItemType Directory -Path $dir -Force | Out-Null
    }

    return $dir
}

function Write-HookError {
    <#
    .SYNOPSIS
        Appends an error line to evolution/.state/hook-errors.log; never throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $Hook,
        [Parameter(Mandatory)] [string] $Message
    )

    try {
        $log = Join-Path (Get-StateDirectory -RepoRoot $RepoRoot) 'hook-errors.log'
        Add-Content -Path $log -Value ("{0:o} {1}: {2}" -f [datetime]::UtcNow, $Hook, $Message)
    }
    catch {
        # Nothing left to do; the hook still exits 0.
    }
}

function Get-JournalFileName {
    <#
    .SYNOPSIS
        Journal file name for a session: YYYY-MM-DD-HHMM.md from the session start recorded by SessionStart, else now.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $SessionId
    )

    $stamp = [datetime]::Now
    $stateFile = Join-Path $RepoRoot "evolution/.state/$SessionId.json"
    if (Test-Path -LiteralPath $stateFile) {
        try {
            $started = (Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json).started
            if ($started) { $stamp = ([datetime] $started).ToLocalTime() }
        }
        catch {
            # Fall back to now.
        }
    }

    return ('{0:yyyy-MM-dd-HHmm}.md' -f $stamp)
}

function Find-SessionJournal {
    <#
    .SYNOPSIS
        The journal file whose first line is "<!-- session: <SessionId> -->", newest first; $null when none.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [Parameter(Mandatory)] [string] $SessionId
    )

    $journalDir = Join-Path $RepoRoot 'evolution/journal'
    if (-not (Test-Path -LiteralPath $journalDir)) { return $null }

    $marker = "<!-- session: $SessionId -->"
    Get-ChildItem -LiteralPath $journalDir -Filter '*.md' -File |
        Where-Object { $_.Name -ne 'TEMPLATE.md' } |
        Where-Object {
            $firstLine = Get-Content -LiteralPath $_.FullName -TotalCount 1
            $firstLine -and $firstLine.Trim() -eq $marker
        } |
        Sort-Object LastWriteTimeUtc -Descending |
        Select-Object -First 1
}

function Test-HookSuppressed {
    <#
    .SYNOPSIS
        True inside a headless child started by this project's own tooling (classifier, regression, evolver).
        Every hook exits 0 immediately when this is true, which is what prevents hook recursion.
    #>
    [CmdletBinding()]
    param()

    return ($env:EVOLUTION_CLASSIFIER -eq '1')
}

Export-ModuleMember -Function Read-HookInput, Resolve-RepoRoot, Get-HookProperty, Get-StateDirectory, Write-HookError, Get-JournalFileName, Find-SessionJournal, Test-HookSuppressed
