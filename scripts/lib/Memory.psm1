#Requires -Version 7.0
<#
.SYNOPSIS
    Short- and long-term memory of the working agent, modelled on a brain rather than a genome.

.DESCRIPTION
    Protected file (plugin engine).
    - memory/short-term.md          working memory: the agent writes it during sessions; injected at session start;
                                    compressed into long-term memory and cleared at every consolidation.
    - memory/long-term.md           index: one line per memory, `- [Title](long-term/<slug>.md) — hook`;
                                    injected at session start (the cue).
    - memory/long-term/<slug>.md    one memory per file, read on demand (the recall). Its frontmatter carries the
                                    counters: since, recalls, last_recalled, strength, idle_cycles.
    Every Read of a topic file is recorded by the PostToolUse hook as a `recall` feedback record. At consolidation
    (`/evolve:propose`) the recalls since the last generation strengthen the memories that were used, the others
    decay, and memories idle for `forgetAfterCycles` cycles whose strength fell below `forgetBelow` are forgotten.
    When the index is over its limit after the model's compression, the weakest memories are forgotten until it fits.
    Both memory files are capped at the limits Claude Code applies to its own memory index: 200 lines or 25 KB.
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:ShortTermPath = 'memory/short-term.md'
$script:LongTermIndexPath = 'memory/long-term.md'
$script:LongTermDir = 'memory/long-term'
$script:IndexLinePattern = '^\s*-\s*\[(?<title>[^\]]+)\]\((?<link>long-term/[^)\s]+\.md)\)\s*(?:—|–|-|:)?\s*(?<hook>.*)$'
$script:CounterKeys = @('since', 'recalls', 'last_recalled', 'strength', 'idle_cycles')
$script:Utf8 = [System.Text.UTF8Encoding]::new($false)

function Get-MemoryLayout {
    <#
    .SYNOPSIS
        The repo-relative memory paths.
    #>
    [CmdletBinding()]
    param()
    [pscustomobject]@{
        ShortTerm     = $script:ShortTermPath
        LongTermIndex = $script:LongTermIndexPath
        LongTermDir   = $script:LongTermDir
    }
}

function Measure-MemoryText {
    <#
    .SYNOPSIS
        Lines and UTF-8 bytes of a memory file's text.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [AllowNull()] [string] $Text)

    if ([string]::IsNullOrEmpty($Text)) { return [pscustomobject]@{ Lines = 0; Bytes = 0 } }
    $lines = @(($Text -replace "`r`n", "`n").TrimEnd("`n") -split "`n").Count
    [pscustomobject]@{ Lines = $lines; Bytes = $script:Utf8.GetByteCount($Text) }
}

function Test-MemoryWithinLimits {
    [CmdletBinding()]
    param([AllowEmptyString()] [AllowNull()] [string] $Text, [Parameter(Mandatory)] $Limits)
    $m = Measure-MemoryText -Text $Text
    return ($m.Lines -le $Limits.MaxLines -and $m.Bytes -le $Limits.MaxBytes)
}

function Limit-MemoryText {
    <#
    .SYNOPSIS
        The text cut to the limits (whole lines), and whether it was cut. Used when injecting memory at session start.
    #>
    [CmdletBinding()]
    param([AllowEmptyString()] [string] $Text, [Parameter(Mandatory)] $Limits)

    $lines = @(($Text -replace "`r`n", "`n") -split "`n")
    $kept = [System.Collections.Generic.List[string]]::new()
    $bytes = 0
    foreach ($line in $lines) {
        $size = $script:Utf8.GetByteCount($line) + 1
        if ($kept.Count -ge $Limits.MaxLines -or ($bytes + $size) -gt $Limits.MaxBytes) {
            return [pscustomobject]@{ Text = ($kept -join "`n"); Truncated = $true }
        }
        $kept.Add($line)
        $bytes += $size
    }
    [pscustomobject]@{ Text = ($kept -join "`n"); Truncated = $false }
}

function Test-ShortTermEmpty {
    <#
    .SYNOPSIS
        True when short-term memory holds no bullet (the template's placeholder does not count).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $path = Join-Path $RepoRoot $script:ShortTermPath
    if (-not (Test-Path -LiteralPath $path)) { return $true }
    $text = [System.IO.File]::ReadAllText($path) -replace '(?s)<!--.*?-->', ''
    return -not ($text -match '(?m)^\s*[-*]\s+\S')
}

function Get-LongTermIndex {
    <#
    .SYNOPSIS
        Index entries of memory/long-term.md: Title, Link (repo-relative topic path), Hook, Line (the raw line).
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot)

    $path = Join-Path $RepoRoot $script:LongTermIndexPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $text = [System.IO.File]::ReadAllText($path) -replace '(?s)<!--.*?-->', ''
    $entries = foreach ($line in $text -split '\r?\n') {
        $m = [regex]::Match($line, $script:IndexLinePattern)
        if ($m.Success) {
            [pscustomobject]@{
                Title = $m.Groups['title'].Value.Trim()
                Link  = "memory/$($m.Groups['link'].Value)"
                Hook  = $m.Groups['hook'].Value.Trim()
                Line  = $line
            }
        }
    }
    return @($entries)
}

function Read-MemoryTopic {
    <#
    .SYNOPSIS
        A topic file split into its frontmatter (ordered dictionary of key: value) and body.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path)

    $text = [System.IO.File]::ReadAllText($Path) -replace "`r`n", "`n"
    $front = [ordered]@{}
    $body = $text
    $m = [regex]::Match($text, '(?s)^---\n(.*?)\n---\n?')
    if ($m.Success) {
        foreach ($line in $m.Groups[1].Value -split "`n") {
            if ($line -match '^([A-Za-z_][A-Za-z0-9_-]*):\s*(.*)$') { $front[$Matches[1]] = $Matches[2].Trim() }
        }
        $body = $text.Substring($m.Length)
    }
    [pscustomobject]@{ Front = $front; Body = $body; HasFrontMatter = $m.Success }
}

function Write-MemoryTopic {
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [System.Collections.IDictionary] $Front, [AllowEmptyString()] [string] $Body)

    $sb = [System.Text.StringBuilder]::new()
    [void] $sb.Append("---`n")
    foreach ($key in $Front.Keys) { [void] $sb.Append("${key}: $($Front[$key])`n") }
    [void] $sb.Append("---`n")
    [void] $sb.Append($Body.TrimStart("`n"))
    if (-not $sb.ToString().EndsWith("`n")) { [void] $sb.Append("`n") }
    [System.IO.File]::WriteAllText($Path, $sb.ToString(), $script:Utf8)
}

function Get-TopicCounters {
    # Counters from a topic's frontmatter with defaults for a memory that has none yet (a new one starts at strength 1).
    param([System.Collections.IDictionary] $Front, [string] $Today)
    $number = {
        param($value, $default)
        $parsed = 0.0
        if ([double]::TryParse([string] $value, [System.Globalization.NumberStyles]::Float, [cultureinfo]::InvariantCulture, [ref] $parsed)) { $parsed } else { $default }
    }
    [pscustomobject]@{
        Since        = if ($Front.Contains('since') -and $Front['since']) { [string] $Front['since'] } else { $Today }
        Recalls      = [int] (& $number $(if ($Front.Contains('recalls')) { $Front['recalls'] }) 0)
        LastRecalled = if ($Front.Contains('last_recalled') -and $Front['last_recalled']) { [string] $Front['last_recalled'] } else { 'never' }
        Strength     = [double] (& $number $(if ($Front.Contains('strength')) { $Front['strength'] }) 1.0)
        IdleCycles   = [int] (& $number $(if ($Front.Contains('idle_cycles')) { $Front['idle_cycles'] }) 0)
    }
}

function Set-TopicCounters {
    param([System.Collections.IDictionary] $Front, $Counters)
    $Front['since'] = $Counters.Since
    $Front['recalls'] = "$($Counters.Recalls)"
    $Front['last_recalled'] = $Counters.LastRecalled
    $Front['strength'] = $Counters.Strength.ToString('0.###', [cultureinfo]::InvariantCulture)
    $Front['idle_cycles'] = "$($Counters.IdleCycles)"
}

function ConvertTo-MemoryRelativePath {
    <#
    .SYNOPSIS
        The repo-relative path of a long-term topic file, or $null when the path is not one.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Path, [Parameter(Mandatory)] [string] $RepoRoot)

    $p = $Path -replace '\\', '/'
    $root = ((Resolve-Path -LiteralPath $RepoRoot).Path -replace '\\', '/').TrimEnd('/')
    if ([System.IO.Path]::IsPathRooted($Path)) {
        if (-not $p.StartsWith("$root/", [System.StringComparison]::OrdinalIgnoreCase)) { return $null }
        $p = $p.Substring($root.Length + 1)
    }
    $p = $p -replace '^\./', ''
    if ($p -match '^memory/long-term/[^/]+\.md$') { return $p }
    return $null
}

function Get-RecallCounts {
    <#
    .SYNOPSIS
        Recalls per topic path from the `recall` feedback records dated on or after -Since.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $RepoRoot, [Parameter(Mandatory)] [datetime] $Since)

    $counts = @{}
    $dir = Join-Path $RepoRoot 'evolution/feedback'
    if (-not (Test-Path -LiteralPath $dir)) { return $counts }
    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.jsonl' -File | Where-Object { $_.BaseName -ge $Since.ToString('yyyy-MM-dd') }) {
        foreach ($line in [System.IO.File]::ReadAllLines($file.FullName)) {
            if ([string]::IsNullOrWhiteSpace($line)) { continue }
            try { $rec = $line | ConvertFrom-Json } catch { continue }
            if ($rec.PSObject.Properties['signal'] -and $rec.signal -eq 'recall') {
                if ($rec.PSObject.Properties['ts'] -and $rec.ts) {
                    try { if (([datetime] $rec.ts).ToUniversalTime() -le $Since.ToUniversalTime()) { continue } } catch { }
                }
                $key = [string] $rec.value
                $counts[$key] = 1 + $(if ($counts.ContainsKey($key)) { $counts[$key] } else { 0 })
            }
        }
    }
    return $counts
}

function Remove-LongTermMemory {
    # Forgets one memory: deletes its topic file and its index line. Returns the removed index title or the path.
    param([string] $Root, [string] $Link)
    $topic = Join-Path $Root $Link
    if (Test-Path -LiteralPath $topic) { Remove-Item -LiteralPath $topic -Force }
    $indexPath = Join-Path $Root $script:LongTermIndexPath
    if (Test-Path -LiteralPath $indexPath) {
        $target = $Link.Substring('memory/'.Length)
        $lines = [System.IO.File]::ReadAllLines($indexPath) | Where-Object {
            $m = [regex]::Match($_, $script:IndexLinePattern)
            -not ($m.Success -and $m.Groups['link'].Value -eq $target)
        }
        [System.IO.File]::WriteAllText($indexPath, ((@($lines) -join "`n").TrimEnd() + "`n"), $script:Utf8)
    }
}

function Invoke-MemoryDecay {
    <#
    .SYNOPSIS
        Step 1 of consolidation, deterministic: counts recalls, strengthens or decays every memory, forgets the idle weak ones.
    .DESCRIPTION
        For each topic under memory/long-term/: strength = strength * decay + recalls this cycle; idle_cycles resets
        on a recall and grows otherwise. A memory idle for ForgetAfterCycles cycles with strength below ForgetBelow is
        forgotten (topic file and index line removed). Works on -Root (the evolver's worktree).
    .OUTPUTS
        [pscustomobject] Recalled (object[] Link, Count, Strength), Forgotten (object[] Link, Reason), Decayed (int)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] [hashtable] $Recalls,
        [Parameter(Mandatory)] $Limits,
        [string] $Today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    )

    $recalled = [System.Collections.Generic.List[object]]::new()
    $forgotten = [System.Collections.Generic.List[object]]::new()
    $decayed = 0
    $dir = Join-Path $Root $script:LongTermDir
    if (-not (Test-Path -LiteralPath $dir)) { return [pscustomobject]@{ Recalled = @(); Forgotten = @(); Decayed = 0 } }

    foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.md' -File | Sort-Object Name) {
        $link = "$script:LongTermDir/$($file.Name)"
        $topic = Read-MemoryTopic -Path $file.FullName
        $c = Get-TopicCounters -Front $topic.Front -Today $Today
        $n = if ($Recalls.ContainsKey($link)) { [int] $Recalls[$link] } else { 0 }
        $c.Strength = [math]::Round($c.Strength * $Limits.Decay + $n, 3)
        if ($n -gt 0) {
            $c.Recalls += $n
            $c.LastRecalled = $Today
            $c.IdleCycles = 0
            $recalled.Add([pscustomobject]@{ Link = $link; Count = $n; Strength = $c.Strength })
        }
        else {
            $c.IdleCycles += 1
            $decayed++
        }

        if ($c.IdleCycles -ge $Limits.ForgetAfterCycles -and $c.Strength -lt $Limits.ForgetBelow) {
            Remove-LongTermMemory -Root $Root -Link $link
            $forgotten.Add([pscustomobject]@{ Link = $link; Reason = "idle for $($c.IdleCycles) cycle(s), strength $($c.Strength.ToString('0.###', [cultureinfo]::InvariantCulture)) < $($Limits.ForgetBelow)" })
            continue
        }
        Set-TopicCounters -Front $topic.Front -Counters $c
        Write-MemoryTopic -Path $file.FullName -Front $topic.Front -Body $topic.Body
    }

    [pscustomobject]@{ Recalled = $recalled.ToArray(); Forgotten = $forgotten.ToArray(); Decayed = $decayed }
}

function Complete-MemoryConsolidation {
    <#
    .SYNOPSIS
        Step 3 of consolidation, deterministic, after the model compressed short-term into long-term memory.
    .DESCRIPTION
        - gives every topic without counters its defaults (a new memory: strength 1, recalls 0, since today);
        - forgets the weakest pre-existing memories (lowest strength, then oldest last recall) while the index is
          over its limit; memories created in this cycle are kept;
        - resets memory/short-term.md to the template: what the model did not carry over is forgotten.
    .OUTPUTS
        [pscustomobject] Forgotten (object[] Link, Reason), New (string[] links)
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Root,
        [Parameter(Mandatory)] $Limits,
        [Parameter(Mandatory)] [string] $ShortTermTemplate,
        [string[]] $ExistingLinks = @(),
        [string] $Today = [datetime]::UtcNow.ToString('yyyy-MM-dd')
    )

    $forgotten = [System.Collections.Generic.List[object]]::new()
    $new = [System.Collections.Generic.List[string]]::new()
    $dir = Join-Path $Root $script:LongTermDir
    $strength = @{}
    $lastRecalled = @{}
    if (Test-Path -LiteralPath $dir) {
        foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.md' -File) {
            $link = "$script:LongTermDir/$($file.Name)"
            $topic = Read-MemoryTopic -Path $file.FullName
            $c = Get-TopicCounters -Front $topic.Front -Today $Today
            if ($link -notin $ExistingLinks) { $new.Add($link) }
            $missing = @($script:CounterKeys | Where-Object { -not $topic.Front.Contains($_) })
            if ($missing.Count -gt 0) {
                Set-TopicCounters -Front $topic.Front -Counters $c
                Write-MemoryTopic -Path $file.FullName -Front $topic.Front -Body $topic.Body
            }
            $strength[$link] = $c.Strength
            $lastRecalled[$link] = $c.LastRecalled
        }
    }

    $indexPath = Join-Path $Root $script:LongTermIndexPath
    while ((Test-Path -LiteralPath $indexPath) -and -not (Test-MemoryWithinLimits -Text ([System.IO.File]::ReadAllText($indexPath)) -Limits $Limits)) {
        $candidates = @(Get-LongTermIndex -RepoRoot $Root | Where-Object { $_.Link -notin $new } |
                Sort-Object @{ Expression = { if ($strength.ContainsKey($_.Link)) { $strength[$_.Link] } else { 0 } } }, @{ Expression = { if ($lastRecalled.ContainsKey($_.Link)) { $lastRecalled[$_.Link] } else { '' } } })
        if ($candidates.Count -eq 0) { break }
        $weakest = $candidates[0]
        Remove-LongTermMemory -Root $Root -Link $weakest.Link
        $forgotten.Add([pscustomobject]@{ Link = $weakest.Link; Reason = 'weakest memory while the index was over its limit' })
    }

    [System.IO.File]::WriteAllText((Join-Path $Root $script:ShortTermPath), $ShortTermTemplate, $script:Utf8)
    [pscustomobject]@{ Forgotten = $forgotten.ToArray(); New = $new.ToArray() }
}

function Test-MemoryShape {
    <#
    .SYNOPSIS
        Contract violations of the memory files under -Root (empty = OK).
    .DESCRIPTION
        Both memory files within their limits; every index line links to an existing topic file; every topic file
        has frontmatter and one index line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)] [string] $Root, [Parameter(Mandatory)] $Limits)

    $violations = [System.Collections.Generic.List[string]]::new()
    foreach ($rel in $script:ShortTermPath, $script:LongTermIndexPath) {
        $path = Join-Path $Root $rel
        if (-not (Test-Path -LiteralPath $path)) { continue }
        $m = Measure-MemoryText -Text ([System.IO.File]::ReadAllText($path))
        if ($m.Lines -gt $Limits.MaxLines -or $m.Bytes -gt $Limits.MaxBytes) {
            $violations.Add("$rel is $($m.Lines) line(s) / $($m.Bytes) byte(s), over the limit of $($Limits.MaxLines) lines / $($Limits.MaxBytes) bytes")
        }
    }

    $links = @(Get-LongTermIndex -RepoRoot $Root | ForEach-Object Link)
    foreach ($link in $links) {
        if (-not (Test-Path -LiteralPath (Join-Path $Root $link))) { $violations.Add("$script:LongTermIndexPath links to a missing memory: $link") }
    }
    foreach ($dup in @($links | Group-Object | Where-Object Count -gt 1)) { $violations.Add("$script:LongTermIndexPath lists $($dup.Name) $($dup.Count) times") }
    $dir = Join-Path $Root $script:LongTermDir
    if (Test-Path -LiteralPath $dir) {
        foreach ($file in Get-ChildItem -LiteralPath $dir -Filter '*.md' -File) {
            $link = "$script:LongTermDir/$($file.Name)"
            if ($link -notin $links) { $violations.Add("memory $link has no line in $script:LongTermIndexPath") }
            if (-not (Read-MemoryTopic -Path $file.FullName).HasFrontMatter) { $violations.Add("memory $link has no frontmatter") }
        }
    }
    return $violations.ToArray()
}

Export-ModuleMember -Function Get-MemoryLayout, Measure-MemoryText, Test-MemoryWithinLimits, Limit-MemoryText, Test-ShortTermEmpty, Get-LongTermIndex, Read-MemoryTopic, Write-MemoryTopic, ConvertTo-MemoryRelativePath, Get-RecallCounts, Invoke-MemoryDecay, Complete-MemoryConsolidation, Test-MemoryShape
