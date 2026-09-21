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

# Errors inside module functions must surface to the caller's try/catch (hooks log them and exit 0).
$ErrorActionPreference = 'Stop'

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

function Get-EvolveConfig {
    <#
    .SYNOPSIS
        The project's evolve settings: evolution/evolve.json merged over the spec defaults.
    .DESCRIPTION
        Every key is optional; an absent file, an empty file or an empty string means "default".
        Unknown keys are ignored. Invalid JSON throws, naming the file.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $ProjectRoot)

    $path = Join-Path $ProjectRoot 'evolution/evolve.json'
    $raw = $null
    $source = 'defaults'
    if (Test-Path -LiteralPath $path -PathType Leaf) {
        $text = [System.IO.File]::ReadAllText($path)
        if (-not [string]::IsNullOrWhiteSpace($text)) {
            try { $raw = $text | ConvertFrom-Json -Depth 8 }
            catch { throw "evolution/evolve.json is not valid JSON: $($_.Exception.Message)" }
        }
        $source = 'evolution/evolve.json'
    }

    $leaf = (Split-Path $ProjectRoot -Leaf).ToLowerInvariant()
    $regression = Get-ConfigValue -Object $raw -Name 'regression' -Default $null
    $proposal = Get-ConfigValue -Object $raw -Name 'proposal' -Default $null
    $classifier = Get-ConfigValue -Object $raw -Name 'classifier' -Default $null

    return [pscustomobject]@{
        EvolverName         = [string] (Get-ConfigValue -Object $raw -Name 'evolverName' -Default 'evolver')
        EvolverEmail        = [string] (Get-ConfigValue -Object $raw -Name 'evolverEmail' -Default "evolver@$leaf.local")
        TranscriptDir       = Get-TranscriptDir -ProjectRoot $ProjectRoot -Configured ([string] (Get-ConfigValue -Object $raw -Name 'transcriptDir' -Default ''))
        MaxEdits            = [int] (Get-ConfigValue -Object $raw -Name 'maxEdits' -Default 3)
        SettleAfterDays     = [int] (Get-ConfigValue -Object $raw -Name 'settleAfterDays' -Default 14)
        RetireAfterDays     = [int] (Get-ConfigValue -Object $raw -Name 'retireAfterDays' -Default 30)
        Regression          = [pscustomobject]@{
            Model        = [string] (Get-ConfigValue -Object $regression -Name 'model' -Default 'sonnet')
            AllowedTools = [string] (Get-ConfigValue -Object $regression -Name 'allowedTools' -Default 'Read,Glob,Grep,Edit,Write')
        }
        Proposal            = [pscustomobject]@{
            Model        = [string] (Get-ConfigValue -Object $proposal -Name 'model' -Default 'sonnet')
            MaxBudgetUsd = [double] (Get-ConfigValue -Object $proposal -Name 'maxBudgetUsd' -Default 3)
        }
        Classifier          = [pscustomobject]@{
            Model = [string] (Get-ConfigValue -Object $classifier -Name 'model' -Default 'haiku')
        }
        AgentTrailerPattern = [string] (Get-ConfigValue -Object $raw -Name 'agentTrailerPattern' -Default '^Co-Authored-By:\s*Claude\b')
        MainLine            = [string] (Get-ConfigValue -Object $raw -Name 'mainLine' -Default '')
        Source              = $source
    }
}

function Get-ConfigValue {
    # A property of a parsed JSON object, or the default when the object, the property or the value is empty.
    [CmdletBinding()]
    param([AllowNull()] $Object, [Parameter(Mandatory)] [string] $Name, [AllowNull()] $Default)

    if ($null -eq $Object -or -not $Object.PSObject.Properties[$Name]) { return $Default }
    $value = $Object.$Name
    if ($null -eq $value -or ($value -is [string] -and [string]::IsNullOrWhiteSpace($value))) { return $Default }
    return $value
}

Export-ModuleMember -Function Resolve-ProjectRoot, Get-PluginRoot, ConvertTo-ClaudeProjectFolderName, Get-TranscriptDir, Get-EvolveConfig
