# DECISIONS.md

Append-only stigmergy log. Subagents add one-line entries for decisions or assumptions they don't want to litigate in return text. Coordinator doesn't re-read this file during a stage; the next subagent glances at it before its task.

Format:
```
YYYY-MM-DD [stage-NN task-M] agent-id — one-line decision or assumption
```

Compaction: at stage boundaries, fold entries into `state.md`'s "Decisions taken that weren't in briefs" section, then truncate below the stage separator.

---

## Stage 02 (in progress)

<!-- new entries go above this line; keep the stage header last -->
