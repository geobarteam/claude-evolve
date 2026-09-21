#Requires -Version 7.0
<#
.SYNOPSIS
    Where things are: the project root, the plugin root and the project's Claude Code transcript folder.

.DESCRIPTION
    Protected file (plugin engine). The project root is never derived from the plugin's own location:
    explicit parameter, then CLAUDE_PROJECT_DIR, then the hook input's cwd, then the current directory.
#>

Set-StrictMode -Version Latest

# git and claude write UTF-8; a non-UTF-8 console (pwsh started from Git Bash on Windows uses code page 850)
# would garble every non-ASCII character the engine reads back from them.
if ([Console]::OutputEncoding.CodePage -ne 65001) { [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new($false) }

function Resolve-ProjectRoot {
    <#
    .SYNOPSIS
        Returns the project root the engine acts on.
    .DESCRIPTION
        Precedence: -ProjectRoot, $env:CLAUDE_PROJECT_DIR, the hook input's `cwd`, the current directory.
        Throws when the chosen candidate is not an existing folder.
    #>
    [CmdletBinding()]
    param(
        [string] $ProjectRoot,
        [object] $HookInput
    )

    $cwd = $null
    if ($null -ne $HookInput -and $HookInput.PSObject.Properties['cwd']) { $cwd = [string] $HookInput.cwd }

    $candidate = $null
    foreach ($c in @($ProjectRoot, $env:CLAUDE_PROJECT_DIR, $cwd, (Get-Location).Path)) {
        if (-not [string]::IsNullOrWhiteSpace($c)) { $candidate = $c; break }
    }

    if (-not (Test-Path -LiteralPath $candidate -PathType Container)) {
        throw "Unable to resolve the project root. '$candidate' is not a folder."
    }
    return (Resolve-Path -LiteralPath $candidate).Path
}

function Get-PluginRoot {
    <#
    .SYNOPSIS
        The plugin's own folder: $env:CLAUDE_PLUGIN_ROOT when set, else the folder above scripts/.
    #>
    [CmdletBinding()]
    param()

    if ($env:CLAUDE_PLUGIN_ROOT -and (Test-Path -LiteralPath $env:CLAUDE_PLUGIN_ROOT -PathType Container)) {
        return (Resolve-Path -LiteralPath $env:CLAUDE_PLUGIN_ROOT).Path
    }
    return (Resolve-Path "$PSScriptRoot/../..").Path
}

function ConvertTo-ClaudeProjectFolderName {
    <#
    .SYNOPSIS
        Encodes a project path the way Claude Code names its per-project transcript folder:
        lower-case drive letter, every path separator, colon and dot replaced by '-'.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $p = $Path.TrimEnd('\', '/')
    if ($p -match '^[A-Za-z]:') { $p = $p.Substring(0, 1).ToLowerInvariant() + $p.Substring(1) }
    return ($p -replace '[\\/:.]', '-')
}

function Get-TranscriptDir {
    <#
    .SYNOPSIS
        The folder holding the project's session transcripts: the configured value when given,
        else $HOME/.claude/projects/<encoded project path>.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $ProjectRoot,
        [string] $Configured
    )

    if ($Configured) { return $Configured }
    return Join-Path (Join-Path (Join-Path $HOME '.claude') 'projects') (ConvertTo-ClaudeProjectFolderName -Path $ProjectRoot)
}

Export-ModuleMember -Function Resolve-ProjectRoot, Get-PluginRoot, ConvertTo-ClaudeProjectFolderName, Get-TranscriptDir
