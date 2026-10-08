# commit-guard

Two `PreToolUse` guardrails that stop the most expensive mistakes an agent can make with
files and git: committing a secret, and editing files it should never touch.

## pre-commit-gate.sh

Runs before any Bash call that contains `git … commit` and exits `2` (block) when the
commit would include:

- conflict markers,
- credential-shaped paths (`.env`, `.env.*` except `.env.example` / `.sample` / `.template`,
  a path component named `credentials` or `credentials.<ext>`, `id_rsa`, `id_ed25519`, `*.pem`),
- secret-shaped strings in added lines (`sk-…`, `ghp_…`, `AKIA…`); the message names the files,
- more than 5,000 files to scan at once (commit in batches, or use a dedicated scanner).

It warns, without blocking, when a commit adds or removes more than 400 lines, counting
what the same command line is about to stage.

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
calls (with `-f`, ignored files too), `commit -a`, and `commit <paths>`. Commands inside
`bash -c` / `sh -c` / `zsh -c` / `eval` are unwrapped and parsed the same way, up to three
levels deep. It scans those files plus the existing staged diff of every repo the chain
commits to.

Git is called a constant number of times per repo: one `ls-files`, one `diff -U0 HEAD`,
then untracked files are read from disk. A 600-file commit is checked in well under a
second. That matters because a PreToolUse hook that times out does not block.

Two details matter for false positives:

- The key pattern must not be glued to a preceding word, so `task-aaaaaaaaaaaaaaaaaaaa` is not an `sk-` key.
- Heredoc bodies (a commit message *mentioning* a key) are not scanned as commands.

If the command cannot be parsed, it falls back to checking the cwd repo's staged diff,
so an exotic command doesn't wedge the session. If `jq` is missing or broken, the input
is read with `python3` instead.

## protected-files.sh

Runs before `Edit` and `Write`. Blocks writes to `.env*` (templates like `.env.example`
are allowed), lock files, `node_modules/`, `.git/` internals, `~/.ssh`, `~/.aws`, and
credential stores by file name (`credentials.json`, `secrets.yaml`, `*.pem`; a source file
like `src/lib/secrets.ts` is allowed). Lock files change through the package manager,
never by hand.

Edits to `.claude/verify.sh` and `.claude/settings*.json` return
`permissionDecision: "ask"` instead: those files define how the agent is checked, so a
human approves each change.

Parsing uses `jq`, with a `python3` fallback: if `jq` is missing or broken, an empty
parse must not silently disable the guard. The tests shadow `jq` with failing and empty
stubs to prove it.

## Files

| File | Role |
|---|---|
| `pre-commit-gate.sh` | Chain-aware commit gate. |
| `lib/shellsplit.py` | Best-effort splitter of a Bash command into simple commands. Not a shell parser; whatever it can't tokenize yields no segment, so callers fail open. |
| `protected-files.sh` | Edit/Write path guard. |
| `test.sh` | 90 fixture cases: chained adds, `cd` and `-C` targets, `commit -am`, `add -f` on ignored files, `bash -c` / `eval` wrappers nested 3 deep, heredoc messages, a 600-file commit under 5 s, the 5,000-file block, false-positive guards, `jq` failure fallbacks, the approval prompt for `verify.sh`. |

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

- This is a seatbelt, not a secret scanner. Three high-signal key patterns catch the
  common agent mistake with few false positives, but other credential formats pass. Run
  a real scanner (gitleaks, trufflehog) in CI as well.
- Commands it cannot see into still pass: a commit run from inside a script file, wrappers
  nested more than three levels deep, or a git call that exceeds its own 8 s timeout on a
  very large repo.
- protected-files sees Edit and Write only. A Bash redirect or `NotebookEdit` bypasses it;
  use `permissions.deny` for paths that must never be written.
