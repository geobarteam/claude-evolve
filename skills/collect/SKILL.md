---
name: collect
description: "Backstop for closed windows: classify every recent session transcript that SessionEnd did not process and record the git signals (owner corrections, reverts, bug attributions, diff survival, commit markers). Idempotent."
argument-hint: "[-Days <n>] [-TranscriptDir <path>]"
---
# /evolve:collect — collect feedback that the hooks missed

Run from the project root:

```powershell
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/feedback/Collect-DailyFeedback.ps1" $ARGUMENTS
```

The first output line, `Transcripts: <folder> (derived|configured)`, names the transcript folder that was
scanned: derived from the project path, or the `transcriptDir` of `evolution/evolve.json`. Report the output
verbatim: how many sessions were processed (one classifier call each, model from `evolve.json`) and how many
git-signal records were written to `evolution/feedback/<date>.jsonl`. A second run writes nothing new.

## Never

- Never edit feedback records by hand; never push.
