# verify-gate

A `Stop` hook that keeps the agent from ending its turn on a broken build, without ever
trapping the session.

When Claude tries to stop, `auto-verify.sh` runs the repo's `.claude/verify.sh`
(typecheck → lint → test). On failure it returns `{"decision": "block", "reason": ...}`,
so the failure text goes straight back to the model as its next instruction. The model
fixes the build and tries to stop again, and the fix is verified again too.

A real block, captured from the hook (path shortened):

```json
{
  "decision": "block",
  "reason": "auto-verify failed (~/code/app/.claude/verify.sh, exit 1; block 1 of at most 4 this turn). Fix before stopping (no passing run is on record for this repo yet, so every error counts):\nverify: typecheck FAIL - exit 2 after 3s (npm run typecheck)\nsrc/cart.ts(14,7): error TS2322: Type 'string' is not assignable to type 'number'."
}
```

It is opt-in per repo: a repo without `.claude/verify.sh` is never touched.

## Why

"Run the tests before you say you're done" is a prompt, and prompts get skipped under
pressure, especially late in a long session. A hook is deterministic. The hard part is
not blocking; it is blocking **only when the block is useful**. A naive Stop-gate fails
in four ways, and this one is built around each of them:

| Failure mode of a naive gate | What this hook does |
|---|---|
| **Infinite loop.** The model can't fix the error, so the gate blocks forever. | The 3rd *identical* failure (fingerprinted after stripping line numbers, timestamps and durations) **releases** the stop, logs `released-cap`, and baselines those lines so the next turn isn't trapped again. |
| **Whack-a-mole.** Every fix surfaces a *different* error, so the identical-failure cap never trips. | A per-turn chain cap: the 5th consecutive block in one turn releases (`AUTO_VERIFY_CHAIN_CAP`) and logs `released-chain`. |
| **Gate that checks once.** Skipping the check whenever `stop_hook_active` is set (the usual loop guard) means the fix itself is never verified. | `stop_hook_active` only continues the block chain. The fix runs through `verify.sh` like any other change. |
| **Hung verify.** A watch-mode test runner or a slow build holds the session. | The run gets a hard 100 s budget (under the hook's 120 s timeout) and kills the whole process group on expiry. A timeout releases the stop: a slow machine proves nothing is broken. |
| **Blaming the agent for old debt.** The repo was already red before this session. | Errors located in files unchanged since the last verified `HEAD` are scoped out as pre-existing. Understands `tsc`, `path:line:col` and eslint-stylish output. |
| **Verify on every turn.** Re-running a 60 s suite after a reply that touched nothing. | Skips only when the set of changed files is the one last verified and nothing in it is newer. A new file inside a new folder, a delete-only turn, and a turn that *committed* its changes (diffed against the last verified SHA) are all still verified. |

Why not rely on Claude Code's own loop protection? The built-in cap ends the turn after
8 consecutive Stop-hook continuations, but [the count resets each time Claude calls a
tool](https://code.claude.com/docs/en/hooks#stop-input). An agent attempting fixes calls
tools every round, so that cap never trips. The identical-failure release and the
per-turn chain cap are what bound it.

All state lives under `~/.claude/state/stop-gate/`, never in the repo.

## Files

| File | Role |
|---|---|
| `auto-verify.sh` | The Stop hook. Decides whether to run, runs, reports. |
| `lib/stop-gate.sh` | Shared plumbing: portable timeout, output normalization, fingerprinting, the 3-strike counter, baseline, scoping. Reusable by any other Stop-gate (e.g. a typecheck-only gate). |
| `verify.sh` | Template for `<repo>/.claude/verify.sh`. Two tiers: default (≤80 s: typecheck, lint, test) and `VERIFY_FULL=1` (adds e2e and build, for pre-push). Missing steps print `SKIP` out loud, never silently. |
| `test.sh` | 39 assertions over 11 scenarios, in a sandboxed `HOME` with temp git repos: pass, debounce, block, identical-failure release, timeout, pre-existing scoping, commit-turn, re-verification after a block, chain cap, new folders, delete-only turns. |

## Install

Included in the `verify-first` plugin ([install](../../README.md#install)). To wire it by hand instead:

```bash
cp verify.sh <your-repo>/.claude/verify.sh     # then tune it per project
```

Register the hook (see [`settings.example.json`](../../settings.example.json)):

```json
"Stop": [{ "matcher": "*", "hooks": [
  { "type": "command", "command": "bash ~/.claude/toolkit/hooks/verify-gate/auto-verify.sh", "timeout": 120 }
]}]
```

Requires `bash`, `git`, `jq`, `perl`. The `verify.sh` template assumes a Node project
(npm, pnpm or yarn); any script that exits non-zero on failure works.

## Limits

- `verify.sh` is the definition of done, so an agent that edits it could switch the gate off. [protected-files](../commit-guard/) makes every Edit/Write to it ask for approval. A Bash redirect still bypasses that, so review diffs to `.claude/verify.sh`.
- A cloned repo's `.claude/verify.sh` runs at the end of every turn that changes source files. Read it before working in a repo you don't trust.
- Only file extensions typical of web projects count as "source changed" (`ts`, `tsx`, `js`, `css`, `astro`, `svelte`, `vue`, `html`, …). Adjust the regex in `auto-verify.sh` for other stacks.
- Pre-existing scoping works on errors that name a file. Unlocated output (a crashed test runner) always counts against the current change.
