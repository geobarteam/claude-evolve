#Requires -Version 7.0
<#
.SYNOPSIS
    Genome helpers shared by the evolver runner, the contract checker and the tests.

.DESCRIPTION
    Protected file (see evolution/evolver/protected-paths.txt). The evolver may not edit it.
    - Get-GenomeManifest   : reads genome-paths.txt and protected-paths.txt.
    - Get-ProtectedSection : returns the exact byte range of the single PROTECTED block in CLAUDE.md.
    - Test-PathInManifest  : glob-aware membership test for repo-relative paths.
#>

Set-StrictMode -Version Latest

$script:ProtectedStart = '<!-- PROTECTED -->'
$script:ProtectedEnd = '<!-- /PROTECTED -->'

function Get-GenomeManifest {
    <#
    .SYNOPSIS
        Reads the two path manifests under evolution/evolver/.
    .OUTPUTS
        [pscustomobject] with Genome (string[]) and Protected (string[]), repo-relative, forward slashes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $RepoRoot
    )

    $evolverDir = Join-Path $RepoRoot 'evolution/evolver'
    $genome = Read-ManifestFile -Path (Join-Path $evolverDir 'genome-paths.txt')
    $protected = Read-ManifestFile -Path (Join-Path $evolverDir 'protected-paths.txt')

    [pscustomobject]@{
        Genome    = $genome
        Protected = $protected
    }
}

function Get-ProtectedSection {
    <#
    .SYNOPSIS
        Returns the single protected block of a file, with its character offsets.
    .DESCRIPTION
        Throws when the file does not contain exactly one PROTECTED block, so callers
        never silently compare against an empty or ambiguous range.
    .OUTPUTS
        [pscustomobject] with Text, Start (0-based index of the opening marker) and End (index just past the closing marker).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $content = [System.IO.File]::ReadAllText($Path)

    $starts = Find-AllIndexes -Text $content -Value $script:ProtectedStart
    $ends = Find-AllIndexes -Text $content -Value $script:ProtectedEnd

    if ($starts.Count -ne 1 -or $ends.Count -ne 1) {
        throw "Expected exactly one protected block in '$Path' but found $($starts.Count) opening and $($ends.Count) closing marker(s)."
    }

    $start = $starts[0]
    $end = $ends[0] + $script:ProtectedEnd.Length

    if ($end -le $start) {
        throw "Protected block in '$Path' has its closing marker before its opening marker."
    }

    [pscustomobject]@{
        Text  = $content.Substring($start, $end - $start)
        Start = $start
        End   = $end
    }
}

function Test-PathInManifest {
    <#
    .SYNOPSIS
        Tests whether a repo-relative path matches any manifest entry.
    .DESCRIPTION
        Entries are exact paths or globs. Supported wildcards: '**' (any depth), '*' (within one segment), '?'.
        Backslashes in either the path or the entries are normalised to forward slashes.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path,

        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [string[]] $Manifest
    )

    $normalised = ConvertTo-RepoPath -Path $Path

    foreach ($entry in $Manifest) {
        $pattern = ConvertTo-GlobRegex -Glob (ConvertTo-RepoPath -Path $entry)
        if ($normalised -match $pattern) {
            return $true
        }
    }

    return $false
}

function Read-ManifestFile {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    if (-not (Test-Path $Path)) {
        throw "Manifest file not found: $Path"
    }

    [string[]] (Get-Content -Path $Path |
            ForEach-Object { $_.Trim() } |
            Where-Object { $_ -and -not $_.StartsWith('#') } |
            ForEach-Object { ConvertTo-RepoPath -Path $_ })
}

function Find-AllIndexes {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [Parameter(Mandatory)] [string] $Value
    )

    $indexes = [System.Collections.Generic.List[int]]::new()
    $index = $Text.IndexOf($Value, [System.StringComparison]::Ordinal)
    while ($index -ge 0) {
        $indexes.Add($index)
        $index = $Text.IndexOf($Value, $index + $Value.Length, [System.StringComparison]::Ordinal)
    }

    return , $indexes.ToArray()
}

function ConvertTo-RepoPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $normalised = $Path -replace '\\', '/'
    while ($normalised.StartsWith('./')) {
        $normalised = $normalised.Substring(2)
    }

    $normalised
}

function ConvertTo-GlobRegex {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Glob)

    $escaped = [regex]::Escape($Glob)
    # Order matters: '**' first, then single '*', then '?'.
    $escaped = $escaped.Replace('\*\*/', '(?:.*/)?').Replace('\*\*', '.*').Replace('\*', '[^/]*').Replace('\?', '[^/]')

    "^$escaped$"
}

Export-ModuleMember -Function Get-GenomeManifest, Get-ProtectedSection, Test-PathInManifest
