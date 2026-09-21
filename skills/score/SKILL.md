---
name: score
description: "Score a genome: run every regression task of this project against a disposable worktree at a ref (HEAD by default) and print Score: n/N. One real model call per task; the owner's checkout is never touched."
argument-hint: "[ref] [-Only T01,T02]"
---
# /evolve:score — run the regression harness

Run from the project root. With a ref (`/evolve:score gen/0`) pass it as `-Ref gen/0`; without one, HEAD is scored:

```powershell
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/regression/Invoke-Regression.ps1" -Ref <ref|HEAD> $ARGUMENTS
```

The tasks come from `evolution/regression/tasks/` (one headless call each, model and tool allow-list from
`evolution/evolve.json`); the run happens in a disposable worktree under the temp folder and removes it
afterwards. Report the output verbatim: one PASS/FAIL line per task, `Score: n/N`, the failed ids, and the
results file under `evolution/.state/regression/`. Uncommitted changes are never scored.

## Never

- Never edit a task to make it pass; never push.
