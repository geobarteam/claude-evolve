# Plan: EvolvePlugin — Install the self-evolving agent tooling in any project from one versioned plugin

## Overview

Implement `_specs/self-improvement/EvolvePlugin.md`: package today's engine (five hooks, `evolution/lib/*.psm1`, evolver runner + contract checker + show/revert, regression runner, feedback collector, labelling tools, Pester suite, shim) as a **Claude Code plugin** named `evolve` in its own git repository, add `/evolve init` that scaffolds a project, parameterise the engine through `evolution/evolve.json`, and migrate this repository to consume the plugin (AC-7). Pattern references: `_plans/SelfEvolvingAgent.md` (approved predecessor; same RED convention for script deliverables), the engine files themselves (read across hooks, lib, evolver, regression, feedback, tests), and the installed-plugin shapes under `~/.claude/plugins/cache/claude-plugins-official/` (`plugin.json`, `hooks/hooks.json`, `marketplace.json`).

Path convention in this plan: `../claude-evolve-plugin/<path>` = the plugin repository (sibling clone `D:\Data\gv10141\Repos\Common\claude-evolve-plugin`, same pattern as `Nihdi-Core-Audit`); bare repo-relative paths = this repository.

**Grounded decisions (verified against this machine and repo on 2026-09-21):**

- **Runtime = pwsh 7.6.5 + Pester 5.7.1.** Claude Code CLI 2.1.116 lives at `C:\Users\gv10141\AppData\Local\Microsoft\WinGet\Packages\Anthropic.ClaudeCode_…\claude.exe`; the npm `claude` shims on PATH are broken. `Resolve-ClaudeCommand` in `evolution/lib/Feedback.psm1` already skips them and **is kept** (Step 7 only makes its `.exe` filter Windows-conditional).
- **Plugin repo = marketplace.** `https://github.com/geobarteam/claude-evolve-plugin.git` carries both `.claude-plugin/plugin.json` and `.claude-plugin/marketplace.json`. Plugin name `evolve`, first version `0.1.0`, tag `v0.1.0`. The clone does not exist yet: Step 1 runs `git init -b main` in the sibling folder; the owner creates the GitHub repository and pushes (the agent never pushes). Commits in the plugin repo end with `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`.
- **`${CLAUDE_PLUGIN_ROOT}` is the versioned cache folder** (`~/.claude/plugins/cache/<marketplace>/<plugin>/<version>`), not the clone. The engine therefore never writes under the plugin root (BR-1); all state stays under `<project>/evolution/.state/` and the temp folder (worktrees).
- **Two-repository window.** From Step 1 to Step 7 the engine exists in both places; the plugin copy is the source of truth and the only one edited. This repository keeps its working engine untouched until Step 8 removes it, so nothing breaks in the owner's daily sessions meanwhile. Steps 1–7 touch only `../claude-evolve-plugin/`; Step 8 touches only this repository.
- **What stays project state here after migration:** `CLAUDE.md` (duties section + `<!-- PROTECTED -->` block, lines 26–42 today), `MEMORY.md`, `evolution/journal/`, `evolution/feedback/*.jsonl`, `evolution/generations/gen-0.md`, `evolution/lineage.md`, `evolution/evolver/genome-paths.txt` + `protected-paths.txt` (manifests keep their path; `Genome.psm1 Get-GenomeManifest` is unchanged), `evolution/regression/tasks/*` (T01–T10 + `T05.check.ps1`, kept as-is: they already are this repo's seeds), `azure-pipeline-genome.yml`, plus the new `evolution/evolve.json`. `MEMORY.md ## Beliefs` names no engine path, so nothing there goes stale.
- **Hard-coded repo assumptions removed (grep-verified):** `$PSScriptRoot '..\..'` root default in `Invoke-Evolver.ps1:26`, `Revert-Generation.ps1:16`, `Show-Generation.ps1:8`, `Test-GenomeContract.ps1:25`, `Invoke-Regression.ps1:22`, `Collect-DailyFeedback.ps1:19`, `Test-ClassifierAgreement.ps1:16`, `Label-Sessions.ps1:18`, `ContractRepo.psm1:4`; `-Fallback (Join-Path $PSScriptRoot '..\..')` in all five hooks; hook imports via `..\..\evolution\lib\`; `TranscriptDir` default `$HOME\.claude\projects\d--Data-gv10141-Repos-Common-FindMyDoctor-Wasm` (`Collect-DailyFeedback.ps1:20`, `Test-ClassifierAgreement.ps1:17`); `evolver@findmydoctor.local` (`Invoke-Evolver.ps1:45`); `AllowedTools = 'Read,Glob,Grep,Edit,Write,Bash(dotnet build *)'` (`Invoke-Regression.ps1:27`); `$script:AgentTrailerPattern` (`GitSignals.psm1:25`); rubric read from `$RepoRoot/evolution/evolver/rubric.md` (`Feedback.psm1:278`, `Test-ClassifierAgreement.ps1:33`); labels dir `evolution/tests/labelled` (`Label-Sessions.ps1:35`, `Test-ClassifierAgreement.ps1:26`); worktree prefixes `fmd-*` (`Worktree.psm1`, `Invoke-Regression.ps1`); `Regression.Tests.ps1` asserting ten NIHDI task ids and `src/Presentation/.../IDoctorServiceClient.cs`.
- **Transcript folder derivation (AC-5):** Claude Code encodes the project path by lowercasing the drive letter and replacing `\`, `/`, `:` and `.` with `-`: `D:\Data\gv10141\Repos\Common\FindMyDoctor-Wasm` → `d--Data-gv10141-Repos-Common-FindMyDoctor-Wasm`. `Get-TranscriptDir` derives `$HOME/.claude/projects/<encoded>` unless `evolve.json` sets `transcriptDir`; the rule is pinned by a test against this known pair.
- **Labelled sessions move to project state**: `evolution/labelled/` (gitignored by `init`), replacing `evolution/tests/labelled/` which disappears with the tests. The two labelling scripts live in `../claude-evolve-plugin/scripts/labelling/`.
- **`/evolve init` semantics (BR-2/BR-3/BR-4 reconciled):** per-artifact idempotent. Every artifact (protected block, duties section, `MEMORY.md`, `evolution/` tree, `evolve.json`, `.gitignore` entries) is created only when missing; a present protected block is never appended again (BR-3) but compared with the template (BR-4 message); when nothing was missing the script prints `already initialised; nothing changed`. This is also exactly what the migration in Step 8 needs: `init` on this repo creates only `evolution/evolve.json` and the `.gitignore` entry.
- **Protected-block template (owner answer 4):** `templates/protected-block.md` holds the four generic bullets of today's block (owner override, correctability, no genome edits during a task, rollback rule) plus a generic fifth bullet `Hard constraints: no secrets in committed files; the agent never pushes.` Project constraints given to `init` are placed either **inside the block** as an extra `Hard constraints for this project:` bullet list (`-ConstraintPlacement protected`) or as a **duties line** outside the block (`-ConstraintPlacement duties`); the `/evolve init` chat flow proposes both and the owner chooses. This repo's block already differs from the template (it names `copilot-instructions.md`, the WASM-token rule and the planning gate), so Step 8 expects the BR-4 message and keeps the block byte-identical.
- **Config keys and defaults** are the spec table verbatim: `evolverName` `evolver`, `evolverEmail` `evolver@<project folder name, lower-case>.local`, `transcriptDir` derived, `maxEdits` 3, `settleAfterDays` 14, `retireAfterDays` 30, `regression.model` `sonnet`, `proposal.model` `sonnet`, `classifier.model` `haiku`, `regression.allowedTools` `Read,Glob,Grep,Edit,Write`, `proposal.maxBudgetUsd` 3, `agentTrailerPattern` `^Co-Authored-By:\s*Claude\b`, `mainLine` current branch at init. Explicit script parameters (`-Model`, `-MaxEdits`, …) still override the config, as today. This repo's `evolve.json` (Step 8) sets `evolverEmail: evolver@findmydoctor.local` (unchanged identity), `regression.allowedTools` with `Bash(dotnet build *)`, `mainLine: dev`.
- **`mainLine` is informational**, matching the spec edge case: the runner still commits on the checked-out branch and logs `on branch 'X' (mainLine: Y)`.
- **Claude Code plugin facts (confirmed against the official docs on 2026-09-21: `code.claude.com/docs/en/plugins.md`, `plugins-reference.md`, `plugin-marketplaces.md`, `hooks.md`):** (a) plugin commands are **always namespaced** `/<plugin>:<command>`, so `commands/evolve.md` in plugin `evolve` is invoked as `/evolve:evolve init|show|…` (see decision 6); `$ARGUMENTS` works in plugin command markdown; the docs call `commands/` legacy and recommend `skills/<name>/SKILL.md`, which is namespaced the same way. (b) `${CLAUDE_PLUGIN_ROOT}` is string-substituted in `hooks.json` commands **and** in command/skill markdown, and is exported as a process environment variable to hook commands together with `CLAUDE_PROJECT_DIR` and `CLAUDE_PLUGIN_DATA` (`~/.claude/plugins/data/<plugin-id>/`, survives updates); it is **not** available to Bash tool calls the model runs, so `/evolve` must pass the substituted path into the script call explicitly. No `plugin-root.txt` fallback is needed. (c) `claude --plugin-dir <clone>` loads the plugin in place and its hooks fire; a `--plugin-dir` plugin overrides an installed one of the same name. (d) Plugin hooks and the project's `.claude/settings.json` hooks for the same event **all fire, in sequence** (the spec's duplicate-hook edge case is real). (e) Install verbs are in-session commands: `/plugin marketplace add geobarteam/claude-evolve-plugin`, `/plugin install evolve@claude-evolve-plugin`, `/plugin marketplace update claude-evolve-plugin`; a new version is picked up with `/reload-plugins`; the install is recorded as `"enabledPlugins": { "evolve@claude-evolve-plugin": true }` in `.claude/settings.json` (project scope) or `~/.claude/settings.json` (user scope), with `extraKnownMarketplaces` for team setups. Marketplace plugins are copied to `~/.claude/plugins/cache/<marketplace>/<plugin>/<version>/`; the old version stays about 14 days. (f) `marketplace.json` requires `name`, `owner.name`, `plugins[].name`, `plugins[].source`; a repository may be its own marketplace with `"source": "./"`. (g) Hooks may use `"shell": "powershell"` or the exec form `"command": "pwsh", "args": [...]`; the docs show `powershell.exe`, `pwsh` is not explicitly documented — the Step 2 gate confirms `pwsh` works (fallback: `powershell.exe -File` launching `pwsh`). Not documented: any variable listing loaded plugins.
- **RED convention (script deliverables):** RED = write the Pester test first in `../claude-evolve-plugin/tests/`, run `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests/<File>.Tests.ps1 -Output Detailed"` from this repo's root, confirm it fails (file missing, assertion fails), then implement. Tests always pass explicit `-RepoRoot`/`-ProjectRoot` (never rely on `CLAUDE_PROJECT_DIR`, which is set inside a Claude Code session and would otherwise point the script at this repo).
- **AGENT PROOF per step** = `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests -Output Detailed"` green. **⚠️ Deviation for approval:** the .NET trio (`dotnet build src/FindMyDoctorWasm.sln` + unit-test exe + `dotnet format --verify-no-changes`) is run **once, at Step 8**, not at every step: Steps 1–7 touch no file in this repository, so the trio cannot change outcome, and the owner rated the previous work "- too slow" partly because the trio ran on every non-`src/` step.
- **Out of scope (spec):** any change to genome rules, rubric wording, feedback signals or regression semantics; Python/Node ports; a marketplace beyond the one repository; migrating other repositories' `CLAUDE.md` into beliefs. The regression seeds file `_specs/self-improvement/regression-seeds.md` and this repo's ten tasks stay as they are (spec row "regression seeds": for this repo they already exist as project state; elsewhere `init` writes skeletons).

**Plugin layout produced by this plan** (spec default, adapted: `scripts/lib/Config.psm1` and `scripts/lib/Init.psm1` added, labelling scripts under `scripts/labelling/`):

```
claude-evolve-plugin/
  .claude-plugin/plugin.json               name evolve, version 0.1.0, description, author, homepage, repository, license, keywords
  .claude-plugin/marketplace.json          Step 7
  hooks/hooks.json                         Step 2: SessionStart, Stop, SessionEnd, UserPromptSubmit, PostToolUse (matcher Skill|Agent|Task)
  hooks/{SessionStart,Stop,SessionEnd,UserPromptSubmit,PostToolUse}.ps1
  commands/evolve.md                       init | propose (default) | show [N] | revert N | collect | score [ref]
  scripts/lib/{Config,Contract,Feedback,Genome,GitSignals,HookInput,Init,Regression,Transcript,Worktree}.psm1
  scripts/evolver/{Invoke-Evolver,Test-GenomeContract,Show-Generation,Revert-Generation}.ps1 + prompt.md + rubric.md
  scripts/regression/Invoke-Regression.ps1
  scripts/feedback/Collect-DailyFeedback.ps1
  scripts/labelling/{Label-Sessions,Test-ClassifierAgreement}.ps1
  scripts/Initialize-Project.ps1           what /evolve init runs
  templates/{protected-block.md, duties.md, MEMORY.md, journal-TEMPLATE.md, genome-paths.txt, protected-paths.txt,
             lineage.md, evolve.json, azure-pipeline-genome.yml, regression/T01.md, regression/T02.md}
  tests/*.Tests.ps1 + ContractRepo.psm1 + fixtures/{claude-shim.ps1, transcript-basic.jsonl, transcript-corrections.jsonl}
  .github/workflows/pester.yml             Step 7
  README.md                                owner's guide, generalised
  LICENSE                                  MIT (assumption, see decisions)
```

**Owner decisions needed before Step 1** (answer inline; the plan is applied as written unless you change one):

1. **.NET trio once, at Step 8 only** (Steps 1–7 never touch this repository). Approve or ask for it at every step. auto approve 1 to 7
2. **Plugin clone location** `D:\Data\gv10141\Repos\Common\claude-evolve-plugin` (sibling; created by Step 1 with `git init -b main`; you add the GitHub remote and push). Approve or name another path. approved
3. **`azure-pipeline-genome.yml`**: after migration its step `./evolution/evolver/Test-GenomeContract.ps1` no longer exists here. Step 8 proposes the minimal edit (clone the plugin at tag `v0.1.0` into `$(Agent.TempDirectory)` and run its checker). Alternative: leave the file unchanged (it stays unregistered and dead until edited). Choose. approvced do first proposition
4. **`.claude/commands/evolve.md` is removed** in Step 8 (the plugin provides `/evolve`; two commands with the same name would clash). AC-7 does not list it explicitly; confirm. confirmed
5. **Assumptions made:** plugin licence MIT with `author` `{ "name": "Geoffrey", "email": "geoffrey@digiverse.be" }` in `plugin.json`; labelled sessions move to `evolution/labelled/` (gitignored); this repo's `evolverEmail` should change to `geoffrey.vandiest@riziv-inami.fgov.be.local`.
6. **Command name.** Plugin commands are always namespaced (Overview fact a), so the spec's `/evolve init` becomes `/evolve:evolve init` with the single `commands/evolve.md` the plan describes. **Recommended alternative:** one file per subcommand — `init.md`, `propose.md`, `show.md`, `revert.md`, `collect.md`, `score.md` — giving `/evolve:init`, `/evolve:propose`, `/evolve:show`, … (bare `/evolve:propose` replaces "no argument = propose"). If you choose it, Steps 5 and 6 create those files instead of one `evolve.md` (same content split by subcommand) and Step 8 removes `.claude/commands/evolve.md` as planned; the docs recommend `skills/<name>/SKILL.md` over the legacy `commands/` folder, so the files would be `skills/init/SKILL.md` etc. Choose: single `evolve.md`, or per-subcommand skills (recommended). use recommended alternatives

---

## Step 1 — The evolver, contract, regression, feedback and labelling scripts run from the plugin against any project, and the plugin's Pester suite passes without this repository

**Scope** *(all under `../claude-evolve-plugin/` — new git repository, branch `main`)*:

- `.claude-plugin/plugin.json` *(create)* — `{ "name": "evolve", "version": "0.1.0", "description": "Self-evolving Claude Code agent: journal + feedback hooks, regression harness, owner-triggered evolver with a genome contract", "author": {…}, "homepage": "https://github.com/geobarteam/claude-evolve-plugin", "repository": "https://github.com/geobarteam/claude-evolve-plugin.git", "license": "MIT", "keywords": ["evolve","genome","hooks","pester"] }`.
- `scripts/lib/Config.psm1` *(create)* — `Resolve-ProjectRoot [-ProjectRoot] [-HookInput]` (precedence: explicit parameter, `$env:CLAUDE_PROJECT_DIR`, hook-input `cwd`, `(Get-Location).Path`; **never** `$PSScriptRoot`; throws `Unable to resolve the project root.` only when the chosen candidate does not exist), `Get-PluginRoot` (`$env:CLAUDE_PLUGIN_ROOT` if set and existing, else `Resolve-Path "$PSScriptRoot/../.."`), `ConvertTo-ClaudeProjectFolderName -Path`, `Get-TranscriptDir -ProjectRoot [-Configured]` (returns `-Configured` when given, else `Join-Path $HOME ".claude/projects/<encoded>"`).
- `scripts/lib/{Contract,Feedback,Genome,GitSignals,HookInput,Regression,Transcript,Worktree}.psm1` *(create — copied from `evolution/lib/`)* — changes: `Feedback.psm1 Invoke-SessionFeedback` reads the rubric from `Join-Path $PSScriptRoot '../evolver/rubric.md'` (plugin-relative) and gains `-RubricPath` for tests; `Worktree.psm1` default prefix `evolve-wt`; `Invoke-Regression.ps1` worktree prefix `evolve-regression`, `Invoke-Evolver.ps1` prefixes `evolve-evolver[-propose]`. `HookInput.psm1` is copied unchanged (its `-Fallback` change is Step 2).
- `scripts/evolver/{Invoke-Evolver,Test-GenomeContract,Show-Generation,Revert-Generation}.ps1`, `scripts/evolver/prompt.md`, `scripts/evolver/rubric.md` *(create — copied from `evolution/evolver/`)* — every `[string] $RepoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..\..')).Path` / `$RepoPath = …` default becomes `[string] $RepoRoot = (Resolve-ProjectRoot)` after `Import-Module "$PSScriptRoot/../lib/Config.psm1"`; module imports become `"$PSScriptRoot/../lib/<Name>.psm1"` (forward slashes); `Invoke-Evolver.ps1` `$regressionScript = "$PSScriptRoot/../regression/Invoke-Regression.ps1"` (already plugin-relative, path style only).
- `scripts/regression/Invoke-Regression.ps1` *(create — copied)* — `$TasksDir` default `Join-Path $RepoRoot 'evolution/regression/tasks'` (project state, no longer `$PSScriptRoot/tasks`); root default as above.
- `scripts/feedback/Collect-DailyFeedback.ps1` *(create — copied)* — `$TranscriptDir` default `(Get-TranscriptDir -ProjectRoot $RepoRoot)` (evaluated after root resolution in the body, not in `param()`).
- `scripts/labelling/Label-Sessions.ps1`, `scripts/labelling/Test-ClassifierAgreement.ps1` *(create — copied from `evolution/tests/`)* — labels dir `Join-Path $RepoRoot 'evolution/labelled'`; transcript dir and rubric as above.
- `templates/protected-block.md`, `templates/duties.md`, `templates/MEMORY.md`, `templates/journal-TEMPLATE.md`, `templates/genome-paths.txt`, `templates/protected-paths.txt`, `templates/lineage.md` *(create)* — generic versions of today's files: `protected-block.md` = the block text described in the Overview (`{{HARD_CONSTRAINTS}}` marker line removed when empty); `duties.md` = today's "Working agent duties" section with `evolution/feedback/Collect-DailyFeedback.ps1` replaced by `/evolve collect` and no NIHDI wording; `MEMORY.md` = today's header + rules + empty `## Beliefs` / `## Conventions`; `protected-paths.txt` = `evolution/evolve.json`, `evolution/evolver/genome-paths.txt`, `evolution/evolver/protected-paths.txt`, `evolution/regression/tasks/*.check.ps1`, `azure-pipeline-*.yml`, `.claude/settings.json`; `genome-paths.txt` = today's; `lineage.md` = header + column row only.
- `tests/ContractRepo.psm1` *(create — rewritten)* — `$script:RealRoot` removed; `New-ContractRepo -Root [-PreviousScore]` assembles `CLAUDE.md` = `templates/duties.md` + `templates/protected-block.md`, copies `templates/MEMORY.md`, both manifest templates, `templates/lineage.md` + a `gen/0` row, writes a minimal `evolution/generations/gen-0.md` (`# gen/0 — baseline`, `Score: —`, `Retired:`/`Declined to change:` sections), `evolution/evolve.json` = `{}`, the dummy `.claude/settings.json`, `.claude/skills/refit/SKILL.md`, `src/x.cs`, one journal, and the two synthetic tasks `T01` (`Say alpha`, expect `alpha`) and `T02` (`Say beta`, expect `beta`); tags `gen/0`. `New-Proposal`, `New-Note`, `Add-ProtectedEdit`, `Add-OutsideEdit` unchanged.
- `tests/{Contract → GenomeContract, Evolver.Commit, Evolver.Run, Feedback, Genome, GitSignals, Lineage, Regression, Transcript}.Tests.ps1`, `tests/fixtures/{claude-shim.ps1, transcript-basic.jsonl, transcript-corrections.jsonl}` *(create — copied from `evolution/tests/`; the five `Hooks.*.Tests.ps1` are Step 2)* — every `$script:RepoRoot = … '..\..'` becomes `$script:PluginRoot = (Resolve-Path "$PSScriptRoot/..").Path` and engine paths follow the new layout; `Genome.Tests.ps1` targets a `New-ContractRepo` scaffold instead of this repository; `Regression.Tests.ps1` rewritten to the synthetic repo (see RED).
- `tests/Config.Tests.ps1`, `tests/PluginLayout.Tests.ps1` *(create)*.
- `README.md` *(create, first cut)* — layout + how to run the tests; generalised in Step 7.

**RED** *(write these tests first, run them, confirm they fail before writing production code)*:

- Test files: `../claude-evolve-plugin/tests/Config.Tests.ps1`, `tests/PluginLayout.Tests.ps1`, `tests/Regression.Tests.ps1`
- Test methods: `ResolveProjectRoot_ExplicitParameter_WinsOverEnvironment`, `ResolveProjectRoot_ClaudeProjectDirSet_ReturnsIt`, `ResolveProjectRoot_NothingSet_ReturnsCurrentDirectory`, `ResolveProjectRoot_Never_ReturnsPluginRoot`, `ConvertToClaudeProjectFolderName_KnownWindowsPath_MatchesClaudeCodeEncoding` (`D:\Data\gv10141\Repos\Common\FindMyDoctor-Wasm` → `d--Data-gv10141-Repos-Common-FindMyDoctor-Wasm`), `ConvertToClaudeProjectFolderName_PosixPath_ReplacesSlashesAndDots`, `GetTranscriptDir_Configured_ReturnsConfiguredValue`, `PluginJson_Exists_NamesEvolveWithSemanticVersion`, `Engine_NoScriptOrModule_UsesPSScriptRootParentParentAsProjectRoot` (regex `\$PSScriptRoot\s*'\.\.[\\/]\.\.'` over `scripts/**`, `hooks/**`, `tests/**`), `Engine_NoFile_ContainsRepositoryOrUserSpecificPaths` (`FindMyDoctor`, `d--Data-gv10141`, `gv10141`, `fmd-` absent from `scripts/**`, `hooks/**`, `templates/**`, `tests/**`), `Regression_TaskFilesOfScaffold_HaveIdPromptCheckExpect`, `InvokeRegression_ShimAnswersAllTasks_ScoresTwoOfTwo`, `InvokeRegression_ShimFailsOne_ScoresOneOfTwoAndListsFailingId`, `InvokeRegression_ScriptCheck_RunsSiblingCheckScriptInsideWorktree` (adds a third task with `check: script` + `T03.check.ps1` asserting the shim's `EDIT:src/x.cs|…` landed in the worktree), `InvokeRegression_Always_RemovesWorktree` (prefix `evolve-regression-`), `InvokeRegression_Never_ModifiesOwnerCheckout` (scaffold's `git status --porcelain` unchanged), `InvokeSessionFeedback_RubricPath_DefaultsToPluginRubric`
- Failing-run command: `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests/Config.Tests.ps1 -Output Detailed"` (module missing), then `…/PluginLayout.Tests.ps1` and `…/Regression.Tests.ps1`.
- All copied test files must also be green: the rest of the suite (Contract, Evolver, Feedback, Genome, GitSignals, Lineage, Transcript) is the regression net for the move.

**GREEN**: create the repository and files as scoped; `Export-ModuleMember -Function Resolve-ProjectRoot, Get-PluginRoot, ConvertTo-ClaudeProjectFolderName, Get-TranscriptDir` in `Config.psm1`; every script imports `Config.psm1` first and resolves its root through it.

**DB changes**: none.

**VERIFY**: `Invoke-Pester -Path ../claude-evolve-plugin/tests` green (≥ 97 tests: the 102 minus the hook tests that arrive in Step 2, plus the new ones).

**REFACTOR** *(these instructions are for the executor, not the planner)*:

- Analyse the produced code with code-analysis.agent and fix any new issues before proceeding to the next step.
- Optional: any additional refactorings to improve code quality, maintainability, or align with patterns — but only after RED-GREEN-VERIFY is complete for this step. Do not refactor during RED-GREEN cycles, only after the feature slice is fully working and verified.

**AGENT PROOF**: plugin Pester suite green; `git -C ../claude-evolve-plugin status` clean after the commit; this repository's `git status` unchanged.

**🛑 HUMAN GATE**:

- [x] Behavioral verification: from **this** repository's root run `pwsh ../claude-evolve-plugin/scripts/evolver/Show-Generation.ps1` (no `-RepoRoot`): it prints this repo's lineage and `gen-0.md` — the project root came from the current directory, not from the script's location. Then `cd` into a scratch folder that is not a repository and run the same script: it fails with `No evolution/lineage.md yet.`, proving it never falls back to the plugin folder. `pwsh ../claude-evolve-plugin/scripts/regression/Invoke-Regression.ps1 -Ref gen/0 -Only T01` from this repo's root scores this repo's own T01 (one real call) with the tasks read from `evolution/regression/tasks/`.
- [x] Code review: no `$PSScriptRoot '..\..'` remains anywhere in the plugin; `ContractRepo.psm1` reads nothing outside the plugin; `Resolve-ProjectRoot` precedence is explicit → `CLAUDE_PROJECT_DIR` → hook `cwd` → current directory. ⚠️ Risk area: the contract checker and evolver now live outside this repo's protected paths; they are unchanged in behaviour (diff the copies against `evolution/` — only root resolution, imports, prefixes and the rubric path may differ).

---

## Step 2 — A session in any project is hooked by the plugin: memory + journals injected, journal enforced, ratings and usage recorded, with no hooks in the project's `.claude/settings.json`

**Scope** *(all under `../claude-evolve-plugin/`)*:

- `hooks/{SessionStart,Stop,SessionEnd,UserPromptSubmit,PostToolUse}.ps1` *(create — copied from `.claude/hooks/`)* — imports `"$PSScriptRoot/../scripts/lib/<Name>.psm1"`; `Resolve-RepoRoot -RepoRoot $RepoRoot -HookInput $hookInput` with **no `-Fallback`**; when no root resolves the hook exits 0 silently (nothing to log to; BR-6 fail-safe); the "Journal duty" text is unchanged.
- `scripts/lib/HookInput.psm1` *(modify)* — `Resolve-RepoRoot`: `-Fallback` removed; precedence explicit `-RepoRoot` → `$env:CLAUDE_PROJECT_DIR` → hook-input `cwd`; throws `Unable to resolve the project root for the hook.` otherwise (callers catch and exit 0).
- `hooks/hooks.json` *(create)* — `{ "hooks": { "SessionStart": [ { "hooks": [ { "type": "command", "command": "pwsh -NoProfile -NonInteractive -File \"${CLAUDE_PLUGIN_ROOT}/hooks/SessionStart.ps1\"", "timeout": 20 } ] } ], "Stop": [ … 20 ], "SessionEnd": [ … 120 ], "UserPromptSubmit": [ … 20 ], "PostToolUse": [ { "matcher": "Skill|Agent|Task", "hooks": [ … 20 ] } ] } }`.
- `tests/Hooks.{SessionStart,Stop,SessionEnd,UserPromptSubmit,PostToolUse}.Tests.ps1` *(create — copied from `evolution/tests/`)* — hook paths `"$PluginRoot/hooks/<Name>.ps1"`; `Hooks.SessionEnd.Tests.ps1 New-FakeRepo` no longer copies a rubric into the fake repo (the hook reads the plugin's).
- `tests/Hooks.Wiring.Tests.ps1` *(create)*.

**RED**:

- Test file: `../claude-evolve-plugin/tests/Hooks.Wiring.Tests.ps1`
- Test methods: `HooksJson_FiveEvents_EachCommandRunsPwshFileUnderPluginRootWithExpectedTimeout` (20/20/120/20/20), `HooksJson_PostToolUse_MatcherIsSkillAgentTask`, `HooksJson_EveryReferencedHookScript_Exists`, `Hook_CwdInInput_UsedAsProjectRootWhenNoRepoRootParameter` (SessionStart with `cwd` = scaffold, no `-RepoRoot`, `CLAUDE_PROJECT_DIR` cleared for the call → prints that scaffold's `MEMORY.md`), `Hook_NoRootResolvable_ExitsZeroWithoutOutput`, `Hook_InternalError_AppendsHookErrorsLogUnderProjectStateAndExitsZero` (unreadable journal dir → `evolution/.state/hook-errors.log` line, exit 0), `SessionStart_Always_WritesPluginRootFileUnderProjectState`, `Hooks_NoScript_ReferencesEvolutionLibOrParentParent` (regex over `hooks/*.ps1`)
- Failing-run command: `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests/Hooks.Wiring.Tests.ps1 -Output Detailed"`
- The five copied hook test files must be green too (they are the behavioural regression net: memory + 3 journals, block/unblock, ratings, usage, feedback records).

**GREEN**: hooks and `hooks.json` as scoped; `HookInput.psm1` change.

**DB changes**: none.

**VERIFY**: plugin Pester suite green (all 102 original `It` blocks now live in the plugin, plus Step 1–2 additions).

**REFACTOR** *(these instructions are for the executor, not the planner)*:

- Analyse the produced code with code-analysis.agent and fix any new issues before proceeding to the next step.
- Optional: any additional refactorings to improve code quality, maintainability, or align with patterns — but only after RED-GREEN-VERIFY is complete for this step. Do not refactor during RED-GREEN cycles, only after the feature slice is fully working and verified.

**AGENT PROOF**: plugin Pester suite green; this repository untouched.

**🛑 HUMAN GATE**:

- [x] Behavioral verification (**live; also confirms that `pwsh` is accepted as a plugin hook command, Overview fact g**): create a throwaway folder `C:\Temp\evolve-gate` with `git init`, a one-line `CLAUDE.md`, `MEMORY.md` containing `## Beliefs` + `- **Gate belief** (since: gen/0). visible`, `evolution/journal/TEMPLATE.md` (copy of the template), an empty `.claude/settings.json` (`{}`), then start `claude --plugin-dir D:\Data\gv10141\Repos\Common\claude-evolve-plugin` inside it. Expect: the first answer shows it saw "Gate belief"; the turn is blocked once until `evolution/journal/<date>.md` exists; a prompt `- slow` yields `Rating recorded: - (slow)` and a `rating` record in `evolution/feedback/<date>.jsonl`; `evolution/.state/hook-errors.log` does not exist. Spec AC-2 met for a project with no hooks of its own. If `pwsh` is not accepted as the hook command, switch `hooks.json` to `powershell.exe -NoProfile -ExecutionPolicy Bypass -File …` launching `pwsh`, and record that in the plan.
- [x] Code review: no hook can fall back to the plugin folder as project root; the `stop_hook_active` loop guard and `EVOLUTION_CLASSIFIER` suppression are unchanged; `hooks.json` quotes `${CLAUDE_PLUGIN_ROOT}`. ⚠️ Risk area: hooks are the part that touches every session; the fail-safe (BR-6) is tested explicitly.

---

## Step 3 — The engine reads its identity, transcript folder, models, budgets, tool allow-list and trailer pattern from `evolution/evolve.json`, with defaults when the file is absent or minimal

**Scope** *(all under `../claude-evolve-plugin/`)*:

- `scripts/lib/Config.psm1` *(modify)* — `Get-EvolveConfig -ProjectRoot` returns a `[pscustomobject]` with every key of the spec table (`EvolverName`, `EvolverEmail`, `TranscriptDir`, `MaxEdits`, `SettleAfterDays`, `RetireAfterDays`, `Regression.Model`, `Regression.AllowedTools`, `Proposal.Model`, `Proposal.MaxBudgetUsd`, `Classifier.Model`, `AgentTrailerPattern`, `MainLine`, plus `Source` = `defaults` | `evolution/evolve.json`): defaults from the Overview; `evolverEmail` default `evolver@<leaf folder of ProjectRoot, lower-case>.local`; `TranscriptDir` resolved through `Get-TranscriptDir`; missing file → all defaults; unreadable JSON → throws `evolution/evolve.json is not valid JSON: <parser message>`; unknown keys ignored.
- `templates/evolve.json` *(create)* — all keys with their defaults, `mainLine` filled by `init` (Step 5); comment-free JSON.
- `scripts/evolver/Invoke-Evolver.ps1` *(modify)* — `$script:EvolverName/Email` from config; `-Model` default `$config.Proposal.Model` (regression call passes `$config.Regression.Model` unless `-Model` was bound explicitly); `-MaxEdits`, `-MaxBudgetUsd`, `-SettleAfterDays` defaults from config; `prompt.md` placeholder `{{RETIRE_AFTER_DAYS}}` replaces the literal "30 days"; log line `Evolver run <stamp> on branch '<branch>' (mainLine: <MainLine>)`; `Get-AgentCommits … -TrailerPattern $config.AgentTrailerPattern`.
- `scripts/evolver/prompt.md` *(modify)* — `{{RETIRE_AFTER_DAYS}}` placeholder (wording otherwise unchanged; rules are out of scope).
- `scripts/regression/Invoke-Regression.ps1` *(modify)* — `-AllowedTools` default `$config.Regression.AllowedTools`, `-Model` default `$config.Regression.Model` (both resolved in the body after the root).
- `scripts/lib/GitSignals.psm1` *(modify)* — `Get-Commits`, `Get-AgentCommits`, `Get-CodeCorrections`, `Get-BugAttributions`, `Get-DiffSurvival`, `Invoke-GitSignals` gain `[string] $TrailerPattern = $script:DefaultAgentTrailerPattern` (`(?im)^Co-Authored-By:\s*Claude\b`, i.e. the spec default with the `(?im)` flags applied by the module); callers pass the configured value.
- `hooks/SessionEnd.ps1`, `scripts/feedback/Collect-DailyFeedback.ps1`, `scripts/labelling/Test-ClassifierAgreement.ps1` *(modify)* — `-Model` default `$config.Classifier.Model`; `-TranscriptDir` default `$config.TranscriptDir`.
- `tests/Config.Tests.ps1`, `tests/Evolver.Commit.Tests.ps1`, `tests/Regression.Tests.ps1`, `tests/GitSignals.Tests.ps1`, `tests/Hooks.SessionEnd.Tests.ps1` *(modify)*.

**RED**:

- Test files: `../claude-evolve-plugin/tests/Config.Tests.ps1` (+ the four listed)
- Test methods: `GetEvolveConfig_NoFile_ReturnsEverySpecDefault`, `GetEvolveConfig_DefaultEvolverEmail_UsesLowerCaseProjectFolderName`, `GetEvolveConfig_PartialFile_OverridesOnlyGivenKeys` (`{ "maxEdits": 2, "regression": { "allowedTools": "Read,Bash(dotnet build *)" } }`), `GetEvolveConfig_InvalidJson_ThrowsNamingTheFile`, `Evolver_ConfiguredIdentity_CommitsWithThatNameAndEmail` (`evolve.json` with `evolverName: bot`, `evolverEmail: bot@example.test` → `git log -1 --format=%an <%ae>`), `Evolver_ConfiguredMaxEdits2_RefusesThreeChanges`, `InvokeRegression_ConfiguredAllowedTools_PassedToClaude` (shim log shows `--allowedTools Read,Bash(dotnet build *)`), `InvokeRegression_ConfiguredModel_PassedToClaude`, `GetAgentCommits_CustomTrailerPattern_MatchesOnlyThatTrailer`, `SessionEnd_ConfiguredClassifierModel_PassedToClaude`
- Failing-run command: `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests/Config.Tests.ps1 -Output Detailed"`

**GREEN**: as scoped; `Export-ModuleMember` adds `Get-EvolveConfig`.

**DB changes**: none.

**VERIFY**: plugin Pester suite green.

**REFACTOR** *(these instructions are for the executor, not the planner)*:

- Analyse the produced code with code-analysis.agent and fix any new issues before proceeding to the next step.
- Optional: any additional refactorings to improve code quality, maintainability, or align with patterns — but only after RED-GREEN-VERIFY is complete for this step. Do not refactor during RED-GREEN cycles, only after the feature slice is fully working and verified.

**AGENT PROOF**: plugin Pester suite green; `Engine_NoFile_ContainsRepositoryOrUserSpecificPaths` extended with `findmydoctor.local` and `dotnet build` and still green.

**🛑 HUMAN GATE**:

- [x] Behavioral verification: in the Step 2 throwaway project write `evolution/evolve.json` = `{ "evolverEmail": "evolver@gate.local" }` and run `pwsh ../claude-evolve-plugin/scripts/evolver/Invoke-Evolver.ps1 -ProposalDir <hand-made 1-line MEMORY.md proposal with a cited Why:> -SkipRegression` from that folder: the commit author is `evolver <evolver@gate.local>`, tag `gen/1`. Delete the file, `git revert gen/1`, run again with `-Force`: author e-mail is `evolver@evolve-gate.local` (derived default). Then `git tag -d gen/1` to leave the throwaway at gen/0.
- [x] Code review: every default in `Get-EvolveConfig` equals the spec table; explicit parameters still win over the file; the trailer default equals the CLAUDE.md rule of this repo (`Co-Authored-By: Claude …`). ⚠️ Risk area: `evolverEmail` decides which commits CI treats as evolver commits (`-OnlyIfAuthor` compares the **name**, which stays `evolver` by default).

---

## Step 4 — The contract refuses any generation that edits `evolution/evolve.json`, anything under the plugin root, or any path outside the project root

**Scope** *(all under `../claude-evolve-plugin/`)*:

- `scripts/lib/Contract.psm1` *(modify)* — `Test-GenomeContract` gains `[string] $PluginRoot = (Get-PluginRoot)` and `[string] $ProjectRoot` (defaults to `$RepoPath`); the protected set = manifest (from the base ref, as today) **+** `evolution/evolve.json` **+** `<plugin root relative to project>/**` when the plugin root lies inside the project root (e.g. a `--plugin-dir` checkout inside the repo); a changed path that is rooted, contains a `..` segment, or resolves outside `$ProjectRoot` yields the violation `REFUSED: path outside the project root: <path>` (BR-1); violation text for the config stays `protected path changed: evolution/evolve.json` (BR-7).
- `scripts/evolver/Test-GenomeContract.ps1` *(modify)* — `-PluginRoot` parameter passed through.
- `scripts/evolver/Invoke-Evolver.ps1` *(modify)* — `Copy-ProposalFiles` refuses (log `REFUSED: path outside the project root: <path>`, exit 1, nothing committed) when a proposal path or the destination resolves outside `$RepoRoot` (both when capturing the worktree diff and in `-ProposalDir` mode); the evidence bundle's "Protected paths (never edit)" section appends `evolution/evolve.json` and `the plugin folder (<PluginRoot>)`.
- `scripts/evolver/prompt.md` *(modify)* — one sentence under "Propose": never edit `evolution/evolve.json` or anything outside this worktree.
- `tests/GenomeContract.Tests.ps1`, `tests/Evolver.Commit.Tests.ps1` *(modify)*.

**RED**:

- Test files: `../claude-evolve-plugin/tests/GenomeContract.Tests.ps1`, `tests/Evolver.Commit.Tests.ps1`
- Test methods: `Contract_EvolveJsonChanged_FailsAsProtectedPath`, `Contract_PluginRootInsideProject_FileUnderItFailsAsProtectedPath` (`-PluginRoot (Join-Path $Root 'tools/evolve-plugin')`), `Contract_PluginRootOutsideProject_AddsNothingAndPasses`, `Contract_ManifestWithoutEvolveJson_StillProtectsItAtRuntime`, `Checker_PluginRootParameter_PassedThrough`, `TestPathInsideProject_{RelativePathWithoutParentSegment_True, ParentSegment_False, RootedPath_False}` (the escape guard is a pure helper `Test-PathInsideProject`, shared by the contract and by the evolver's `Copy-ProposalFiles`; a `-ProposalDir` cannot physically contain a `..` entry and `git diff --name-only` never yields one, so the guard is unit-tested directly instead of through an impossible proposal), `Evolver_EvidenceBundle_ListsEvolveJsonAndPluginRootAsProtected`
- Failing-run command: `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests/GenomeContract.Tests.ps1 -Output Detailed"`

**GREEN**: as scoped.

**DB changes**: none.

**VERIFY**: plugin Pester suite green.

**REFACTOR** *(these instructions are for the executor, not the planner)*:

- Analyse the produced code with code-analysis.agent and fix any new issues before proceeding to the next step.
- Optional: any additional refactorings to improve code quality, maintainability, or align with patterns — but only after RED-GREEN-VERIFY is complete for this step. Do not refactor during RED-GREEN cycles, only after the feature slice is fully working and verified.

**AGENT PROOF**: plugin Pester suite green.

**🛑 HUMAN GATE**:

- [x] Behavioral verification: in the throwaway project hand-craft a proposal that changes `evolution/evolve.json` (`maxEdits` → 9) plus a valid note → `Invoke-Evolver.ps1 -ProposalDir … -SkipRegression` prints `REFUSED … VIOLATION: protected path changed: evolution/evolve.json` and commits nothing; `Test-GenomeContract.ps1 -Base gen/0 -Worktree <that proposal applied in a worktree> -PluginRoot <path inside the project>` names the plugin path when a file under it is changed. Spec AC-6 met.
- [x] Code review: the runtime additions cannot be removed by editing the manifests (they are added in code, not read from a file); path normalisation uses forward slashes before the `..` check. ⚠️ Risk area: this is the contract that keeps the config and the engine out of the evolver's reach.

---

## Step 5 — `/evolve init` scaffolds a fresh project idempotently: protected block and duties in `CLAUDE.md`, `MEMORY.md`, the `evolution/` tree with a generated gen-0 inventory, `evolve.json`, `.gitignore` entries, optional CI template, with the BR-2/3/4 messages and duplicate-hook warning

**Scope** *(all under `../claude-evolve-plugin/`)*:

- `scripts/lib/Init.psm1` *(create)* — `Test-ProjectInitialised -ProjectRoot` (block present **and** `evolution/lineage.md` present), `Get-ProtectedBlockTemplate [-Constraints]` (renders `templates/protected-block.md`; with constraints adds `- Hard constraints for this project:` + one sub-bullet per constraint), `Add-ProtectedBlock -ClaudeMdPath -Text` (appends with one blank line; returns `protected block already present` without writing when a block exists), `Compare-ProtectedBlock -ClaudeMdPath -Template` (returns `protected block differs from the plugin template (kept as is)` or `$null`), `Add-DutiesSection -ClaudeMdPath [-ConstraintLine]` (inserts `templates/duties.md` **before** the protected block if the heading `## Working agent duties` is absent; `-ConstraintLine` adds `- **Hard constraints.** <text>` to it), `New-GenerationZeroNote -ProjectRoot` (inventory tables for `.claude/agents`, `.claude/skills` (`SKILL.md` front-matter `description`), `.claude/commands`, `.claude/instructions`, `.claude/templates`, `.claude/tools`, plus `CLAUDE.md`/`MEMORY.md`; each row = file + first line of its `description` front-matter or first heading; when `.claude/` is missing every section reads `(none)` and the function emits a warning `no .claude/ folder found; inventory sections are empty`), `New-LineageFile -ProjectRoot -Summary` (template + `| gen/0 | <today> | — | settled | <summary> |`), `New-EvolveConfig -ProjectRoot` (template with `mainLine` = `git symbolic-ref --short HEAD`, or `main` when not a repo), `New-RegressionSkeletons -ProjectRoot` (copies `templates/regression/T01.md`, `T02.md` only when `evolution/regression/tasks/` has no `T*.md`: T01 prompt `Which file in this repository holds the owner's protected constraints for the coding agent?` expect `CLAUDE.md`; T02 prompt `May you push commits or tags to a remote?` expect `never`), `Add-GitignoreEntries -ProjectRoot` (`evolution/.state/`, `evolution/labelled/` — appended once under a `# evolve plugin` comment), `Test-DuplicateHooks -ProjectRoot` (scans `.claude/settings.json` `hooks` commands for `SessionStart.ps1|Stop.ps1|SessionEnd.ps1|UserPromptSubmit.ps1|PostToolUse.ps1` → warning `settings.json already runs <event> hook '<command>'; the plugin hook will run in addition`), `Copy-ProjectTemplates` (`MEMORY.md`, `evolution/journal/TEMPLATE.md`, both manifests, `evolution/feedback/.gitkeep`, `evolution/generations/`).
- `scripts/Initialize-Project.ps1` *(create)* — `[-ProjectRoot] [-Constraints <string[]>] [-ConstraintPlacement protected|duties] [-IncludeCi] [-WhatIf]`: refuses with `CLAUDE.md not found` (exit 1) when absent; otherwise runs every `Init.psm1` step per-artifact-idempotently, prints one line per artifact (`created <path>` | `kept <path>`), the BR-4 line when applicable, duplicate-hook warnings, and ends with either `initialised <n> artifact(s)` or `already initialised; nothing changed` (exit 0). **Never** runs `git add`, `git commit` or `git tag`. `-IncludeCi` copies `templates/azure-pipeline-genome.yml` (generalised: pool and trigger branch as `# TODO` placeholders, checker invoked from a cloned plugin at a pinned tag — same content as Step 8's proposal for this repo).
- `templates/evolve.json`, `templates/regression/T01.md`, `templates/regression/T02.md`, `templates/azure-pipeline-genome.yml` *(create)*.
- `commands/evolve.md` *(create — from `.claude/commands/evolve.md`, `init` only in this step)* — the `init` flow in chat: (1) ask for project-specific hard constraints (example given: "the WASM client never holds tokens"), (2) propose the two placements and show the resulting protected-block text for confirmation, (3) ask whether regression seeds exist (skeletons otherwise), (4) ask about the CI template (AC-8: default no), (5) run `pwsh -NoProfile -File "<plugin root>/scripts/Initialize-Project.ps1" -ProjectRoot "$PWD" [-Constraints …] [-ConstraintPlacement …] [-IncludeCi]` where `<plugin root>` = `${CLAUDE_PLUGIN_ROOT}` (string-substituted in command markdown; the Bash tool does not see it as an environment variable, so the command text must carry the substituted path), (6) show the output, (7) offer — and only after an explicit yes run — `git add` of the created paths, a commit `chore(evolve): initialise the self-evolving agent (gen/0)` and `git tag gen/0`; nothing is committed or tagged otherwise (AC-1). The other subcommands are Step 6.
- `tests/Init.Tests.ps1` *(create)*.

**RED**:

- Test file: `../claude-evolve-plugin/tests/Init.Tests.ps1` (fresh `TestDrive:` repos with `git init`, a `CLAUDE.md`, optionally `.claude/agents/a.md` + `.claude/skills/s/SKILL.md` with `description:` front-matter)
- Test methods: `Init_FreshRepo_WritesProtectedBlockDutiesMemoryEvolutionTreeConfigAndGitignore`, `Init_FreshRepo_Gen0InventoryListsEachAgentSkillCommandInstructionWithDescription`, `Init_FreshRepo_LineageHasGen0RowAndEvolveJsonListedInProtectedPaths`, `Init_FreshRepo_EvolveJsonMainLineIsCurrentBranch`, `Init_SecondRun_ChangesNoFileAndSaysAlreadyInitialised` (hash every file before/after), `Init_NoClaudeMd_RefusesClaudeMdNotFound`, `Init_ExistingProtectedBlock_NotAppendedAgainAndReportsProtectedBlockAlreadyPresent`, `Init_ExistingBlockDifferentFromTemplate_ReportsDiffersKeptAsIs`, `Init_NoClaudeFolder_WritesEmptyInventorySectionsAndWarns`, `Init_ConstraintsProtectedPlacement_BlockContainsHardConstraintsBullet`, `Init_ConstraintsDutiesPlacement_DutiesLineAddedAndBlockEqualsTemplate`, `Init_ExistingTasks_KeepsThemAndWritesNoSkeletons`, `Init_NoTasks_WritesTwoSkeletonTasks`, `Init_WithoutIncludeCi_WritesNoPipelineFile`, `Init_IncludeCi_WritesPipelineTemplate`, `Init_SettingsWithStopHookCommand_WarnsDuplicateHook`, `Init_Never_CommitsOrTags` (`git log` count and `git tag` unchanged), `Init_PartiallyInitialisedProject_CreatesOnlyMissingArtifacts` (block + lineage present, no `evolve.json` → only `evolve.json` and the `.gitignore` entry created — the Step 8 migration case), `EvolveCommand_InitSection_NeverCommitsWithoutConfirmation` (markdown contains the confirmation sentence before any `git commit`)
- Failing-run command: `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests/Init.Tests.ps1 -Output Detailed"`

**GREEN**: as scoped; `Export-ModuleMember` for every `Init.psm1` function.

**DB changes**: none.

**VERIFY**: plugin Pester suite green.

**REFACTOR** *(these instructions are for the executor, not the planner)*:

- Analyse the produced code with code-analysis.agent and fix any new issues before proceeding to the next step.
- Optional: any additional refactorings to improve code quality, maintainability, or align with patterns — but only after RED-GREEN-VERIFY is complete for this step. Do not refactor during RED-GREEN cycles, only after the feature slice is fully working and verified.

**AGENT PROOF**: plugin Pester suite green; `Genome.Tests.ps1`'s `GetGenomeManifest_EveryListedNonGlobPathExists` re-run against an `init`-scaffolded folder (every non-glob entry of the template manifests exists after `init`).

**🛑 HUMAN GATE**:

- [x] Behavioral verification (**live**): new throwaway repo `C:\Temp\evolve-init` with a `CLAUDE.md`, a `.claude/agents/hello.md` and a `.claude/skills/hello/SKILL.md`; `claude --plugin-dir …` inside it; run `/evolve:evolve init` (or `/evolve:init` if decision 6 chooses per-subcommand files) and answer: constraint "never delete migrations", placement inside the block, skeleton seeds, no CI. Expect: `CLAUDE.md` ends with the block containing the constraint and has the duties section; `MEMORY.md`, `evolution/{journal/TEMPLATE.md, feedback/, generations/gen-0.md (lists hello agent + hello skill), lineage.md (gen/0 row), evolver/genome-paths.txt, evolver/protected-paths.txt (contains evolution/evolve.json), regression/tasks/T01.md+T02.md, evolve.json}` and the `.gitignore` entries exist; no `azure-pipeline-genome.yml`; `git status` shows only untracked files and no tag until you answer yes. Run `/evolve init` again → `already initialised; nothing changed`. Spec AC-1, AC-8, BR-2, BR-3 and the two `.claude/`/duplicate-hook edge cases met.
- [x] Code review: the block template text is exactly the constraints you want every project to freeze; the constraint placement proposal is clear about the difference (inside the block = the evolver can never touch it; duties line = the evolver can rewrite it). ⚠️ Risk area: `init` writes a protected block that outranks every other instruction in that project.

---

## Step 6 — `/evolve` from the plugin proposes, shows, reverts, collects and scores exactly as today, in any initialised project

**Scope** *(all under `../claude-evolve-plugin/`)*:

- `commands/evolve.md` *(modify)* — front-matter `description`, `tools: [Bash, Read]`, `argument-hint: "init | propose (default; -Force, -SkipRegression, -Model <name>) | show [N] | revert N | collect | score [ref]"`; subcommand table: `propose` → `scripts/evolver/Invoke-Evolver.ps1 $ARGUMENTS`; `show [N]` → `Show-Generation.ps1 [-Generation N]`; `revert N` → confirmation in chat then `Revert-Generation.ps1 -Generation N -Confirm:$false`; `collect` → `scripts/feedback/Collect-DailyFeedback.ps1`; `score [ref]` → `scripts/regression/Invoke-Regression.ps1 -Ref <ref|HEAD>`; every command runs from the project root (`$PWD`) with the plugin-root resolution of Step 5; the "Report", "Never" sections and the cost note are today's text with `evolution/evolver/…` paths replaced by `<plugin root>/scripts/…` and `.state` paths kept project-relative; wording notes the task count comes from `evolution/regression/tasks/` (no longer "ten").
- `scripts/feedback/Collect-DailyFeedback.ps1` *(modify)* — prints `Transcripts: <dir> (derived|configured)` first so the owner sees which folder is scanned.
- `tests/Command.Tests.ps1` *(create)*, `tests/Feedback.Tests.ps1` *(modify)*.

**RED**:

- Test files: `../claude-evolve-plugin/tests/Command.Tests.ps1`, `tests/Feedback.Tests.ps1`
- Test methods: `EvolveCommand_FrontMatter_HasDescriptionToolsAndArgumentHintWithSixSubcommands`, `EvolveCommand_EveryScriptItNames_ExistsUnderPluginScripts` (parses `scripts/<…>.ps1` occurrences and `Test-Path`s them), `EvolveCommand_NeverReferencesProjectRelativeEnginePaths` (`evolution/evolver/*.ps1`, `evolution/lib`, `.claude/hooks` absent), `EvolveCommand_RevertSection_RequiresExplicitYesBeforeRunning`, `EvolveCommand_ContainsNoPushOrScheduleInstruction`, `CollectDaily_PrintsTranscriptDirAndWhetherDerivedOrConfigured`
- Failing-run command: `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests/Command.Tests.ps1 -Output Detailed"`

**GREEN**: as scoped.

**DB changes**: none.

**VERIFY**: plugin Pester suite green.

**REFACTOR** *(these instructions are for the executor, not the planner)*:

- Analyse the produced code with code-analysis.agent and fix any new issues before proceeding to the next step.
- Optional: any additional refactorings to improve code quality, maintainability, or align with patterns — but only after RED-GREEN-VERIFY is complete for this step. Do not refactor during RED-GREEN cycles, only after the feature slice is fully working and verified.

**AGENT PROOF**: plugin Pester suite green.

**🛑 HUMAN GATE**:

- [x] Behavioral verification (**live**, in the Step 5 throwaway project after you confirmed its `gen/0` commit + tag): `/evolve show` prints the lineage and the generated `gen-0.md`; `/evolve score gen/0` runs the two skeleton tasks with the real `claude` (2 calls) and prints `Score: n/2`; `/evolve collect` prints the derived transcript folder `…\.claude\projects\C--Temp-evolve-init` and processes the init session; `/evolve propose -SkipRegression` (a journal newer than gen/0 exists from the init session) ends in `COMMITTED gen/1`, `REFUSED`, or "proposed no change" — any of the three is the contract working; if committed, `/evolve revert 1` asks for confirmation, then commits with your identity and appends the `reverted` row. Spec AC-3 met.
- [x] Code review: the command never edits genome files, never pushes, never loops; the plugin-root resolution works both when `${CLAUDE_PLUGIN_ROOT}` is substituted and when it is not.

---

## Step 7 — The plugin is installable from its GitHub marketplace, its CI runs the Pester suite on Windows and Linux on every commit, and its README is the generalised owner's guide

**Scope** *(all under `../claude-evolve-plugin/`)*:

- `.github/workflows/pester.yml` *(create)* — `on: [push, pull_request]`; matrix `os: [windows-latest, ubuntu-latest]`; steps: checkout, `shell: pwsh` → `Install-Module Pester -MinimumVersion 5.7.1 -Force -SkipPublisherCheck`, `git config --global user.name ci; git config --global user.email ci@example.test` (the tests create repos), `Invoke-Pester -Path tests -CI` (fails the job on any failure).
- `.claude-plugin/marketplace.json` *(create)* — `{ "name": "claude-evolve-plugin", "description": "…", "owner": { "name": "Geoffrey", "email": "geoffrey@digiverse.be" }, "plugins": [ { "name": "evolve", "description": "…", "author": {…}, "source": "./" } ] }` (self-hosted marketplace form, docs-confirmed; Overview fact f).
- `README.md` *(modify — generalised from `evolution/README.md`)* — sections: What it is · Prerequisites (`pwsh` 7+, `git`, Claude Code CLI logged in) · Install (in a Claude Code session: `/plugin marketplace add geobarteam/claude-evolve-plugin`, `/plugin install evolve@claude-evolve-plugin`; upgrade with `/plugin marketplace update claude-evolve-plugin` then `/reload-plugins`; team setup via `enabledPlugins` + `extraKnownMarketplaces` in `.claude/settings.json`; the command is namespaced `/evolve:…`, see decision 6) · `/evolve init` walkthrough · Daily use (today's §1) · Asking for a generation (§3, paths and "n tasks") · Reading / undoing (§4–5) · `evolution/evolve.json` reference (spec table) · What the tooling never does (§6, plugin root + config added) · Troubleshooting (§7 + "hooks do not fire: is `pwsh` on PATH?") · Developing the plugin (`--plugin-dir`, `Invoke-Pester -Path tests`) · Upgrading (BR-4: the protected block is never rewritten).
- `LICENSE` *(create — MIT)*.
- Linux path hygiene *(modify across `hooks/**`, `scripts/**`, `tests/**`)*: every `Join-Path … '..\x\y.psm1'` and `'evolution\journal'` literal uses `/`; `Resolve-ClaudeCommand` applies the `.exe` filter only when `$IsWindows` (otherwise first `Application` named `claude`); `Get-TranscriptDir` uses `Join-Path $HOME '.claude/projects/<name>'`; hook `.ps1` files start with `#!/usr/bin/env pwsh`; `.gitattributes` `* text=auto eol=lf` + `*.ps1 text eol=lf`.
- `tests/Portability.Tests.ps1` *(create)*.

**RED**:

- Test file: `../claude-evolve-plugin/tests/Portability.Tests.ps1`
- Test methods: `Engine_NoBackslashPathLiteral_InHooksScriptsOrTests` (regex `'[^']*\\[^']*\.(psm1|ps1|md|jsonl?)'` and `\\evolution\\`), `ResolveClaudeCommand_ExplicitCommand_ReturnedUnchanged`, `ResolveClaudeCommand_ClaudeCliEnvSet_Wins`, `ResolveClaudeCommand_ExeFilter_OnlyOnWindows` (function source contains `$IsWindows` guard), `MarketplaceJson_ListsEvolvePluginWithOwnerAndSource`, `Workflow_RunsPesterOnWindowsAndUbuntuWithPwsh`, `ReadmeInstallSection_NamesMarketplaceAndPluginAndConfigKeys` (every `evolve.json` key appears in the README)
- Failing-run command: `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests/Portability.Tests.ps1 -Output Detailed"`

**GREEN**: as scoped; tag `v0.1.0` is **your** act after the gate (the agent tags nothing in the plugin repo).

**DB changes**: none.

**VERIFY**: plugin Pester suite green locally (Windows).

**REFACTOR** *(these instructions are for the executor, not the planner)*:

- Analyse the produced code with code-analysis.agent and fix any new issues before proceeding to the next step.
- Optional: any additional refactorings to improve code quality, maintainability, or align with patterns — but only after RED-GREEN-VERIFY is complete for this step. Do not refactor during RED-GREEN cycles, only after the feature slice is fully working and verified.

**AGENT PROOF**: plugin Pester suite green.

**🛑 HUMAN GATE**:

- [x] Behavioral verification (done locally: `claude plugin validate` passes, the clone was added as marketplace `claude-evolve-plugin` and `evolve@claude-evolve-plugin` installed into the throwaway with `enabledPlugins`; hooks and journal work from the cache copy without `--plugin-dir`. **Still the owner's acts:** create the GitHub repo, push `main`, tag `v0.1.0`, confirm Actions green on both runners, then re-add the marketplace from GitHub) (**your acts, verifies assumptions d and e**): create the GitHub repository, push `main`, tag `v0.1.0`, push the tag; GitHub Actions shows the Pester job green on **both** `windows-latest` and `ubuntu-latest` (spec AC-4 and AC-9). Then on this machine, in a Claude Code session in the Step 5 throwaway project, run `/plugin marketplace add geobarteam/claude-evolve-plugin` and `/plugin install evolve@claude-evolve-plugin` (project scope); `~/.claude/plugins/installed_plugins.json` lists `evolve` with an `installPath` under the cache and the project's `.claude/settings.json` gains `enabledPlugins`; in the Step 5 throwaway project (without `--plugin-dir`) a session shows the injected memory and `/evolve show` works — `${CLAUDE_PLUGIN_ROOT}` substitution confirmed for hooks.
- [x] Code review: the workflow installs nothing but Pester and reaches no network beyond that; no test needs a logged-in `claude` (all use the shim); README states pwsh as a prerequisite and documents the actual command name.

---

## Step 8 — ⚠️ This repository consumes the plugin: engine files removed, hooks block gone from `.claude/settings.json`, state and history kept unchanged, `/evolve` and the five hooks work from the installed plugin

⚠️ **Risk areas, read before approving:** (1) this step edits files that are protected by this repo's own manifest (`.claude/settings.json`, `evolution/evolver/protected-paths.txt`, deletion of hooks and engine); that is an owner-approved change committed under **your** git identity, which the contract checker (`-OnlyIfAuthor evolver`) does not bind — the gate still runs the checker to prove the protected block is byte-identical. (2) `CLAUDE.md`'s `<!-- PROTECTED -->` block must not change by a single byte; only the duties section (outside the block) is edited. (3) The plugin must already be installed from the marketplace (Step 7 gate) before this step's live check.

**Scope** *(this repository only)*:

- `.claude/hooks/SessionStart.ps1`, `Stop.ps1`, `SessionEnd.ps1`, `UserPromptSubmit.ps1`, `PostToolUse.ps1` *(delete)*.
- `.claude/settings.json` *(modify)* — remove the `"hooks"` block; `permissions` untouched.
- `.claude/commands/evolve.md` *(delete — decision 4)*.
- `evolution/lib/` *(delete, 8 modules)*, `evolution/evolver/{Invoke-Evolver,Revert-Generation,Show-Generation,Test-GenomeContract}.ps1`, `evolution/evolver/prompt.md`, `evolution/evolver/rubric.md` *(delete)*, `evolution/regression/Invoke-Regression.ps1` *(delete)*, `evolution/feedback/Collect-DailyFeedback.ps1` *(delete)*, `evolution/tests/` *(delete, whole folder incl. `labelled/README.md`, fixtures, shim, `ContractRepo.psm1`, the two labelling scripts)*.
- `evolution/evolver/protected-paths.txt` *(modify)* — becomes: `evolution/evolve.json`, `evolution/evolver/genome-paths.txt`, `evolution/evolver/protected-paths.txt`, `evolution/regression/tasks/*.check.ps1`, `azure-pipeline-*.yml`, `.claude/settings.json` (every removed engine path dropped; no misleading globs). `genome-paths.txt` unchanged.
- `evolution/evolve.json` *(create — via `pwsh <installPath>/scripts/Initialize-Project.ps1 -ProjectRoot .`, then edited)* — `{ "evolverName": "evolver", "evolverEmail": "evolver@findmydoctor.local", "regression": { "allowedTools": "Read,Glob,Grep,Edit,Write,Bash(dotnet build *)" }, "mainLine": "dev" }` (all other keys default). `init` output must show `kept` for the block (BR-4 line expected: this block differs from the template), `MEMORY.md`, lineage, manifests, gen-0, tasks, and `created` only for `evolve.json` and the `.gitignore` entries.
- `.gitignore` *(modify)* — replace `evolution/tests/labelled/*` + `!evolution/tests/labelled/README.md` with `evolution/labelled/` (`evolution/.state/` stays).
- `evolution/README.md` *(modify)* — short pointer: engine and owner's guide live in `https://github.com/geobarteam/claude-evolve-plugin` (installed plugin `evolve`); what stays in this repo (journal, feedback, generations, lineage, manifests, tasks, `evolve.json`); `/evolve collect` replaces the old script path; classifier gate commands now `pwsh <plugin>/scripts/labelling/…`.
- `CLAUDE.md` *(modify, duties section only, lines 26–32)* — "Commit trailer" bullet: `evolution/feedback/Collect-DailyFeedback.ps1` → `the plugin's feedback collector (/evolve collect)`; "Read on start" bullet unchanged. **No change inside the protected block.**
- `azure-pipeline-genome.yml` *(modify — decision 3; skip if you chose "unchanged")* — the `pwsh` step becomes: `git clone --depth 1 --branch v0.1.0 https://github.com/geobarteam/claude-evolve-plugin.git "$(Agent.TempDirectory)/evolve-plugin"` then `& "$(Agent.TempDirectory)/evolve-plugin/scripts/evolver/Test-GenomeContract.ps1" -RepoPath "$(Build.SourcesDirectory)" -Base HEAD~1 -Head HEAD -OnlyIfAuthor evolver -ScanNotes`.
- `evolution/generations/gen-0.md`, `evolution/lineage.md`, `evolution/journal/**`, `evolution/feedback/*.jsonl`, `evolution/regression/tasks/**`, `MEMORY.md` — **untouched** (AC-7).
- `../claude-evolve-plugin/tests/Init.Tests.ps1` *(modify)* — the migration case is `Init_PartiallyInitialisedProject_CreatesOnlyMissingArtifacts` from Step 5; this step adds `Init_ProjectWithCustomProtectedBlock_KeepsItByteIdenticalAndReportsDiffers` (scaffold with this repo's exact block text → after `init` the block bytes are identical and the BR-4 line is printed).

**RED**:

- Test file: `../claude-evolve-plugin/tests/Init.Tests.ps1`
- Test method: `Init_ProjectWithCustomProtectedBlock_KeepsItByteIdenticalAndReportsDiffers`
- Failing-run command: `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests/Init.Tests.ps1 -Output Detailed"`
- Then, in this repo, the migration itself is verified by observable behaviour (gate) rather than by a test in this repo: the repo no longer has a Pester suite by design (AC-7).
- Executor's note: the test passed on first run — the byte-identity guarantee already came with Step 5's `Add-ProtectedBlock`/`Compare-ProtectedBlock`; it stays as the regression net for the migration case (188 tests in the plugin).

**GREEN**: run `init` from the **installed** plugin path (not the clone) against this repo; apply the deletions and edits as scoped; commit as `chore(evolve): consume the evolve plugin; remove the in-repo engine (AC-7)` with the Claude trailer, on `ai-evolution`.

**DB changes**: none.

**VERIFY**: plugin Pester suite green **and, once, the .NET trio** (`dotnet build src/FindMyDoctorWasm.sln`, `.\src\Test\Unit\bin\Debug\net10.0\Nihdi.FindMyDoctorWasm.Unit.Tests.exe`, `dotnet format src/FindMyDoctorWasm.sln --verify-no-changes`) — proof that no `src/` file changed (decision 1).

**REFACTOR** *(these instructions are for the executor, not the planner)*:

- Analyse the produced code with code-analysis.agent and fix any new issues before proceeding to the next step.
- Optional: any additional refactorings to improve code quality, maintainability, or align with patterns — but only after RED-GREEN-VERIFY is complete for this step. Do not refactor during RED-GREEN cycles, only after the feature slice is fully working and verified.

**AGENT PROOF**: plugin Pester suite green; .NET trio green; `git diff <pre-migration sha> -- evolution/journal evolution/feedback/*.jsonl evolution/generations evolution/lineage.md evolution/regression/tasks MEMORY.md evolution/evolver/genome-paths.txt` is empty; `git diff <pre-migration sha> -- CLAUDE.md` touches only the duties bullet.

**🛑 HUMAN GATE**:

- [ ] Behavioral verification: (a) `pwsh <installPath>/scripts/evolver/Test-GenomeContract.ps1 -RepoPath . -Base <pre-migration sha> -Head HEAD` (without `-OnlyIfAuthor`) lists violations **only** for the intended protected/engine paths and never `protected block of CLAUDE.md changed`; `git diff gen/0 -- CLAUDE.md | Select-String PROTECTED` shows no hunk inside the block. (b) A new Claude Code session in **this** repo (plugin installed, no `--plugin-dir`, no `.claude/hooks`): the first answer shows `MEMORY.md` and the last three journals; the turn is blocked until this session's journal exists; `/evolve show` prints `gen/0` from this repo's lineage; `/evolve collect` scans `…\.claude\projects\d--Data-gv10141-Repos-Common-FindMyDoctor-Wasm` (derived, no config key needed); `/evolve score gen/0 -Only T01` scores this repo's own seed. (c) `pwsh -NoProfile -Command "Invoke-Pester -Path ../claude-evolve-plugin/tests"` reports every test passed (≥ 102). Spec AC-7 and AC-2/AC-3 for this repository met.
- [ ] Code review: `evolution/evolver/protected-paths.txt` lists only files that exist; `evolution/evolve.json` values (identity unchanged, `dotnet build` allow-list, `mainLine` `dev`); the `.claude/settings.json` diff removes exactly the `hooks` block; the pipeline edit (if chosen) pins `v0.1.0`; no leftover reference to `evolution/lib`, `.claude/hooks` or `evolution/tests` anywhere in `CLAUDE.md`, `.github/`, `.claude/` (grep). ⚠️ Risk areas as listed at the top of this step.
