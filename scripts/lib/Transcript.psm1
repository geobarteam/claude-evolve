#Requires -Version 7.0
<#
.SYNOPSIS
    The only place that knows the shape of Claude Code transcript files.

.DESCRIPTION
    Protected file. Claude Code documents the transcript JSONL as internal and subject to change,
    so every reader (hooks, feedback scripts, evolver) goes through this module. If the format changes,
    fix it here and re-run evolution/tests/Transcript.Tests.ps1 against a fresh fixture.

    Observed shape (2026-09-21): one JSON object per line with
      type        : user | assistant | queue-operation | attachment | ... (unknown types are kept as-is)
      uuid, parentUuid, timestamp (ISO 8601 UTC), sessionId, isMeta
      message     : { role, content } where content is a string or an array of blocks
                    block.type : text | thinking | tool_use | tool_result
#>

Set-StrictMode -Version Latest

# Errors inside module functions must surface to the caller's try/catch (hooks log them and exit 0).
$ErrorActionPreference = 'Stop'

function Read-Transcript {
    <#
    .SYNOPSIS
        Reads a transcript JSONL file into objects, skipping lines that are not JSON.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    if (-not (Test-Path -LiteralPath $Path)) {
        return @()
    }

    $records = [System.Collections.Generic.List[object]]::new()
    foreach ($line in [System.IO.File]::ReadLines($Path)) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $records.Add(($line | ConvertFrom-Json -Depth 64))
        }
        catch {
            # Not JSON (or truncated): skip, never fail the caller.
        }
    }

    return $records.ToArray()
}

function Get-UserTurns {
    <#
    .SYNOPSIS
        Returns the owner's prompts: user records that carry text and are neither tool results nor injected meta records.
    .OUTPUTS
        [pscustomobject] Uuid, Timestamp ([datetime] UTC), Text
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Records
    )

    $turns = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $Records) {
        if ((Get-Prop $record 'type') -ne 'user') { continue }
        if ([bool](Get-Prop $record 'isMeta' $false)) { continue }

        $message = Get-Prop $record 'message'
        if ($null -eq $message) { continue }
        $content = Get-Prop $message 'content'

        $text = $null
        if ($content -is [string]) {
            $text = $content
        }
        elseif ($content -is [System.Array]) {
            $blocks = @($content)
            if (@($blocks | Where-Object { (Get-Prop $_ 'type') -eq 'tool_result' }).Count -gt 0) { continue }
            $textBlocks = @($blocks | Where-Object { (Get-Prop $_ 'type') -eq 'text' } | ForEach-Object { Get-Prop $_ 'text' })
            if ($textBlocks.Count -eq 0) { continue }
            $text = ($textBlocks -join "`n")
        }

        if ([string]::IsNullOrWhiteSpace($text)) { continue }

        $turns.Add([pscustomobject]@{
                Uuid      = Get-Prop $record 'uuid'
                Timestamp = ConvertTo-UtcDateTime (Get-Prop $record 'timestamp')
                Text      = $text
            })
    }

    return $turns.ToArray()
}

function Get-AssistantTurns {
    <#
    .SYNOPSIS
        Returns assistant records with their visible text and tool names. Thinking blocks are never extracted.
    .OUTPUTS
        [pscustomobject] Uuid, Timestamp ([datetime] UTC), Text, ToolUses (string[])
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [AllowEmptyCollection()]
        [object[]] $Records
    )

    $turns = [System.Collections.Generic.List[object]]::new()
    foreach ($record in $Records) {
        if ((Get-Prop $record 'type') -ne 'assistant') { continue }

        $message = Get-Prop $record 'message'
        if ($null -eq $message) { continue }
        $content = Get-Prop $message 'content'

        $text = ''
        $toolUses = @()
        if ($content -is [string]) {
            $text = $content
        }
        elseif ($content -is [System.Array]) {
            $blocks = @($content)
            $text = (@($blocks | Where-Object { (Get-Prop $_ 'type') -eq 'text' } | ForEach-Object { Get-Prop $_ 'text' }) -join "`n")
            $toolUses = @($blocks | Where-Object { (Get-Prop $_ 'type') -eq 'tool_use' } | ForEach-Object { Get-Prop $_ 'name' })
        }

        $turns.Add([pscustomobject]@{
                Uuid      = Get-Prop $record 'uuid'
                Timestamp = ConvertTo-UtcDateTime (Get-Prop $record 'timestamp')
                Text      = $text
                ToolUses  = [string[]] $toolUses
            })
    }

    return $turns.ToArray()
}

function Get-LastUserTimestamp {
    <#
    .SYNOPSIS
        UTC timestamp of the owner's last prompt in a transcript, or $null when there is none or the file is missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)]
        [string] $Path
    )

    $records = @(Read-Transcript -Path $Path)
    $turns = @(Get-UserTurns -Records $records)
    if ($turns.Count -eq 0) {
        return $null
    }

    return ($turns | Sort-Object Timestamp | Select-Object -Last 1).Timestamp
}

function Get-Prop {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [AllowNull()] $Object,
        [Parameter(Mandatory)] [string] $Name,
        $Default = $null
    )

    if ($null -eq $Object) { return $Default }
    $property = $Object.PSObject.Properties[$Name]
    if ($null -eq $property) { return $Default }
    # -NoEnumerate keeps a one-element array (e.g. a single content block) an array; scalars must not go
    # through it because this PowerShell version wraps a scalar in an array when -NoEnumerate is used.
    if ($property.Value -is [System.Collections.IList]) {
        Write-Output -NoEnumerate $property.Value
    }
    else {
        return $property.Value
    }
}

function ConvertTo-UtcDateTime {
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [datetime]) { return $Value.ToUniversalTime() }

    $styles = [System.Globalization.DateTimeStyles]::AdjustToUniversal -bor [System.Globalization.DateTimeStyles]::AssumeUniversal
    [datetime] $parsed = [datetime]::MinValue
    if ([datetime]::TryParse([string] $Value, [cultureinfo]::InvariantCulture, $styles, [ref] $parsed)) {
        return [datetime]::SpecifyKind($parsed, [System.DateTimeKind]::Utc)
    }

    return $null
}

Export-ModuleMember -Function Read-Transcript, Get-UserTurns, Get-AssistantTurns, Get-LastUserTimestamp
