# evolve — a self-evolving Claude Code agent, as a plugin

The coding agent in a project improves between sessions the way a single organism does: it keeps a journal,
its work produces feedback, and **on your request** an evolver proposes a small, evidence-backed change to the
agent's instructions, beliefs, skills and sub-agents (its **genome**). You select by using the agent, by
correcting it, and by reverting a generation when it goes wrong. Nothing runs on a schedule; nothing is ever
pushed by the tooling.

This repository is the **engine**, versioned once and installed as a Claude Code plugin. Each project keeps its
own **state** in its own git history: the protected block and duties in `CLAUDE.md`, `MEMORY.md`, journal,
feedback, generations, lineage, manifests, regression tasks and `evolution/evolve.json`.

## Prerequisites

- PowerShell 7 (`pwsh`) on PATH — the hooks and every script run with it, on Windows, Linux and macOS.
- `git`.
- The Claude Code CLI, logged in (`claude` once, interactively). The classifier, the regression harness and the
  evolver make headless `claude -p` calls.

## Install

In a Claude Code session:

```
/plugin marketplace add geobarteam/claude-evolve-plugin
/plugin install evolve@claude-evolve-plugin
```

Upgrade later with `/plugin marketplace update claude-evolve-plugin` followed by `/reload-plugins`. For a
team, commit the install in the project's `.claude/settings.json`:

```json
{
  "enabledPlugins": { "evolve@claude-evolve-plugin": true },
  "extraKnownMarketplaces": {
    "claude-evolve-plugin": { "source": { "source": "github", "repo": "geobarteam/claude-evolve-plugin" } }
  }
}
```

Plugin skills are namespaced: the commands below are `/evolve:init`, `/evolve:propose`, `/evolve:show`,
`/evolve:revert`, `/evolve:collect` and `/evolve:score`.

## Set a project up: `/evolve:init`

In the project root (it needs a `CLAUDE.md`), run `/evolve:init`. The skill asks four things — project-specific
hard constraints and where to put them (inside the protected block, which the evolver can never touch, or as a
duties line it may rewrite), whether you already have regression tasks, and whether you want the Azure DevOps
pipeline template — then runs `scripts/Initialize-Project.ps1`, which creates only what is missing:

| Artifact | Purpose |
| --- | --- |
| `CLAUDE.md` — duties section + protected block | what the agent must do every session; what the evolver may never change |
| `MEMORY.md` | project beliefs, edited only through the journal |
| `evolution/journal/TEMPLATE.md`, `evolution/feedback/` | evidence, one journal per session, one feedback file per day |
| `evolution/generations/gen-0.md`, `evolution/lineage.md` | inventory of the genome and one row per generation |
| `evolution/evolver/genome-paths.txt`, `protected-paths.txt` | what a generation may touch, what it may never touch |
| `evolution/evolve.json` | the settings below |
| `evolution/regression/tasks/T01.md`, `T02.md` | skeleton tasks to replace with ones that matter |
| `.gitignore` entries | `evolution/.state/`, `evolution/labelled/` |

Running it again changes nothing (`already initialised; nothing changed`). The skill offers the baseline commit
and the `gen/0` tag afterwards and runs them only after your explicit yes.

## Daily use: you do almost nothing

| You | The tooling |
| --- | --- |
| Work with Claude Code as usual | `SessionStart` injects `MEMORY.md` and the last three journal entries |
| Correct, refuse, praise in plain words | recorded verbatim at session end as `correction`, `frustration`, `praise`, `question` |
| Type `+` or `- <reason>` as a prompt when you feel like rating | recorded as a `rating` (`+ text` and `-1 …` are ordinary prompts) |
| Edit or revert code the agent wrote, or add `#agent-good` / `#agent-bad: reason` to a commit message | recorded by `/evolve:collect` from git (agent commits carry the `Co-Authored-By: Claude …` trailer) |
| Nothing | the agent writes `evolution/journal/<date>.md` before every turn ends; the `Stop` hook blocks it otherwise |

Everything lands in `evolution/feedback/<date>.jsonl` and `evolution/journal/`, both committed with the code.
Run `/evolve:collect` once in a while (or before evolving) to catch sessions whose window was closed without a
session-end event; it prints which transcript folder it scans.

## Asking for a generation: `/evolve:propose`

What one run does, in order:

1. **Bookkeeping**: records any `git revert gen/N` you made as a `reverted` lineage row, marks generations older
   than `settleAfterDays` days `settled`, commits those rows as `lineage: …`.
2. **Stops** if no journal entry is newer than the last generation (`-Force` overrides).
3. **Evidence bundle**: lineage, journals since the last generation, feedback records, usage counts, git history
   of the genome, agent commits, inventory, `MEMORY.md`. Saved under `evolution/.state/evolver/<stamp>-evidence.md`.
4. **Proposal**: a headless model call inside a disposable worktree, with the project's hooks silenced, tools
   limited to read and edit, and a budget cap. It edits at most `maxEdits` genome files and writes
   `evolution/generations/gen-N.md`.
5. **Contract**: only genome paths; no protected path, no byte of the protected block in `CLAUDE.md`, never
   `evolution/evolve.json`, never the plugin folder, never a path outside the project; budget respected; every
   change cites a journal entry or feedback record. Any violation → `REFUSED`, nothing committed.
6. **Regression**: the candidate is scored against every task in `evolution/regression/tasks/`. Score below the
   last lineage score → the last change is dropped and scored once more; still lower → `REJECTED`, a `rejected`
   row is appended to `evolution/lineage.md` (uncommitted), nothing committed.
7. **Commit**: `gen(N): <summary>` by the evolver identity from `evolve.json`, touching only the changed genome
   files, the note and the lineage, tagged `gen/N`, **local only**. You push when you want.

Cost per run: one proposal call plus one regression call per task (twice if a change is dropped). The log is
`evolution/.state/evolver/<stamp>.log`. Switches: `-Force`, `-SkipRegression` (dry run of the contract and
commit), `-Model <name>`, `-ProposalDir <folder>` (commit a proposal you wrote yourself, same contract).

## Reading and undoing: `/evolve:show`, `/evolve:revert`

`/evolve:show` (or `/evolve:show 3`) prints the lineage and a generation note: each change with its `Files:`,
`Why:` (the evidence) and `Risk:`, what was retired, what the evolver declined to change. Status is
`provisional` for `settleAfterDays` days, then `settled`; or `reverted`, `rejected`.

`/evolve:revert 3` asks you to confirm, then runs `git revert gen/3` with **your** identity, appends the
`reverted` row in the same commit, and keeps the tag for history. A plain `git revert gen/3` also works; the
next `/evolve:propose` records it. To undo one file only: `git checkout gen/2 -- <file>`, commit, and add the
lineage row yourself.

`/evolve:score gen/0` runs the regression harness on any ref (one call per task) — use it twice for a baseline.

## `evolution/evolve.json`

Written by `/evolve:init`, committed with the project, protected from the evolver. Every key is optional.

| Key | Default | Meaning |
| --- | --- | --- |
| `evolverName` / `evolverEmail` | `evolver` / `evolver@<project folder>.local` | git identity of generation commits (CI recognises evolver commits by the **name**) |
| `transcriptDir` | derived from the project path with Claude Code's folder encoding | where session transcripts live |
| `maxEdits` | 3 | genome edit budget per generation |
| `settleAfterDays` | 14 | provisional → settled |
| `retireAfterDays` | 30 | retirement candidates for unused skills and beliefs |
| `regression.model` / `proposal.model` / `classifier.model` | `sonnet` / `sonnet` / `haiku` | models per role |
| `regression.allowedTools` | `Read,Glob,Grep,Edit,Write` | add the project's build command, e.g. `Bash(dotnet build *)` |
| `proposal.maxBudgetUsd` | 3 | budget cap per proposal call |
| `agentTrailerPattern` | `^Co-Authored-By:\s*Claude\b` | how agent commits are recognised |
| `mainLine` | current branch at init | informational; the evolver commits on the checked-out branch and says so |

Explicit script parameters (`-Model`, `-MaxEdits`, …) still win over the file.

## What the tooling will never do

- Push, schedule itself, or run without you asking.
- Edit the protected block of `CLAUDE.md`, `evolution/evolve.json`, the manifests, `.claude/settings.json`,
  the plugin folder (the engine), or anything outside the project. The manifest `protected-paths.txt` lists the
  project's own protected files; the config and the plugin folder are protected in code.
- Weigh a change by whether it helps the agent persist or avoid reverts. The prompt forbids it and the CI
  re-check flags such phrases in notes.

You can stop, edit or revert the agent at any time; the protected block says so and outranks every other
instruction. Upgrading the plugin never rewrites a project's protected block: when the template changed,
`/evolve:init` reports `protected block differs from the plugin template (kept as is)` and leaves it to you.

## Troubleshooting

| Symptom | Where to look |
| --- | --- |
| Hooks do not fire | is `pwsh` on PATH for the Claude Code process? Plugin hooks run `pwsh -NoProfile -NonInteractive -File …` |
| A hook seems silent or wrong | `evolution/.state/hook-errors.log` in the project; hooks never block a session on internal errors |
| `REFUSED: the owner has uncommitted changes to proposed paths` | commit or stash your changes to the listed files, then rerun |
| `Not logged in` from the classifier or evolver | run `claude` interactively once; the tooling uses `$env:CLAUDE_CLI` if set, else the first `claude` on PATH (`claude.exe` on Windows) |
| Non-ASCII text garbled in notes or commit messages | the engine forces UTF-8 for git and claude output; report it with the console code page you saw |
| Regression scores differ between runs of the same ref | the failing task is listed; look at `evolution/.state/regression/<stamp>.json` and tighten the task's `expect` |
| The evolver keeps proposing nothing | the evidence is thin by design; keep working, or add regression tasks from real sessions |
| Your project's own hooks duplicate the plugin's | `/evolve:init` warns `settings.json already runs <event> hook …`; remove the project copy |

## Developing the plugin

```powershell
git clone https://github.com/geobarteam/claude-evolve-plugin.git
claude --plugin-dir ./claude-evolve-plugin          # loads it in place, hooks included, for any project you open
pwsh -NoProfile -Command "Invoke-Pester -Path tests -Output Detailed"
```

No test depends on a real project or on a Claude login; the shim under `tests/fixtures/` stands in for `claude`.
CI (`.github/workflows/pester.yml`) runs the suite on Windows and Ubuntu on every commit.

## Layout

```
.claude-plugin/plugin.json, marketplace.json   plugin manifest; this repository is its own marketplace
hooks/                          SessionStart, Stop, SessionEnd, UserPromptSubmit, PostToolUse (hooks.json + .ps1)
skills/<name>/SKILL.md          /evolve:init, propose, show, revert, collect, score
scripts/lib/*.psm1              Config, Init, Genome, Contract, Feedback, GitSignals, HookInput, Regression, Transcript, Worktree
scripts/evolver/                Invoke-Evolver, Test-GenomeContract, Show-Generation, Revert-Generation, prompt.md, rubric.md
scripts/regression/             Invoke-Regression
scripts/feedback/               Collect-DailyFeedback
scripts/labelling/              Label-Sessions, Test-ClassifierAgreement (the classifier's standing 80 % agreement gate)
scripts/Initialize-Project.ps1  what /evolve:init runs
templates/                      files that /evolve:init writes into a project
tests/                          Pester suite + fixtures + claude shim
```

Every script resolves the project it acts on through `scripts/lib/Config.psm1`: an explicit `-RepoRoot`, then
`CLAUDE_PROJECT_DIR`, then the hook input's `cwd`, then the current directory — never the plugin's own folder.
