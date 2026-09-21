---
name: propose
description: "Ask the evolver for one generation of genome changes: at most maxEdits evidence-backed edits (evolve.json), contract-checked and regression-scored, committed locally as gen/N by the evolver identity, never pushed. Owner-triggered only; nothing is scheduled."
argument-hint: "[-Force] [-SkipRegression] [-Model <name>]"
---
# /evolve:propose — ask for one generation

This skill is **protected**: it never edits genome files itself and never pushes. It launches the evolver
runner from the plugin and reports what happened. Run it from the project root.

## Steps

1. Run the runner, passing through any arguments the owner gave:

   ```powershell
   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/evolver/Invoke-Evolver.ps1" $ARGUMENTS
   ```

   It takes a few minutes: one model call for the proposal plus one regression run over every task in
   `evolution/regression/tasks/` (two runs if a change is dropped and retried). Do not run anything else meanwhile.

2. Report the outcome verbatim, whichever it is:
   - **COMMITTED gen/N** — read `evolution/generations/gen-N.md` and show the note (summary, score, every
     `Change k:` with its `Why:`, `Retired`, `Declined to change`). Remind the owner that the commit is local and
     provisional for `settleAfterDays` days; `git revert gen/N` is the emergency exit, and the next run records
     reverts in the lineage.
   - **REJECTED** — show the score line and the `rejected` row appended to `evolution/lineage.md`
     (uncommitted; the owner decides whether to keep it).
   - **REFUSED** — show every `VIOLATION:` line or the uncommitted-path list. A refusal is the contract working,
     not a bug to route around.
   - **nothing to evolve** — say so; the owner can pass `-Force`.

3. Point at the log: `evolution/.state/evolver/<stamp>.log` and the evidence bundle beside it.

## Never

- Never edit `CLAUDE.md`, `MEMORY.md`, skills, agents, `evolution/evolve.json` or anything under `evolution/`
  from this skill; the runner is the only writer of a generation.
- Never push, never delete tags, never re-run to "get a better score".
- Never call the runner from a hook, a loop or a schedule.
