# workflow-lint

A `PreToolUse` hook on Claude Code's `Workflow` tool, which runs a script that orchestrates
many subagents. Before the script runs, the hook checks two things:

- **Rule A — every `agent()` call pins its model.** The call's options must be an object
  literal with a `model:` key. An agent without one silently inherits the session model.
- **Rule B — every fan-out declares its width.** A script that calls `parallel()` or
  `pipeline()` must declare an UPPER_SNAKE constant such as `MAX_WORKERS = 4` or
  `CONCURRENCY = 3`.

```js
const MAX_SCOUTS = 6                                                      // Rule B
const hits = await parallel(files.slice(0, MAX_SCOUTS).map(f => () =>
  agent(`Find TODOs in ${f}`, { model: 'haiku', effort: 'low' })))        // Rule A
const verdict = await agent('Judge the findings', { model: 'opus' })      // Rule A
```

## Why

Model routing written down in a rule file is advisory. In a multi-agent script, the
default does the damage quietly: when I measured my own transcripts, agents with no
`model:` had inherited the session model and accounted for most workflow tokens. A
fan-out meant for the cheapest tier runs on the most expensive one, and nothing looks
wrong. Unbounded fan-out fails just as silently: cost and rate-limit pressure grow with a
width nobody chose.

The rule can only be enforced deterministically at the point where the script is about
to run.

## Design

- **A real tokenizer, not a regex.** The script is tokenized first: comments, strings,
  regex literals and template text never count, while code inside `${…}` does. So
  `agent(` inside a string or a comment is ignored, and `x.agent(` and `subagent(` are not
  agent calls.
- **A deliberate escape hatch.** A call that should inherit the session model (for example
  taste-critical work run on whatever strong model the session uses) carries the marker
  `/* model: session */`, inside the call or alone on the line above it. The exception is
  visible in the code, not implicit.
- **Three modes.** `WORKFLOW_LINT_MODE=warn` (the default) lets the run proceed and tells
  the model and the user what is unpinned. `reject` denies the tool call. `off` disables
  the hook.
- **Fails open.** Any internal error exits 0 with no output. Every linted call is logged to
  `~/.claude/state/workflow-lint.jsonl`, so the warn mode doubles as a measurement before
  you switch to `reject`.
- **Resolves every way a script arrives**: inline `script`, `scriptPath`, or a saved
  workflow `name` (looked up in the project's `.claude/workflows/`, then the repo root's,
  then `~/.claude/workflows/`; built-in names pass).

## Install

Included in the `verify-first` plugin ([install](../../README.md#install)). To wire it by hand instead:

```json
"PreToolUse": [{ "matcher": "Workflow", "hooks": [
  { "type": "command", "command": "bash ~/.claude/toolkit/hooks/workflow-lint/workflow-lint.sh", "timeout": 5 }
]}]
```

Requires `jq` and `python3` (standard library only). `test.sh` runs 58 cases: hook-level
cases (inline, path, saved name, the three modes, logging) plus a batch of tokenizer edge
cases (markers in comments, template literals, regex literals, look-alike calls).
