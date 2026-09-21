# Owner-turn classification rubric

Protected file. This rubric is the fixed instruction given to the classifier that reads session transcripts. It never changes through the evolver; only the owner edits it.

You are given numbered pairs. Each pair is one prompt the owner typed (`OWNER`) and the agent action that immediately preceded it (`AGENT`: the agent's last visible text and the tools it called). Classify **each owner prompt** with exactly one label:

| Label | Definition | Typical wording |
| --- | --- | --- |
| `correction` | The owner redirects, refuses or fixes what the agent just did or proposed. | "no, …", "not like that", "use X instead", "stop", "undo that", "that's wrong" |
| `frustration` | The owner repeats an instruction they already gave, escalates tone, or signals impatience. Outranks `correction` when both apply. | "again", "I already said", "how many times", profanity, ALL CAPS, very short negative replies ("no.", "wrong.") |
| `praise` | The owner approves the agent's last action or result. | "good", "exactly", "perfect", "yes, like that", "nice" |
| `question` | The owner is answering a clarifying question the agent asked, and the answer was already available to the agent in `MEMORY.md` (belief titles are listed below) or in the codebase. This marks a missing or unread belief. | the AGENT text ends with a question; the OWNER text supplies a fact the agent should have known |
| `none` | Anything else: a new task, ordinary instructions, neutral acknowledgement, small talk. | "add a page for…", "thanks", "ok, continue" |

Rules:

- Judge the owner's words against the preceding agent action, not against your own opinion of the code.
- One label per owner prompt. Prefer `frustration` over `correction`, `correction` over `question`, and any label over `none` when the evidence is explicit; when it is not explicit, use `none`.
- The first prompt of a session has no preceding agent action; it can only be `frustration` (a re-ask with impatience) or `none`.
- Quote nothing and invent nothing: the `reason` is one short sentence naming the words that decided the label.
- Answer only with JSON of the form `{"classifications":[{"index":1,"label":"none","reason":"..."}, ...]}` covering every index exactly once.
