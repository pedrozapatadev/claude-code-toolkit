#!/bin/bash
# PreToolUse(Bash) hook: deterministic pre-commit gate.
# Registered with `if: "Bash(*git*commit*)"` (settings.json); the case below is the same filter for direct runs.
# Exit 2 = block. Blocks: staged conflict markers, credential-shaped paths, obvious secrets, in
#   - the staged diff of every repo a `git commit` in the command targets (`git -C <dir> commit`, `git -c k=v commit`,
#     `cd <dir> && git commit` all resolve to their repo), and
#   - what the same command line stages first: the pathspecs of earlier `git add` calls in the chain, and `commit -a`
#     / `commit <paths>` (tracked modified files), because in `git add x && git commit` the index is still empty when
#     this hook runs.
# Warns (exit 0, stderr): oversized staged diffs. Fails open if the command cannot be parsed.

INPUT=$(cat)
CMD=$(echo "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null)

# Fast path: no "git ... commit" anywhere → allow immediately
case "$CMD" in
    *git*commit*) ;;
    *) exit 0 ;;
esac

CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -z "$CWD" ] && CWD=$(pwd)
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# Portable (ERE, no grep -P): the key must not be glued to a preceding word, so `task-…` text is not an sk- key.
SECRET_RE='(^|[^A-Za-z0-9_])(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})'
CRED_PATH_RE='(^|/)\.env($|\.)|credentials|id_rsa|id_ed25519|\.pem$'
TAB=$(printf '\t')

# Plan: one line per fact, tab separated. `OK` first = parsed. `R<TAB>repo` = a commit target; `P<TAB>path` and
# `L<TAB>path<TAB>line` = a file/added line that the command is about to stage.
PLAN_PY=$(cat <<'PY'
import os, re, subprocess, sys

sys.path.insert(0, sys.argv[2])
from shellsplit import git_parts, segments, strip_prefix

OPT_WITH_VALUE = {'-m', '-F', '-C', '-c', '-t', '--message', '--file', '--author', '--date', '--template',
                  '--reuse-message', '--reedit-message', '--fixup', '--squash', '--cleanup', '-S', '--gpg-sign'}
MAX_FILES, MAX_BYTES, MAX_LINES = 400, 1 << 20, 20000
emitted = [0]


def git(repo, *args):
    r = subprocess.run(['git', '-C', repo] + list(args), capture_output=True, timeout=5)
    return r.stdout.decode('utf-8', 'replace') if r.returncode == 0 else ''


def resolve(base, arg):
    arg = os.path.expanduser(arg) if arg else ''
    return os.path.normpath(os.path.join(base, arg)) if arg else base


def add_files(repo, update_only, paths):
    flags = ['-m'] if update_only else ['-m', '-o', '--exclude-standard']
    out = git(repo, 'ls-files', '--full-name', *flags, '--', *(paths or [':/']))
    return sorted({p for p in out.split('\n') if p})


def emit_file(top, rel):
    path = os.path.join(top, rel)
    print('P\t' + path)
    tracked = bool(git(top, 'ls-files', '--', rel).strip())
    if tracked:
        diff = git(top, 'diff', 'HEAD', '-U0', '--', rel) or git(top, 'diff', '-U0', '--', rel)
        lines = [ln[1:] for ln in diff.split('\n') if ln.startswith('+') and not ln.startswith('+++')]
    else:
        try:
            if os.path.getsize(path) > MAX_BYTES:
                return
            data = open(path, 'rb').read()
        except OSError:
            return
        if b'\0' in data:
            return
        lines = data.decode('utf-8', 'replace').split('\n')
    for ln in lines:
        if emitted[0] >= MAX_LINES:
            return
        emitted[0] += 1
        print('L\t%s\t%s' % (path, ln[:2000].replace('\t', ' ')))


def commit_options(rest):
    """(commit -a given, positional paths) for the arguments after `git commit`."""
    all_flag, paths, skip, after_dd = False, [], False, False
    for a in rest:
        if skip:
            skip = False
        elif after_dd:
            paths.append(a)
        elif a == '--':
            after_dd = True
        elif a.startswith('--'):
            all_flag = all_flag or a == '--all'
            skip = a in OPT_WITH_VALUE
        elif re.match(r'^-[A-Za-z]+$', a):
            for i, ch in enumerate(a[1:], 1):
                if ch == 'a':
                    all_flag = True
                elif ch in 'mFCctS':
                    skip = i == len(a) - 1 and ch != 'S'
                    break
        elif not a.startswith('-'):
            paths.append(a)
    return all_flag, paths


def main():
    cmd = sys.stdin.read()
    cur = sys.argv[1]
    adds = []
    print('OK')
    for seg in segments(cmd):
        s = strip_prefix(seg)
        if not s:
            continue
        if s[0] in ('cd', 'pushd'):
            nxt = [a for a in s[1:] if not a.startswith('-')]
            cur = resolve(cur, nxt[0]) if nxt else cur
            continue
        if os.path.basename(s[0]) != 'git':
            continue
        sub, dash_c, rest = git_parts(s)
        repo = resolve(cur, dash_c)
        if sub == 'add':
            flags = {a for a in rest if a.startswith('-') and a != '--'}
            upd = bool(flags & {'-u', '--update'}) and not (flags & {'-A', '--all'})
            whole = bool(flags & {'-A', '--all', '-u', '--update'})
            paths = [a for a in rest if not a.startswith('-')]
            adds.append((repo, upd, paths if paths or not whole else [':/']))
        elif sub == 'commit':
            print('R\t' + repo)
            top = git(repo, 'rev-parse', '--show-toplevel').strip()
            if not top:
                continue
            all_flag, cpaths = commit_options(rest)
            todo = set()
            for arepo, upd, paths in adds:
                if git(arepo, 'rev-parse', '--show-toplevel').strip() == top:
                    todo.update(add_files(arepo, upd, paths))
            if all_flag:
                todo.update(add_files(repo, True, []))
            if cpaths:
                todo.update(add_files(repo, True, cpaths))
            for rel in sorted(todo)[:MAX_FILES]:
                emit_file(top, rel)


try:
    main()
except Exception:
    pass
PY
)

PLAN=$(printf '%s' "$CMD" | python3 -c "$PLAN_PY" "$CWD" "$LIB" 2>/dev/null)
REPOS=$(printf '%s\n' "$PLAN" | grep "^R${TAB}" | cut -f2- | sort -u)
case "$PLAN" in
    OK*) [ -n "$REPOS" ] || exit 0 ;;   # parsed, and no commit in it (e.g. `git log --grep commit`)
    *) REPOS="$CWD" ;;                  # could not parse: check the cwd repo's staged diff as before
esac

# Content the command is about to stage (pathspecs of the chain's git add, commit -a), not yet in the index
PENDING_PATHS=$(printf '%s\n' "$PLAN" | grep "^P${TAB}" | cut -f2-)
PENDING_SECRETS=$(printf '%s\n' "$PLAN" | grep "^L${TAB}" | cut -f3- | grep -E "$SECRET_RE" | head -3)

while IFS= read -r REPO; do
    [ -n "$REPO" ] || continue
    git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || continue

    # 1) Conflict markers in staged content
    if git -C "$REPO" diff --cached --check 2>/dev/null | grep -q "conflict marker"; then
        echo "BLOCKED: staged changes contain conflict markers (git diff --cached --check). Resolve before committing." >&2
        exit 2
    fi

    # 2) Credential-shaped staged paths
    BAD_PATHS=$(git -C "$REPO" diff --cached --name-only 2>/dev/null | grep -E "$CRED_PATH_RE" | head -5)
    if [ -n "$BAD_PATHS" ]; then
        echo "BLOCKED: staged paths look like credentials/env files:" >&2
        echo "$BAD_PATHS" >&2
        exit 2
    fi

    # 3) Obvious secret patterns in staged additions
    SECRETS=$(git -C "$REPO" diff --cached 2>/dev/null | grep -E '^\+' | grep -E "$SECRET_RE" | head -3)
    if [ -n "$SECRETS" ]; then
        echo "BLOCKED: staged additions contain secret-shaped strings (API key patterns). Remove them and use env vars." >&2
        exit 2
    fi

    # 4) Oversized diff → warn only
    CHANGED=$(git -C "$REPO" diff --cached --shortstat 2>/dev/null | grep -oE '[0-9]+ insertion|[0-9]+ deletion' | grep -oE '[0-9]+' | paste -sd+ - | bc 2>/dev/null)
    if [ -n "$CHANGED" ] && [ "$CHANGED" -gt 400 ]; then
        echo "WARNING: staged diff is ${CHANGED} lines (>400). Review it (or split it) before committing a change this size." >&2
    fi
done <<EOREPOS
$REPOS
EOREPOS

# Same checks 2 and 3 on what this command line stages itself
BAD_PENDING=$(printf '%s\n' "$PENDING_PATHS" | grep -E "$CRED_PATH_RE" | head -5)
if [ -n "$BAD_PENDING" ]; then
    echo "BLOCKED: this command stages paths that look like credentials/env files:" >&2
    echo "$BAD_PENDING" >&2
    exit 2
fi
if [ -n "$PENDING_SECRETS" ]; then
    echo "BLOCKED: files this command stages (git add / commit -a) contain secret-shaped strings (API key patterns). Remove them and use env vars." >&2
    exit 2
fi

exit 0
