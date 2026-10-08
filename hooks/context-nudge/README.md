# context-nudge

A `UserPromptSubmit` hook that tells the model, once, when the session's context has
grown large enough that a fresh session would be cheaper and sharper.

## Why

On 1M-token context models, auto-compaction starts near ~967k tokens. That means a
session can run for hours at 400k–900k context, and **every call re-reads all of it**:
cost and latency scale with context, and instruction-following degrades in very long
contexts. Nothing in the default harness tells you this is happening.

Measured on my own usage over 30 days, before this hook: median main-session call at
~370k context, and most main-thread input tokens came from calls above 400k.

## Design

- **Speaks only at a natural boundary.** It fires when the user sends a prompt, never
  mid-tool-loop, so a long build is never interrupted.
- **Never compacts, never blocks.** It adds `additionalContext` for the model (write a
  handoff to `docs/build-state.md` or `tasks/todo.md` *if this prompt starts a new
  task*, otherwise finish the current one) and a one-line `systemMessage` for the user.
- **Once per band per compaction.** Bands default to 400k and 700k
  (`CONTEXT_NUDGE_BANDS` overrides). A compaction re-arms them.
- **Measures the main chain only.** Context = `input + cache_read + cache_creation`
  from the latest main-chain assistant turn in the transcript. Subagent (sidechain)
  usage is ignored, and so are task notifications that arrive as prompts.

## Install

Included in the `verify-first` plugin ([install](../../README.md#install)). To wire it by hand instead:

```json
"UserPromptSubmit": [{ "hooks": [
  { "type": "command", "command": "bash ~/.claude/toolkit/hooks/context-nudge/context-nudge.sh", "timeout": 5 }
]}]
```

Requires `jq`, `python3`. `test.sh` runs 10 fixture cases against a synthetic transcript.
