---
name: revert
description: "Revert generation gen/N with the owner's git identity and record a 'reverted' row in the lineage. Asks for an explicit yes in the chat before anything runs. Never pushes."
argument-hint: "N"
---
# /evolve:revert — undo one generation

Reverting is the owner's act. Run from the project root.

## Steps

1. Show what would be reverted: run

   ```powershell
   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/evolver/Show-Generation.ps1" -Generation $ARGUMENTS
   ```

   and name the generation and its one-line summary.

2. Ask the owner to confirm in the chat. Only after an **explicit yes** run

   ```powershell
   pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/evolver/Revert-Generation.ps1" -Generation $ARGUMENTS -Confirm:$false
   ```

   and report its output. The revert is committed with the owner's git identity, keeps the tag, and appends a
   `reverted` row to `evolution/lineage.md`. The script refuses when the tag does not exist, when the lineage has
   uncommitted changes, or when the index already holds staged changes; report a refusal verbatim.

## Never

- Never run the revert without the explicit yes; never push; never delete the tag.
