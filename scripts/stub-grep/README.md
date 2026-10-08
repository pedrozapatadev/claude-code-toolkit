# stub-grep

Fails when **added** lines contain stub markers: `TODO`, `FIXME`, `XXX`, `HACK`,
`not implemented`, `// stub`, `lorem ipsum`.

```bash
bash stub-grep.sh                 # vs the merge-base with main/master
bash stub-grep.sh --base HEAD~3   # vs any ref
```

Exit `0` clean, `1` stubs found (`file:line: text` on stdout), `2` usage error.

## Why

The most common way an agent "finishes" a task without finishing it is a placeholder:
a `// TODO: wire this up`, a function that throws `Not implemented`, lorem ipsum in a
component. Typecheck and lint pass on all of them.

A plain `grep -r TODO` is useless in a real repo, because it reports years of existing
debt. This script reports **only lines this change added**, across everything a
change can touch: committed since the base, staged, unstaged, and untracked files
(diffed against `/dev/null`, so every line of a new file counts).

Docs, lock files, snapshots, minified files, `node_modules`, and build output are
skipped. Tests are still scanned.

Use it as a step in `verify.sh` (see [verify-gate](../../hooks/verify-gate/)), in CI,
or as the "substantive, not stubs" check of the
[five-gates](../../skills/five-gates/) Verify gate.

`test.sh` runs 11 fixture cases (pre-existing TODOs ignored, staged and untracked
stubs caught, bad refs rejected).
