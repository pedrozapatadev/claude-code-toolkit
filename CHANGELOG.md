# Changelog

Versions follow the `version` in `.claude-plugin/plugin.json`. Claude Code only offers a
plugin update when that version changes.

## 1.0.0 — 2026-10-08

First public release.

- **verify-gate** — Stop hook running `.claude/verify.sh`, with identical-failure and
  per-turn chain releases, timeout release, pre-existing-error scoping and re-verification
  after a block.
- **commit-guard** — chain-aware commit secret gate (handles `git add -f`, `bash -c` / `eval`
  wrappers and large commits), and protected-files, which asks before edits to
  `.claude/verify.sh` and hook settings.
- **workflow-lint** — every `agent()` pins its model, and every fan-out declares a width.
- **context-nudge** — one prompt-boundary hint per context band.
- **stub-grep** — stub markers in added lines only.
- **five-gates** skill and the **model-routing** rule.

Before release, a fresh-context adversarial review on a different model found these
issues in the first cut. Each is fixed with a regression test:

- verify-gate skipped the check whenever `stop_hook_active` was set, so a fix was never
  re-verified. It now re-verifies, bounded by a per-turn chain cap.
- `git status --porcelain` reports a new folder, not the files in it, so changes inside
  new folders were invisible. It now lists every untracked file. Delete-only turns are
  verified too.
- The commit gate could be bypassed with `git add -f`, `bash -c` / `eval` wrappers, a
  missing `jq`, or a secret beyond its file cap. Large commits could exceed the hook
  timeout and fail open. Git calls are now batched.
- An agent could edit `.claude/verify.sh` to switch the gate off. Edits to it now ask
  for approval.
- False positives on `.env.example` and on paths that merely contain "secrets" are fixed.
