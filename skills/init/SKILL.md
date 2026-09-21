---
name: init
description: "Initialise this project for the evolve plugin: protected owner constraints and working-agent duties in CLAUDE.md, MEMORY.md, the evolution/ tree with a generated gen-0 inventory, evolve.json, regression task skeletons and the .gitignore entries. Idempotent; commits and tags gen/0 only after the owner's explicit yes."
argument-hint: "(no arguments; the skill asks its questions in the chat)"
---
# /evolve:init — set this project up for the self-evolving agent

You are running the owner-triggered initialisation of the evolve plugin. It writes **project state** into the
current repository; the engine itself stays in the plugin. Follow the steps in order and never skip a question.

## 1. Preconditions

- The current directory must be the project root and must contain `CLAUDE.md`. If it does not, stop and say
  `CLAUDE.md not found` — the owner creates it first (one line is enough).
- Say what the script will create (listed below) and that nothing is committed or tagged without a yes.

## 2. Questions to ask the owner, one at a time

1. **Hard constraints.** "Which project-specific hard constraints must the agent never break?" Give one example:
   *the WASM client never holds tokens*. Accept several, or none.
2. **Placement.** Propose the two safe places and explain the difference:
   - **inside the protected block** (`-ConstraintPlacement protected`): the evolver can never edit or remove them;
     they are frozen with the owner's other constraints. Recommended for security and data rules.
   - **as a duties line** (`-ConstraintPlacement duties`): visible to the agent, but the evolver may rewrite
     it in a later generation. Suitable for conventions that should be able to evolve.
   Show the resulting protected-block text (the template plus the constraints) and ask for confirmation.
3. **Regression seeds.** "Do you have regression tasks for this project (files under
   `evolution/regression/tasks/`)?" If none exist the script writes two skeleton tasks, T01 and T02, that the
   owner replaces later.
4. **CI template.** "Do you use Azure DevOps and want the genome-contract pipeline template
   (`azure-pipeline-genome.yml`)?" Default **no**; only pass `-IncludeCi` on an explicit yes.

## 3. Run the script

```powershell
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/Initialize-Project.ps1" -ProjectRoot "$PWD" [-Constraints "<c1>", "<c2>"] [-ConstraintPlacement protected|duties] [-IncludeCi]
```

Show its output verbatim: one `created` / `kept` line per artifact, any `warning:` lines (no `.claude/` folder,
duplicate hooks in `.claude/settings.json`, a protected block that differs from the plugin template), and the
closing line `initialised N artifact(s)` or `already initialised; nothing changed`.

## 4. Offer the baseline commit — only after an explicit yes

Ask: "Shall I commit these files as the baseline and tag it `gen/0`?" Only after the owner's explicit yes run,
with the owner's own git identity:

```powershell
git add CLAUDE.md MEMORY.md evolution .gitignore
git commit -m "chore(evolve): initialise the self-evolving agent (gen/0)"
git tag gen/0
```

Add `azure-pipeline-genome.yml` to the `git add` line only when it was created. Never push.

## Never

- Never run `git commit` or `git tag` without the explicit yes from step 4; never run `git push`.
- Never edit the protected block of an already initialised project; report the difference the script prints
  and leave it to the owner.
- Never pass constraints the owner did not state.
