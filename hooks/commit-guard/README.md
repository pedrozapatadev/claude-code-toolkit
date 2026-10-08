# commit-guard

Two `PreToolUse` guardrails that stop the most expensive mistakes an agent can make with
files and git: committing a secret, and editing files it should never touch.

## pre-commit-gate.sh

Runs before any Bash call that contains `git … commit` and exits `2` (block) when the
commit would include:

- conflict markers,
- credential-shaped paths (`.env*`, `credentials`, `id_rsa`, `id_ed25519`, `*.pem`),
- secret-shaped strings in added lines (`sk-…`, `ghp_…`, `AKIA…`).

It warns, without blocking, on staged diffs over 400 lines.

### Why it parses the command line

A plain git `pre-commit` hook is the wrong layer for an agent. Agents write chained
commands, and at the moment a PreToolUse hook fires, **the index is still empty**:

```bash
git add .env && git commit -m "wip"       # nothing is staged yet when the hook runs
cd ../other-repo && git commit -am "fix"   # the commit targets a different repo than the cwd
git -C ~/proj -c user.name=x commit -m m   # -C and -c move the target
```

So the gate splits the command into simple commands (`lib/shellsplit.py`: quotes,
heredocs, continuations, `&& || ; |` and redirects), follows `cd`, `git -C` and `-c`,
and computes what the chain is *about to* stage: the pathspecs of earlier `git add`
calls, `commit -a`, and `commit <paths>`. It scans those files plus the existing staged
diff of every repo the chain commits to.

Two details matter for false positives:

- The key pattern must not be glued to a preceding word, so `task-aaaaaaaaaaaaaaaaaaaa` is not an `sk-` key.
- Heredoc bodies (a commit message *mentioning* a key) are not scanned as commands.

If the command cannot be parsed, it fails open to checking the cwd repo's staged diff,
so an exotic command never wedges the session.

## protected-files.sh

Runs before `Edit` and `Write`. Blocks writes to `.env*`, lock files, `node_modules/`,
`.git/` internals, `~/.ssh`, `~/.aws`, and anything named `credentials` or `secrets`.
Lock files change through the package manager, never by hand.

Parsing uses `jq`, with a `python3` fallback: if `jq` is missing or broken, an empty
parse must not silently disable the guard. The tests shadow `jq` with failing and empty
stubs to prove it.

## Files

| File | Role |
|---|---|
| `pre-commit-gate.sh` | Chain-aware commit gate. |
| `lib/shellsplit.py` | Best-effort splitter of a Bash command into simple commands. Not a shell parser; whatever it can't tokenize yields no segment, so callers fail open. |
| `protected-files.sh` | Edit/Write path guard. |
| `test.sh` | 33 fixture cases: chained adds, `cd` and `-C` targets, `commit -am`, heredoc messages, false-positive guards, `jq` failure fallbacks. |

## Install

Included in the `verify-first` plugin ([install](../../README.md#install)). To wire it by hand instead:

```json
"PreToolUse": [
  { "matcher": "Edit|Write", "hooks": [
    { "type": "command", "command": "bash ~/.claude/toolkit/hooks/commit-guard/protected-files.sh", "timeout": 5 } ] },
  { "matcher": "Bash", "hooks": [
    { "type": "command", "command": "bash ~/.claude/toolkit/hooks/commit-guard/pre-commit-gate.sh", "timeout": 10, "if": "Bash(*git*commit*)" } ] }
]
```

The `if` filter keeps the Python start-up off every other Bash call; the script repeats
the same check, so it is also safe to register without it.

## Limits

This is a seatbelt, not a secret scanner. Three high-signal patterns catch the common
agent mistake with almost no false positives. Run a real scanner (gitleaks, trufflehog)
in CI as well.
