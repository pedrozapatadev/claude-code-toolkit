#!/bin/bash
# PreToolUse(Bash) hook: deterministic pre-commit gate.
# Registered with `if: "Bash(*git*commit*)"` (settings.json); the case below is the same filter for direct runs.
# Exit 2 = block. Blocks: staged conflict markers, credential-shaped paths, obvious secrets, in
#   - the staged diff of every repo a `git commit` in the command targets (`git -C <dir> commit`, `git -c k=v commit`,
#     `cd <dir> && git commit` all resolve to their repo), and
#   - what the same command line stages first: the pathspecs of earlier `git add` calls in the chain (`git add -f`
#     also lists gitignored files), and `commit -a` / `commit <paths>` (tracked modified files), because in
#     `git add x && git commit` the index is still empty when this hook runs.
#   `bash|sh|zsh|dash -c STR` and `eval STR` wrappers are parsed in place (3 levels deep).
#   A command that stages more than 5000 files (or 64 MB of text) is blocked: it cannot be scanned within the hook timeout.
# Warns (exit 0, stderr): oversized diffs (staged + pending, >400 lines). Fails open if the command cannot be parsed.
# Input is read with jq; python3 is the fallback when jq is missing, fails, or returns nothing.

INPUT=$(cat)

# One field of the hook JSON ($1 = command | cwd): jq first, python3 if jq is absent, fails, or yields empty.
json_field() {
    local v
    case "$1" in
        command) v=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // ""' 2>/dev/null) ;;
        *) v=$(printf '%s' "$INPUT" | jq -r '.cwd // ""' 2>/dev/null) ;;
    esac
    if [ -z "$v" ] && [ -n "$INPUT" ]; then
        v=$(printf '%s' "$INPUT" | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    v = d["tool_input"]["command"] if sys.argv[1] == "command" else d["cwd"]
    print(v if isinstance(v, str) else "")
except Exception:
    print("")
' "$1" 2>/dev/null)
    fi
    printf '%s' "$v"
}

CMD=$(json_field command)

# Fast path: no "git ... commit" anywhere → allow immediately
case "$CMD" in
    *git*commit*) ;;
    *) exit 0 ;;
esac

CWD=$(json_field cwd)
[ -z "$CWD" ] && CWD=$(pwd)
LIB="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib"

# Portable (ERE, no grep -P): the key must not be glued to a preceding word, so `task-…` text is not an sk- key.
SECRET_RE='(^|[^A-Za-z0-9_])(sk-[A-Za-z0-9_-]{20,}|ghp_[A-Za-z0-9]{20,}|AKIA[0-9A-Z]{16})'
# Credential-shaped paths: .env and .env.* (but not the .example/.sample/.template files), a path component named
# credentials or credentials.<ext>, ssh private keys, *.pem.
CRED_PATH_RE='(^|/)\.env($|\.)|(^|/)credentials(\.[^/]+)?(/|$)|id_rsa|id_ed25519|\.pem$'
CRED_OK_RE='(^|/)\.env\.(example|sample|template)$'
TAB=$(printf '\t')
cred_paths() { grep -Ev "$CRED_OK_RE" | grep -E "$CRED_PATH_RE" | head -5; }

# Plan: one line per fact, tab separated. `OK` first = parsed. `R<TAB>repo` = a commit target; then, for what the
# command is about to stage: `P<TAB>path` (relative to the repo top), `S<TAB>path` (holds a secret-shaped string),
# `N<TAB>repo<TAB>count` (added lines), `X<TAB>files|bytes<TAB>n` (over the scan cap).
PLAN_PY=$(cat <<'PY'
import os, re, subprocess, sys

sys.path.insert(0, sys.argv[2])
from shellsplit import git_parts, inner_command, segments, strip_prefix

SECRET = re.compile(sys.argv[3])
OPT_WITH_VALUE = {'-m', '-F', '-C', '-c', '-t', '--message', '--file', '--author', '--date', '--template',
                  '--reuse-message', '--reedit-message', '--fixup', '--squash', '--cleanup', '-S', '--gpg-sign'}
MAX_FILES, MAX_BYTES, MAX_TOTAL, MAX_DEPTH = 5000, 1 << 20, 64 << 20, 3
HUNK = re.compile(r'^@@ -\d+(?:,(\d+))? \+\d+(?:,(\d+))? @@')
ESCAPES = {'a': 7, 'b': 8, 'f': 12, 'n': 10, 'r': 13, 't': 9, 'v': 11, '\\': 92, '"': 34}


def git(repo, *args, **kw):
    try:
        r = subprocess.run(['git', '-C', repo] + list(args), capture_output=True, timeout=kw.get('timeout', 5))
    except (OSError, subprocess.SubprocessError):
        return ''
    return r.stdout.decode('utf-8', 'replace') if r.returncode == 0 else ''


def resolve(base, arg):
    arg = os.path.expanduser(arg) if arg else ''
    return os.path.normpath(os.path.join(base, arg)) if arg else base


def add_files(repo, update_only, paths, force=False):
    """Paths (relative to the repo top) that `git add <paths>` would stage; `force` also lists gitignored files."""
    flags = ['-m'] if update_only else ['-m', '-o'] if force else ['-m', '-o', '--exclude-standard']
    out = git(repo, 'ls-files', '-z', '--full-name', *flags, '--', *(paths or [':/']), timeout=8)
    return {p for p in out.split('\0') if p and not p.endswith('/')}


def unquote(p):
    """Undo git's C-style quoting of a path in a diff header."""
    if not (len(p) >= 2 and p[0] == '"' and p[-1] == '"'):
        return p
    s, out, i = p[1:-1], bytearray(), 0
    while i < len(s):
        c = s[i]
        if c == '\\' and i + 1 < len(s):
            i += 1
            if s[i] in '01234567':
                j = i
                while j < min(i + 3, len(s)) and s[j] in '01234567':
                    j += 1
                out.append(int(s[i:j], 8) & 255)
                i = j
                continue
            out.append(ESCAPES.get(s[i], ord(s[i])))
        else:
            out.extend(c.encode('utf-8'))
        i += 1
    return out.decode('utf-8', 'replace')


def parse_diff(text):
    """{path: [added lines]} from `git diff -U0`; hunk headers say how many body lines to take, so an added line
    that looks like a `+++ b/x` header is not misread."""
    out, cur, add, rem = {}, None, 0, 0
    for ln in text.split('\n'):
        if add or rem:
            if ln.startswith('+') and add:
                add -= 1
                if cur is not None:
                    out[cur].append(ln[1:])
                continue
            if ln.startswith('-') and rem:
                rem -= 1
                continue
            if ln.startswith('\\'):
                continue
            add = rem = 0
        m = HUNK.match(ln)
        if m:
            rem = int(m.group(1) if m.group(1) is not None else 1)
            add = int(m.group(2) if m.group(2) is not None else 1)
        elif ln.startswith('+++ '):
            name = unquote(ln[4:].rstrip('\t'))
            cur = name[2:] if name.startswith('b/') else None
            if cur is not None:
                out.setdefault(cur, [])
    return out


def scan(repo, top, rels):
    """P = file about to be staged, S = it holds a secret-shaped string, N = added lines in total, X = over a cap."""
    for rel in rels:
        print('P\t' + rel)
    tracked = set(git(top, 'ls-files', '-z', timeout=8).split('\0'))
    diff = None
    if any(r in tracked for r in rels) and git(top, 'rev-parse', '--verify', '-q', 'HEAD').strip():
        diff = parse_diff(git(top, 'diff', 'HEAD', '-U0', '--no-color', '--no-ext-diff', '--no-renames',
                              '--src-prefix=a/', '--dst-prefix=b/', timeout=8))
    total_bytes = lines = 0
    for rel in rels:
        if diff is not None and rel in tracked:
            text = '\n'.join(diff.get(rel, []))
            n = len(diff.get(rel, []))
        else:
            path = os.path.join(top, rel)
            try:
                if os.path.islink(path) or os.path.getsize(path) > MAX_BYTES:
                    continue
                with open(path, 'rb') as fh:
                    data = fh.read()
            except OSError:
                continue
            if b'\0' in data:
                continue
            text = data.decode('utf-8', 'replace')
            n = text.count('\n') + (0 if not text or text.endswith('\n') else 1)
        total_bytes += len(text)
        if total_bytes > MAX_TOTAL:
            print('X\tbytes\t%d' % total_bytes)
            return
        lines += n
        if SECRET.search(text):
            print('S\t' + rel)
    print('N\t%s\t%d' % (repo, lines))


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


def add_options(rest):
    """(flags, pathspecs, force) for the arguments after `git add`."""
    flags, paths, force, after_dd = set(), [], False, False
    for a in rest:
        if after_dd:
            paths.append(a)
        elif a == '--':
            after_dd = True
        elif a.startswith('--'):
            flags.add(a)
            force = force or a == '--force'
        elif a.startswith('-') and len(a) > 1:
            flags.update('-' + ch for ch in a[1:])
            force = force or 'f' in a[1:]
        else:
            paths.append(a)
    return flags, paths, force


def on_commit(st, repo, rest):
    print('R\t' + repo)
    top = git(repo, 'rev-parse', '--show-toplevel').strip()
    if not top:
        return
    all_flag, cpaths = commit_options(rest)
    todo = set()
    for arepo, upd, paths, force in st['adds']:
        if git(arepo, 'rev-parse', '--show-toplevel').strip() == top:
            todo.update(add_files(arepo, upd, paths, force))
    if all_flag:
        todo.update(add_files(repo, True, []))
    if cpaths:
        todo.update(add_files(repo, True, cpaths))
    if len(todo) > MAX_FILES:
        print('X\tfiles\t%d' % len(todo))
        return
    scan(repo, top, sorted(todo))


def process(cmd, st, depth):
    for seg in segments(cmd):
        s = strip_prefix(seg)
        if not s:
            continue
        inner = inner_command(s)
        if inner is not None:   # bash -c STR / eval STR: same chain, same cwd
            if depth < MAX_DEPTH:
                saved = st['cur']
                process(inner, st, depth + 1)
                st['cur'] = saved
            continue
        if s[0] in ('cd', 'pushd'):
            nxt = [a for a in s[1:] if not a.startswith('-')]
            st['cur'] = resolve(st['cur'], nxt[0]) if nxt else st['cur']
            continue
        if os.path.basename(s[0]) != 'git':
            continue
        sub, dash_c, rest = git_parts(s)
        repo = resolve(st['cur'], dash_c)
        if sub == 'add':
            flags, paths, force = add_options(rest)
            upd = bool(flags & {'-u', '--update'}) and not (flags & {'-A', '--all'})
            whole = bool(flags & {'-A', '--all', '-u', '--update'})
            st['adds'].append((repo, upd, paths if paths or not whole else [':/'], force))
        elif sub == 'commit':
            on_commit(st, repo, rest)


def main():
    print('OK')
    process(sys.stdin.read(), {'cur': sys.argv[1], 'adds': []}, 0)


try:
    main()
except Exception:
    pass
PY
)

PLAN=$(printf '%s' "$CMD" | python3 -c "$PLAN_PY" "$CWD" "$LIB" "$SECRET_RE" 2>/dev/null)
REPOS=$(printf '%s\n' "$PLAN" | grep "^R${TAB}" | cut -f2- | sort -u)
case "$PLAN" in
    OK*) [ -n "$REPOS" ] || exit 0 ;;   # parsed, and no commit in it (e.g. `git log --grep commit`)
    *) REPOS="$CWD" ;;                  # could not parse: check the cwd repo's staged diff as before
esac

# Over the scan cap: cannot vouch for it
OVER=$(printf '%s\n' "$PLAN" | grep "^X${TAB}" | head -1)
if [ -n "$OVER" ]; then
    case "$OVER" in
        "X${TAB}files${TAB}"*) echo "BLOCKED: this command stages more than 5000 files (${OVER##*${TAB}}); commit in smaller batches or scan with a dedicated secret scanner." >&2 ;;
        *) echo "BLOCKED: this command stages more than 64 MB of text; commit in smaller batches or scan with a dedicated secret scanner." >&2 ;;
    esac
    exit 2
fi

# Content the command is about to stage (pathspecs of the chain's git add, commit -a), not yet in the index
PENDING_PATHS=$(printf '%s\n' "$PLAN" | grep "^P${TAB}" | cut -f2-)
PENDING_SECRETS=$(printf '%s\n' "$PLAN" | grep "^S${TAB}" | cut -f2- | sort -u | head -5)

while IFS= read -r REPO; do
    [ -n "$REPO" ] || continue
    git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1 || continue

    # 1) Conflict markers in staged content
    if git -C "$REPO" diff --cached --check 2>/dev/null | grep -q "conflict marker"; then
        echo "BLOCKED: staged changes contain conflict markers (git diff --cached --check). Resolve before committing." >&2
        exit 2
    fi

    # 2) Credential-shaped staged paths
    BAD_PATHS=$(git -C "$REPO" diff --cached --name-only 2>/dev/null | cred_paths)
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

    # 4) Oversized diff → warn only: staged insertions+deletions plus the lines this command is about to add
    STAGED_N=$(git -C "$REPO" diff --cached --numstat 2>/dev/null | awk '$1 ~ /^[0-9]+$/ {n += $1} $2 ~ /^[0-9]+$/ {n += $2} END {print n + 0}')
    PENDING_N=$(printf '%s\n' "$PLAN" | REPO_ENV="$REPO" awk -F'\t' '$1 == "N" && $2 == ENVIRON["REPO_ENV"] {n += $3} END {print n + 0}')
    CHANGED=$((STAGED_N + PENDING_N))
    if [ "$CHANGED" -gt 400 ]; then
        echo "WARNING: staged diff is ${CHANGED} lines (>400). Review it (or split it) before committing a change this size." >&2
    fi
done <<EOREPOS
$REPOS
EOREPOS

# Same checks 2 and 3 on what this command line stages itself
BAD_PENDING=$(printf '%s\n' "$PENDING_PATHS" | cred_paths)
if [ -n "$BAD_PENDING" ]; then
    echo "BLOCKED: this command stages paths that look like credentials/env files:" >&2
    echo "$BAD_PENDING" >&2
    exit 2
fi
if [ -n "$PENDING_SECRETS" ]; then
    echo "BLOCKED: files this command stages (git add / commit -a) contain secret-shaped strings (API key patterns). Remove them and use env vars:" >&2
    echo "$PENDING_SECRETS" >&2
    exit 2
fi

exit 0
