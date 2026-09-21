#Requires -Version 7.0
<#
.SYNOPSIS
    Git-derived feedback signals: owner edits to agent-written code, reverts, bug fixes, diff survival, commit markers.

.DESCRIPTION
    Protected file. Agent commits are recognised by the trailer "Co-Authored-By: Claude ..." (CLAUDE.md rule).
    Every Get-* function returns signal objects { Signal, Value, Reason, Ref, Extra } without writing anything;
    Invoke-GitSignals writes them through Feedback.psm1 and keeps a cursor in evolution/.state/git-cursor.json
    so a signal is written once per source commit.

    Signals
      code-correction   owner commit changes lines an agent commit wrote (value: the verbatim hunk, ref: agent sha)
      code-revert       owner commit is a `git revert` of an agent commit (weight 2)
      bug-attribution   owner `fix` commit changes agent lines (ref: agent sha)
      diff-survival     fraction of an agent commit's added lines still in HEAD after MinAgeDays (ref: agent sha)
      commit-marker     #agent-good / #agent-bad: <reason> in any commit message (ref: that commit)
      generation-revert `Revert "gen(N): ..."` commit (value: gen/N, ref: revert commit)
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Feedback.psm1')

$script:AgentTrailerPattern = '^Co-Authored-By:\s*Claude\b'   # '(?im)' is applied at match time; override per call with -TrailerPattern (evolve.json agentTrailerPattern)
$script:FieldSeparator = [char] 0x1f
$script:RecordSeparator = [char] 0x1e

# Errors inside module functions must surface to the caller's try/catch (hooks log them and exit 0).
$ErrorActionPreference = 'Stop'

function Invoke-Git {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string[]] $GitArgs
    )

    $output = & git -C $RepoPath -c core.quotepath=false @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0) {
        throw "git $($GitArgs -join ' ') failed in '$RepoPath': $($output -join "`n")"
    }

    return @($output | ForEach-Object { [string] $_ })
}

function Test-GitRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoPath)

    if (-not (Test-Path -LiteralPath $RepoPath)) { return $false }
    & git -C $RepoPath rev-parse --is-inside-work-tree 2>&1 | Out-Null
    return ($LASTEXITCODE -eq 0)
}

function Get-Commits {
    <#
    .SYNOPSIS
        Commits in the window (oldest first) with IsAgent set from the trailer.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [int] $SinceDays = 7,
        [string] $TrailerPattern = $script:AgentTrailerPattern
    )

    $format = '%H' + $script:FieldSeparator + '%P' + $script:FieldSeparator + '%an' + $script:FieldSeparator + '%cI' + $script:FieldSeparator + '%s' + $script:FieldSeparator + '%b' + $script:RecordSeparator
    $gitArgs = @('log', '--reverse', "--format=$format", "--since=$SinceDays days ago")
    $raw = (Invoke-Git -RepoPath $RepoPath -GitArgs $gitArgs) -join "`n"

    $commits = foreach ($chunk in $raw.Split($script:RecordSeparator)) {
        $trimmed = $chunk.Trim("`n", "`r", ' ')
        if (-not $trimmed) { continue }
        $fields = $trimmed.Split($script:FieldSeparator)
        if ($fields.Count -lt 6) { continue }
        $body = ($fields[5..($fields.Count - 1)] -join [string] $script:FieldSeparator).Trim()
        [pscustomobject]@{
            Sha       = $fields[0].Trim()
            Parents   = @($fields[1].Trim() -split '\s+' | Where-Object { $_ })
            Author    = $fields[2].Trim()
            Date      = [datetime]::Parse($fields[3].Trim(), [cultureinfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::AdjustToUniversal)
            Subject   = $fields[4].Trim()
            Body      = $body
            IsAgent   = ($body -match ('(?im)' + $TrailerPattern))
        }
    }

    return @($commits)
}

function Get-AgentCommits {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [int] $SinceDays = 7,
        [string] $TrailerPattern = $script:AgentTrailerPattern
    )

    return @(Get-Commits -RepoPath $RepoPath -SinceDays $SinceDays -TrailerPattern $TrailerPattern | Where-Object IsAgent)
}

function Get-AgentLineOverlaps {
    <#
    .SYNOPSIS
        For one owner commit: every hunk whose removed lines were written by an agent commit.
    .OUTPUTS
        [pscustomobject] File, AgentSha, Hunk (verbatim diff text)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] $Commit,
        [Parameter(Mandatory)] [hashtable] $AgentShas
    )

    if ($Commit.Parents.Count -ne 1) { return @() }
    $parent = $Commit.Parents[0]
    $files = @(Invoke-Git -RepoPath $RepoPath -GitArgs @('diff-tree', '--no-commit-id', '-r', '--name-only', '--diff-filter=M', $Commit.Sha))

    $overlaps = foreach ($file in $files) {
        $diff = @(Invoke-Git -RepoPath $RepoPath -GitArgs @('show', $Commit.Sha, '--format=', '--unified=0', '--', $file))
        $hunks = Split-Hunks -DiffLines $diff
        foreach ($hunk in $hunks) {
            if ($hunk.OldCount -le 0) { continue }
            $blame = $null
            try {
                $blame = @(Invoke-Git -RepoPath $RepoPath -GitArgs @('blame', '--line-porcelain', '-L', "$($hunk.OldStart),+$($hunk.OldCount)", $parent, '--', $file))
            }
            catch {
                continue
            }

            $agentSha = $null
            foreach ($line in $blame) {
                if ($line -match '^([0-9a-f]{40}) \d+ \d+') {
                    if ($AgentShas.ContainsKey($Matches[1])) { $agentSha = $Matches[1]; break }
                }
            }
            if ($agentSha) {
                [pscustomobject]@{ File = $file; AgentSha = $agentSha; Hunk = ($hunk.Lines -join "`n") }
            }
        }
    }

    return @($overlaps)
}

function Split-Hunks {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyCollection()] [string[]] $DiffLines)

    $hunks = [System.Collections.Generic.List[object]]::new()
    $current = $null
    foreach ($line in $DiffLines) {
        if ($line -match '^@@ -(\d+)(?:,(\d+))? \+(\d+)(?:,(\d+))? @@') {
            $current = [pscustomobject]@{
                OldStart = [int] $Matches[1]
                OldCount = if ($Matches[2]) { [int] $Matches[2] } else { 1 }
                Lines    = [System.Collections.Generic.List[string]]::new()
            }
            $current.Lines.Add($line)
            $hunks.Add($current)
        }
        elseif ($current -and ($line.StartsWith('+') -or $line.StartsWith('-') -or $line.StartsWith('\'))) {
            $current.Lines.Add($line)
        }
    }

    return $hunks.ToArray()
}

function New-Signal {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Signal,
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Value,
        [string] $Reason,
        [Parameter(Mandatory)] [string] $Ref,
        [hashtable] $Extra = @{},
        [Parameter(Mandatory)] [string] $Key
    )

    [pscustomobject]@{ Signal = $Signal; Value = $Value; Reason = $Reason; Ref = $Ref; Extra = $Extra; Key = $Key }
}

function Get-CodeCorrections {
    <#
    .SYNOPSIS
        code-correction for owner hunks over agent lines; code-revert for `git revert` of an agent commit.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [int] $SinceDays = 7,
        [string] $TrailerPattern = $script:AgentTrailerPattern
    )

    $commits = @(Get-Commits -RepoPath $RepoPath -SinceDays $SinceDays -TrailerPattern $TrailerPattern)
    $agentShas = @{}
    foreach ($c in $commits | Where-Object IsAgent) { $agentShas[$c.Sha] = $c }
    if ($agentShas.Count -eq 0) { return @() }

    $signals = foreach ($commit in $commits | Where-Object { -not $_.IsAgent }) {
        $reverted = Get-RevertedSha -Commit $commit
        if ($reverted -and $agentShas.ContainsKey($reverted)) {
            New-Signal -Signal 'code-revert' -Value $commit.Subject -Reason 'owner reverted an agent commit' -Ref $reverted -Key "code-revert:$($commit.Sha)" -Extra @{
                owner_commit = $commit.Sha
                weight       = 2
            }
            continue
        }

        foreach ($overlap in Get-AgentLineOverlaps -RepoPath $RepoPath -Commit $commit -AgentShas $agentShas) {
            New-Signal -Signal 'code-correction' -Value $overlap.Hunk -Reason $commit.Subject -Ref $overlap.AgentSha -Key "code-correction:$($commit.Sha):$($overlap.File):$($overlap.Hunk.GetHashCode())" -Extra @{
                owner_commit = $commit.Sha
                file         = $overlap.File
                weight       = 1
            }
        }
    }

    return @($signals)
}

function Get-BugAttributions {
    <#
    .SYNOPSIS
        bug-attribution for owner commits of type `fix` whose hunks touch agent lines.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [int] $SinceDays = 7,
        [string] $TrailerPattern = $script:AgentTrailerPattern
    )

    $commits = @(Get-Commits -RepoPath $RepoPath -SinceDays $SinceDays -TrailerPattern $TrailerPattern)
    $agentShas = @{}
    foreach ($c in $commits | Where-Object IsAgent) { $agentShas[$c.Sha] = $c }
    if ($agentShas.Count -eq 0) { return @() }

    $signals = foreach ($commit in $commits | Where-Object { -not $_.IsAgent -and $_.Subject -match '^fix(\(|:|!)' }) {
        $overlaps = @(Get-AgentLineOverlaps -RepoPath $RepoPath -Commit $commit -AgentShas $agentShas)
        foreach ($agentSha in ($overlaps | ForEach-Object AgentSha | Sort-Object -Unique)) {
            $files = @($overlaps | Where-Object AgentSha -EQ $agentSha | ForEach-Object File | Sort-Object -Unique)
            New-Signal -Signal 'bug-attribution' -Value $commit.Subject -Reason 'fix commit touched agent-written lines' -Ref $agentSha -Key "bug-attribution:$($commit.Sha):$agentSha" -Extra @{
                owner_commit = $commit.Sha
                files        = $files
                weight       = 1
            }
        }
    }

    return @($signals)
}

function Get-DiffSurvival {
    <#
    .SYNOPSIS
        For each agent commit at least MinAgeDays old: fraction of the lines it added that HEAD still attributes to it.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [int] $MinAgeDays = 7,
        [int] $WindowDays = 60,
        [string] $TrailerPattern = $script:AgentTrailerPattern
    )

    $cutoff = [datetime]::UtcNow.AddDays(-$MinAgeDays)
    $agents = @(Get-AgentCommits -RepoPath $RepoPath -SinceDays $WindowDays -TrailerPattern $TrailerPattern | Where-Object { $_.Date -le $cutoff })

    $signals = foreach ($commit in $agents) {
        $added = 0
        $numstat = @(Invoke-Git -RepoPath $RepoPath -GitArgs @('show', '--format=', '--numstat', $commit.Sha))
        $files = foreach ($line in $numstat) {
            if ($line -match '^(\d+|-)\t(\d+|-)\t(.+)$') {
                if ($Matches[1] -ne '-') { $added += [int] $Matches[1] }
                $Matches[3]
            }
        }

        $surviving = 0
        foreach ($file in @($files)) {
            try {
                $blame = @(Invoke-Git -RepoPath $RepoPath -GitArgs @('blame', '--line-porcelain', 'HEAD', '--', $file))
            }
            catch {
                continue
            }
            foreach ($line in $blame) {
                if ($line -match '^([0-9a-f]{40}) \d+ \d+' -and $Matches[1] -eq $commit.Sha) { $surviving++ }
            }
        }

        if ($added -le 0) { continue }
        $fraction = [math]::Round($surviving / $added, 3)
        New-Signal -Signal 'diff-survival' -Value ($fraction.ToString([cultureinfo]::InvariantCulture)) -Reason "$surviving of $added added lines still in HEAD after $MinAgeDays day(s)" -Ref $commit.Sha -Key "diff-survival:$($commit.Sha)" -Extra @{
            added     = $added
            surviving = $surviving
            weight    = 1
        }
    }

    return @($signals)
}

function Get-CommitMarkers {
    <#
    .SYNOPSIS
        #agent-good and #agent-bad: <reason> markers in commit messages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [int] $SinceDays = 7
    )

    $signals = foreach ($commit in Get-Commits -RepoPath $RepoPath -SinceDays $SinceDays) {
        $message = ($commit.Subject + "`n" + $commit.Body)
        if ($message -match '(?im)#agent-bad(?::\s*(.*))?$') {
            $reason = if ($Matches.Count -gt 1 -and $Matches[1]) { $Matches[1].Trim() } else { '' }
            New-Signal -Signal 'commit-marker' -Value 'bad' -Reason $reason -Ref $commit.Sha -Key "commit-marker:$($commit.Sha)" -Extra @{ weight = 2 }
        }
        elseif ($message -match '(?im)#agent-good\b') {
            New-Signal -Signal 'commit-marker' -Value 'good' -Reason $commit.Subject -Ref $commit.Sha -Key "commit-marker:$($commit.Sha)" -Extra @{ weight = 1 }
        }
    }

    return @($signals)
}

function Get-GenerationReverts {
    <#
    .SYNOPSIS
        `Revert "gen(N): ..."` commits.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [int] $SinceDays = 7
    )

    $signals = foreach ($commit in Get-Commits -RepoPath $RepoPath -SinceDays $SinceDays) {
        if ($commit.Subject -match '^Revert "gen\((\d+)\)') {
            New-Signal -Signal 'generation-revert' -Value "gen/$($Matches[1])" -Reason $commit.Subject -Ref $commit.Sha -Key "generation-revert:$($commit.Sha)" -Extra @{
                reverted_commit = (Get-RevertedSha -Commit $commit)
                weight          = 2
            }
        }
    }

    return @($signals)
}

function Invoke-GitSignals {
    <#
    .SYNOPSIS
        Computes every git signal and writes the ones not yet recorded. Idempotent via evolution/.state/git-cursor.json.
    .OUTPUTS
        [int] number of records written
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoRoot,
        [string] $RepoPath = $RepoRoot,
        [int] $SinceDays = 7,
        [int] $MinSurvivalAgeDays = 7,
        [string] $TrailerPattern = $script:AgentTrailerPattern
    )

    if (-not (Test-GitRepository -RepoPath $RepoPath)) { return 0 }

    $cursorPath = Join-Path $RepoRoot 'evolution/.state/git-cursor.json'
    $done = @{}
    if (Test-Path -LiteralPath $cursorPath) {
        foreach ($key in @((Get-Content -LiteralPath $cursorPath -Raw | ConvertFrom-Json).written)) { $done[[string] $key] = $true }
    }

    $signals = @()
    $signals += @(Get-CodeCorrections -RepoPath $RepoPath -SinceDays $SinceDays -TrailerPattern $TrailerPattern)
    $signals += @(Get-BugAttributions -RepoPath $RepoPath -SinceDays $SinceDays -TrailerPattern $TrailerPattern)
    $signals += @(Get-CommitMarkers -RepoPath $RepoPath -SinceDays $SinceDays)
    $signals += @(Get-GenerationReverts -RepoPath $RepoPath -SinceDays $SinceDays)
    $signals += @(Get-DiffSurvival -RepoPath $RepoPath -MinAgeDays $MinSurvivalAgeDays -TrailerPattern $TrailerPattern)

    $written = 0
    foreach ($signal in $signals) {
        if ($done.ContainsKey($signal.Key)) { continue }
        $params = @{
            RepoRoot  = $RepoRoot
            SessionId = 'git'
            Signal    = $signal.Signal
            Value     = $signal.Value
            Ref       = $signal.Ref
            Extra     = $signal.Extra
        }
        if ($signal.Reason) { $params.Reason = $signal.Reason }
        Write-FeedbackRecord @params
        $done[$signal.Key] = $true
        $written++
    }

    $stateDir = Split-Path $cursorPath -Parent
    if (-not (Test-Path -LiteralPath $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
    [ordered]@{ updated = [datetime]::UtcNow.ToString('o'); written = @($done.Keys | Sort-Object) } | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $cursorPath -Encoding utf8

    return $written
}

function Get-RevertedSha {
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Commit)

    if ($Commit.Body -match 'This reverts commit ([0-9a-f]{40})') { return $Matches[1] }
    return $null
}

Export-ModuleMember -Function Get-Commits, Get-AgentCommits, Get-CodeCorrections, Get-BugAttributions, Get-DiffSurvival, Get-CommitMarkers, Get-GenerationReverts, Invoke-GitSignals
