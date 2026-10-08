# Security

These hooks run shell commands with your user's permissions, on every matching tool call.
Read them before enabling them. Each one is short and commented for that reason.

## What the guardrails do and don't cover

- **commit-guard is a seatbelt, not a secret scanner.** It catches the common agent mistakes
  (committing `.env`, credential files, or `sk-` / `ghp_` / `AKIA` keys, including through
  `git add -f`, chained commands and `bash -c` / `eval` wrappers). It does not detect every
  credential format. Run a real scanner such as gitleaks or trufflehog in CI as well.
- **protected-files covers Edit and Write only.** A Bash redirect (`echo … > .env`) or
  `NotebookEdit` does not pass through it. Use Claude Code permission rules
  (`permissions.deny`) for paths that must never be written.
- **verify-gate runs the repo's own `.claude/verify.sh`.** In a cloned repo you don't trust,
  read that file first: it runs at the end of every turn that changes source files. An
  agent's Edit/Write to it asks for your approval.
- **Every hook fails open on its own errors** (missing tools, unparseable input), so a broken
  environment never wedges a session. The trade-off is that a guard can silently stand down.
  Run `./run-tests.sh` after changing your environment.

## Reporting

Please report a bypass or vulnerability through GitHub's private vulnerability reporting
(the repo's Security tab → "Report a vulnerability"), not in a public issue.
