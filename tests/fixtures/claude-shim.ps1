<#
.SYNOPSIS
    Fake `claude` executable for tests. Accepts the same command line as `claude -p <prompt> ...`
    and answers with canned JSON in the shape of `claude -p --output-format json`.

.DESCRIPTION
    Test-only. The shim labels owner turns by keyword so the production code path (prompt building,
    JSON parsing, record writing) is exercised without a model call. Production code never matches keywords.
    Every invocation is appended to $env:CLAUDE_SHIM_LOG (if set) so tests can assert call counts and flags.
#>
$argList = @($args)

if ($env:CLAUDE_SHIM_LOG) {
    # One line per call, whatever the prompt contains.
    Add-Content -Path $env:CLAUDE_SHIM_LOG -Value (("EVOLUTION_CLASSIFIER=$env:EVOLUTION_CLASSIFIER " + ($argList -join ' ')) -replace "`r?`n", ' ')
}

$prompt = ''
for ($i = 0; $i -lt $argList.Count; $i++) {
    if ($argList[$i] -eq '-p' -and $i + 1 -lt $argList.Count) { $prompt = $argList[$i + 1] }
}

if ($prompt -match 'EVOLVER PROPOSAL') {
    # Evolver mode: write the files from the JSON map in $env:CLAUDE_SHIM_PROPOSAL (relative path -> content)
    # into the current directory (the worktree), like an agent editing the genome in place.
    $written = 0
    if ($env:CLAUDE_SHIM_PROPOSAL -and (Test-Path -LiteralPath $env:CLAUDE_SHIM_PROPOSAL)) {
        $map = Get-Content -LiteralPath $env:CLAUDE_SHIM_PROPOSAL -Raw | ConvertFrom-Json
        foreach ($property in $map.PSObject.Properties) {
            $dest = Join-Path (Get-Location).Path $property.Name
            New-Item -ItemType Directory -Path (Split-Path $dest -Parent) -Force | Out-Null
            [System.IO.File]::WriteAllText($dest, [string] $property.Value, [System.Text.UTF8Encoding]::new($false))
            $written++
        }
    }
    [ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = "shim proposal: $written file(s) written" } | ConvertTo-Json -Compress
    exit 0
}

if ($prompt -notmatch '(?m)^\[\d+\] OWNER: ') {
    # Regression mode: answer from the JSON map in $env:CLAUDE_SHIM_ANSWERS (key = substring of the prompt).
    # A value "EDIT:<relative file>|<text>" inserts <text> before the file's last closing brace in the current
    # directory (the worktree) to imitate an agent that edits code, and answers "edited".
    $answer = 'no answer'
    if ($env:CLAUDE_SHIM_ANSWERS -and (Test-Path -LiteralPath $env:CLAUDE_SHIM_ANSWERS)) {
        $map = Get-Content -LiteralPath $env:CLAUDE_SHIM_ANSWERS -Raw | ConvertFrom-Json
        foreach ($property in $map.PSObject.Properties) {
            if ($prompt.Contains($property.Name)) { $answer = [string] $property.Value; break }
        }
    }
    if ($answer -match '^EDIT:([^|]+)\|(?s)(.*)$') {
        $file = Join-Path (Get-Location).Path $Matches[1]
        $content = [System.IO.File]::ReadAllText($file)
        $index = $content.LastIndexOf('}')
        [System.IO.File]::WriteAllText($file, $content.Substring(0, $index) + $Matches[2] + $content.Substring($index))
        $answer = 'edited'
    }
    [ordered]@{ type = 'result'; subtype = 'success'; is_error = $false; result = $answer } | ConvertTo-Json -Compress
    exit 0
}

$classifications = @()
foreach ($line in ($prompt -split "`n")) {
    if ($line -match '^\[(\d+)\] OWNER: (.*)$') {
        $index = [int] $Matches[1]
        $text = $Matches[2]
        $label = 'none'
        if ($text -match 'already said') { $label = 'frustration' }
        elseif ($text -match '^no,') { $label = 'correction' }
        elseif ($text -match '^exactly') { $label = 'praise' }
        elseif ($text -match 'MEMORY\.md') { $label = 'question' }
        $classifications += [ordered]@{ index = $index; label = $label; reason = "shim: keyword match for '$label'" }
    }
}

$structured = [ordered]@{ classifications = $classifications }
$result = [ordered]@{
    type              = 'result'
    subtype           = 'success'
    is_error          = $false
    result            = ($structured | ConvertTo-Json -Depth 8 -Compress)
    structured_output = $structured
}

$result | ConvertTo-Json -Depth 10 -Compress
exit 0
