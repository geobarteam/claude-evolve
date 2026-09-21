---
name: show
description: "Print the lineage and one generation note of this project (the latest by default, or gen/N). Read-only."
argument-hint: "[N]"
---
# /evolve:show — read the lineage and a generation note

Read-only. Run from the project root:

```powershell
pwsh -NoProfile -File "${CLAUDE_PLUGIN_ROOT}/scripts/evolver/Show-Generation.ps1" $ARGUMENTS
```

With a number (`/evolve:show 3`) pass it as `-Generation 3`; without one the latest generation is shown.
Print the output verbatim: the lineage table (`evolution/lineage.md`) followed by the note
(`evolution/generations/gen-N.md`). If the script says `No evolution/lineage.md yet.`, the project is not
initialised: point the owner to `/evolve:init`.

## Never

- Never edit the lineage or a note from here; never push.
