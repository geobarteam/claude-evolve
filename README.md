# evolve — a self-evolving Claude Code agent, as a plugin

The engine behind a coding agent that journals every session, collects the owner's feedback, scores its own
genome with a regression harness, and, only when the owner asks, proposes at most three evidence-backed edits to
that genome as a tagged, revertable generation.

This repository is the **engine** (protected, versioned once). Each project keeps its own **state**: `CLAUDE.md`
duties and protected block, `MEMORY.md`, journal, feedback, generations, lineage, manifests, regression tasks and
`evolution/evolve.json`.

## Layout

```
.claude-plugin/plugin.json      plugin manifest (name "evolve")
hooks/                          SessionStart, Stop, SessionEnd, UserPromptSubmit, PostToolUse (hooks.json + .ps1)
scripts/lib/*.psm1              Config, Genome, Contract, Feedback, GitSignals, HookInput, Regression, Transcript, Worktree
scripts/evolver/                Invoke-Evolver, Test-GenomeContract, Show-Generation, Revert-Generation, prompt.md, rubric.md
scripts/regression/             Invoke-Regression
scripts/feedback/               Collect-DailyFeedback
scripts/labelling/              Label-Sessions, Test-ClassifierAgreement
templates/                      files that `/evolve:init` writes into a project
tests/                          Pester suite + fixtures + claude shim
```

## Where the project root comes from

Every script resolves the project it acts on through `scripts/lib/Config.psm1`: an explicit `-RepoRoot`, then
`CLAUDE_PROJECT_DIR`, then the hook input's `cwd`, then the current directory. Never from the plugin's own
location. Run a script from the project's root and it acts on that project.

## Running the tests

```powershell
pwsh -NoProfile -Command "Invoke-Pester -Path tests -Output Detailed"
```

Prerequisites: PowerShell 7+, Pester 5, git. No test depends on a real project or on a Claude login; the
shim under `tests/fixtures/` stands in for `claude`.
