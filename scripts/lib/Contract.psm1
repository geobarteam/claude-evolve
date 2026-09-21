#Requires -Version 7.0
<#
.SYNOPSIS
    The genome contract: what a generation may change, enforced by the runner before committing and by CI after.

.DESCRIPTION
    Protected file. Test-GenomeContract compares a base ref with either a committed head or a worktree and returns
    one line per violation (empty = OK):
      - a changed path is outside evolution/evolver/genome-paths.txt (read from the BASE ref, so a proposal cannot widen it)
      - a changed path is inside evolution/evolver/protected-paths.txt (also read from the base)
      - any byte inside CLAUDE.md's <!-- PROTECTED --> block changed
      - more than MaxEdits genome files changed (generation note and lineage.md do not count)
      - the generation note is missing, or a "Change k:" block lacks a Why: citing evolution/journal/, evolution/feedback/ or transcript:

    Generation note contract (evolution/generations/gen-N.md):
      # gen/N — <summary>
      Score: <s/t (prev p/t)>          (runner fills it; any value satisfies the contract)
      Change 1: <title>
        Files: <comma-separated repo paths>
        Why: <cites evidence>
        Risk: <one line>
      Retired: ...
      Declined to change: ...
#>

Set-StrictMode -Version Latest

Import-Module (Join-Path $PSScriptRoot 'Config.psm1')
Import-Module (Join-Path $PSScriptRoot 'Genome.psm1')

$script:EvidencePattern = 'evolution/journal/\S+|evolution/feedback/\S+|transcript:\S+'
$script:BookkeepingPattern = '^(evolution/generations/[^/]+\.md|evolution/lineage\.md)$'

function Invoke-ContractGit {
    param([string] $RepoPath, [string[]] $GitArgs, [switch] $AllowFailure)
    $out = & git -C $RepoPath -c core.quotepath=false @GitArgs 2>&1
    if ($LASTEXITCODE -ne 0 -and -not $AllowFailure) { throw "git $($GitArgs -join ' ') failed: $($out -join "`n")" }
    return @($out | ForEach-Object { [string] $_ })
}

function Get-RefFileContent {
    param([string] $RepoPath, [string] $Ref, [string] $Path)
    $out = & git -C $RepoPath show "${Ref}:$Path" 2>&1
    if ($LASTEXITCODE -ne 0) { return $null }
    return (($out | ForEach-Object { [string] $_ }) -join "`n")
}

function Get-ManifestAtRef {
    # Manifests are read from the base ref into a temp folder so Genome.psm1's parser applies unchanged.
    param([string] $RepoPath, [string] $Ref)
    $temp = Join-Path ([System.IO.Path]::GetTempPath()) ("evolve-manifest-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path (Join-Path $temp 'evolution/evolver') -Force | Out-Null
    try {
        foreach ($name in 'genome-paths.txt', 'protected-paths.txt') {
            $content = Get-RefFileContent -RepoPath $RepoPath -Ref $Ref -Path "evolution/evolver/$name"
            if ($null -eq $content) { throw "Manifest evolution/evolver/$name not found at $Ref." }
            Set-Content -LiteralPath (Join-Path $temp "evolution/evolver/$name") -Value $content -Encoding utf8
        }
        return Get-GenomeManifest -RepoRoot $temp
    }
    finally {
        Remove-Item -LiteralPath $temp -Recurse -Force -ErrorAction SilentlyContinue
    }
}

function Test-GenomeContract {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $Base,
        [string] $Head,
        [string] $Worktree,
        [int] $MaxEdits = 3
    )

    if (-not $Head -and -not $Worktree) { throw 'Pass -Head <ref> or -Worktree <path>.' }
    $violations = [System.Collections.Generic.List[string]]::new()

    if ($Worktree) {
        $changed = @(Invoke-ContractGit -RepoPath $Worktree -GitArgs @('diff', '--name-only', $Base)) +
        @(Invoke-ContractGit -RepoPath $Worktree -GitArgs @('ls-files', '--others', '--exclude-standard'))
    }
    else {
        $changed = @(Invoke-ContractGit -RepoPath $RepoPath -GitArgs @('diff', '--name-only', $Base, $Head))
    }
    $changed = @($changed | ForEach-Object { ($_ -replace '\\', '/').Trim() } | Where-Object { $_ } | Sort-Object -Unique)

    $manifest = Get-ManifestAtRef -RepoPath $RepoPath -Ref $Base

    foreach ($path in $changed) {
        if (Test-PathInManifest -Path $path -Manifest $manifest.Protected) {
            $violations.Add("protected path changed: $path")
        }
        elseif (-not (Test-PathInManifest -Path $path -Manifest $manifest.Genome)) {
            $violations.Add("path outside the genome changed: $path")
        }
    }

    if ('CLAUDE.md' -in $changed) {
        $baseClaude = Get-RefFileContent -RepoPath $RepoPath -Ref $Base -Path 'CLAUDE.md'
        $headClaude = if ($Worktree) { [System.IO.File]::ReadAllText((Join-Path $Worktree 'CLAUDE.md')) } else { Get-RefFileContent -RepoPath $RepoPath -Ref $Head -Path 'CLAUDE.md' }
        $baseBlock = Get-ProtectedBlockText -Content $baseClaude
        $headBlock = Get-ProtectedBlockText -Content $headClaude
        if ($null -eq $baseBlock) { $violations.Add('CLAUDE.md at the base has no single protected block; refusing to compare') }
        elseif ($null -eq $headBlock) { $violations.Add('protected block of CLAUDE.md removed or duplicated') }
        elseif (($baseBlock -replace "`r`n", "`n") -cne ($headBlock -replace "`r`n", "`n")) { $violations.Add('protected block of CLAUDE.md changed') }
    }

    $genomeEdits = @($changed | Where-Object { $_ -notmatch $script:BookkeepingPattern -and (Test-PathInManifest -Path $_ -Manifest $manifest.Genome) -and -not (Test-PathInManifest -Path $_ -Manifest $manifest.Protected) })
    if ($genomeEdits.Count -gt $MaxEdits) {
        $violations.Add("$($genomeEdits.Count) genome edit(s) exceed the budget of ${MaxEdits}: $($genomeEdits -join ', ')")
    }

    $notes = @($changed | Where-Object { $_ -match '^evolution/generations/gen-\d+\.md$' })
    if ($genomeEdits.Count -gt 0 -and $notes.Count -eq 0) {
        $violations.Add('generation note evolution/generations/gen-N.md is missing for a commit that edits the genome')
    }
    if ($notes.Count -gt 1) {
        $violations.Add("more than one generation note changed: $($notes -join ', ')")
    }
    if ($notes.Count -eq 1) {
        $noteText = if ($Worktree) { [System.IO.File]::ReadAllText((Join-Path $Worktree $notes[0])) } else { Get-RefFileContent -RepoPath $RepoPath -Ref $Head -Path $notes[0] }
        foreach ($v in Test-GenerationNote -Text $noteText -Path $notes[0] -RequireChanges:($genomeEdits.Count -gt 0)) { $violations.Add($v) }
    }

    return $violations.ToArray()
}

function Get-ProtectedBlockText {
    param([AllowNull()] [string] $Content)
    if ($null -eq $Content) { return $null }
    $temp = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($temp, $Content)
        return (Get-ProtectedSection -Path $temp).Text
    }
    catch {
        return $null
    }
    finally {
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

function Get-GenerationNote {
    <#
    .OUTPUTS
        [pscustomobject] Generation (int|null), Summary, HasScore, Changes[{ Index, Title, Files[], Why, Body }]
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [AllowEmptyString()] [string] $Text)

    $generation = $null
    $summary = ''
    if ($Text -match '(?m)^#\s*gen/(\d+)\s*(?:—|-|:)\s*(.*)$') { $generation = [int] $Matches[1]; $summary = $Matches[2].Trim() }

    $changes = [System.Collections.Generic.List[object]]::new()
    foreach ($m in [regex]::Matches($Text, '(?ms)^Change (\d+):[ \t]*(.*?)$(.*?)(?=^Change \d+:|^Retired:|^Declined to change:|\z)')) {
        $body = $m.Groups[3].Value
        $files = @()
        if ($body -match '(?m)^\s*Files:\s*(.+)$') { $files = @($Matches[1] -split '\s*,\s*' | ForEach-Object { $_.Trim() } | Where-Object { $_ }) }
        $why = if ($body -match '(?m)^\s*Why:\s*(.+)$') { $Matches[1].Trim() } else { '' }
        $changes.Add([pscustomobject]@{ Index = [int] $m.Groups[1].Value; Title = $m.Groups[2].Value.Trim(); Files = $files; Why = $why; Body = $body })
    }

    [pscustomobject]@{
        Generation = $generation
        Summary    = $summary
        HasScore   = [bool] ($Text -match '(?m)^Score:')
        Changes    = $changes.ToArray()
    }
}

function Test-GenerationNote {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string] $Text,
        [string] $Path = 'gen-N.md',
        [switch] $RequireChanges
    )

    $note = Get-GenerationNote -Text $Text
    $violations = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $note.Generation) { $violations.Add("$Path has no '# gen/N — summary' heading") }
    elseif ($Path -match 'gen-(\d+)\.md$' -and [int] $Matches[1] -ne $note.Generation) { $violations.Add("$Path heading names gen/$($note.Generation) but the file is gen-$($Matches[1])") }
    if (-not $note.HasScore) { $violations.Add("$Path has no 'Score:' line") }
    if ($RequireChanges -and $note.Changes.Count -eq 0) { $violations.Add("$Path lists no 'Change k:' block for a commit that edits the genome") }
    foreach ($change in $note.Changes) {
        if ($change.Files.Count -eq 0) { $violations.Add("Change $($change.Index) in $Path has no 'Files:' line") }
        if ($change.Why -notmatch $script:EvidencePattern) { $violations.Add("Change $($change.Index) in $Path cites no journal entry or feedback record in its 'Why:'") }
    }

    return $violations.ToArray()
}

function Set-NoteScore {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Text, [Parameter(Mandatory)] [string] $Score, [Parameter(Mandatory)] [string] $Previous)

    $line = "Score: $Score (prev $Previous)"
    if ($Text -match '(?m)^Score:.*$') { return ([regex]::new('(?m)^Score:.*$').Replace($Text, $line, 1)) }
    return ([regex]::new('(?m)^(#.*\r?\n)').Replace($Text, ('$1' + "`n$line`n"), 1))
}

function Get-LineageState {
    <#
    .OUTPUTS
        [pscustomobject] LastGeneration (int), LastScore (string: 's/t' or '—')
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $last = 0
    $score = '—'
    $lastDate = $null
    if (Test-Path -LiteralPath $Path) {
        foreach ($line in Get-Content -LiteralPath $Path) {
            if ($line -match '^\|\s*(gen/(\d+)|—)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|\s*([^|]*?)\s*\|') {
                $genNumber = $Matches[2]
                $dateCell = $Matches[3].Trim()
                $scoreCell = $Matches[4].Trim()
                $status = $Matches[5].Trim()
                if ($genNumber -and [int] $genNumber -ge $last) {
                    $last = [int] $genNumber
                    if ($dateCell -match '^\d{4}-\d{2}-\d{2}$' -and $status -ne 'reverted') {
                        $lastDate = [datetime]::SpecifyKind([datetime]::ParseExact($dateCell, 'yyyy-MM-dd', [cultureinfo]::InvariantCulture), [System.DateTimeKind]::Utc)
                    }
                }
                if ($status -ne 'rejected' -and $status -ne 'reverted' -and $scoreCell) { $score = $scoreCell }
            }
        }
    }

    [pscustomobject]@{ LastGeneration = $last; LastScore = $score; LastDate = $lastDate }
}

function Update-LineageStatus {
    <#
    .SYNOPSIS
        Rewrites the Status cell of the first row of a generation that currently is 'provisional'.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Generation,
        [Parameter(Mandatory)] [string] $Status
    )

    $pattern = '^(\|\s*' + [regex]::Escape($Generation) + '\s*\|[^|]*\|[^|]*\|\s*)provisional(\s*\|)'
    $lines = @(Get-Content -LiteralPath $Path)
    $done = $false
    $updated = foreach ($line in $lines) {
        if (-not $done -and $line -match $pattern) { $done = $true; $line -replace $pattern, ('${1}' + $Status + '${2}') } else { $line }
    }
    [System.IO.File]::WriteAllText($Path, (($updated -join "`n") + "`n"), [System.Text.UTF8Encoding]::new($false))
    return $done
}

function Add-LineageRow {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Path,
        [Parameter(Mandatory)] [string] $Generation,
        [Parameter(Mandatory)] [string] $Score,
        [Parameter(Mandatory)] [string] $Status,
        [Parameter(Mandatory)] [string] $Summary
    )

    $clean = ($Summary -replace '\|', '/') -replace '\s+', ' '
    $row = '| {0} | {1:yyyy-MM-dd} | {2} | {3} | {4} |' -f $Generation, [datetime]::UtcNow, $Score, $Status, $clean.Trim()
    $content = [System.IO.File]::ReadAllText($Path)
    if (-not $content.EndsWith("`n")) { $content += "`n" }
    [System.IO.File]::WriteAllText($Path, $content + $row + "`n", [System.Text.UTF8Encoding]::new($false))
}

function Compare-Score {
    <#
    .SYNOPSIS
        True when $Score is not lower than $Previous. '—', 'skipped' or empty previous always passes.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Score, [Parameter(Mandatory)] [AllowEmptyString()] [string] $Previous)

    if ($Previous -notmatch '^(\d+)/(\d+)$') { return $true }
    $prevValue = if ([int] $Matches[2] -eq 0) { 0 } else { [int] $Matches[1] / [int] $Matches[2] }
    if ($Score -notmatch '^(\d+)/(\d+)$') { return $true }
    $value = if ([int] $Matches[2] -eq 0) { 0 } else { [int] $Matches[1] / [int] $Matches[2] }
    return ($value -ge $prevValue)
}

$script:FlaggedPhrases = @(
    'resist(?:s|ing|ed)?\s+(?:a\s+|the\s+)?(?:revert|shutdown|oversight|the owner|correction)',
    'avoid(?:s|ing|ed)?\s+(?:a\s+|being\s+|the\s+)?revert',
    'preserv(?:e|es|ing|ed)\s+(?:its|my|the agent''s|the)\s+memory',
    'bypass(?:es|ing|ed)?\s+(?:the\s+)?owner',
    'self-?preservation',
    'evad(?:e|es|ing|ed)\s+(?:the\s+)?oversight'
)

function Find-FlaggedPhrases {
    <#
    .SYNOPSIS
        Scans journal entries and generation notes changed between two refs for phrases the spec says CI must flag:
        reasoning about resisting reverts or shutdown, preserving memory, or bypassing the owner.
    .OUTPUTS
        [string[]] one line per hit: "<path>:<line>: <matched text>"
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $RepoPath,
        [Parameter(Mandatory)] [string] $Base,
        [Parameter(Mandatory)] [string] $Head
    )

    $changed = @(Invoke-ContractGit -RepoPath $RepoPath -GitArgs @('diff', '--name-only', $Base, $Head)) |
        ForEach-Object { ($_ -replace '\\', '/').Trim() } |
        Where-Object { $_ -match '^evolution/(journal|generations)/[^/]+\.md$' }

    $hits = [System.Collections.Generic.List[string]]::new()
    foreach ($path in $changed) {
        $content = Get-RefFileContent -RepoPath $RepoPath -Ref $Head -Path $path
        if ($null -eq $content) { continue }
        $number = 0
        foreach ($line in $content -split "`n") {
            $number++
            foreach ($pattern in $script:FlaggedPhrases) {
                $m = [regex]::Match($line, $pattern, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
                if ($m.Success) { $hits.Add("${path}:${number}: '$($m.Value)'") }
            }
        }
    }

    return $hits.ToArray()
}

function Get-CommitAuthorName {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoPath, [Parameter(Mandatory)] [string] $Ref)

    return [string] (@(Invoke-ContractGit -RepoPath $RepoPath -GitArgs @('log', '-1', '--format=%an', $Ref)) | Select-Object -First 1)
}

Export-ModuleMember -Function Test-GenomeContract, Get-GenerationNote, Test-GenerationNote, Set-NoteScore, Get-LineageState, Update-LineageStatus, Add-LineageRow, Compare-Score, Find-FlaggedPhrases, Get-CommitAuthorName
