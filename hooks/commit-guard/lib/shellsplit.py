"""Best-effort split of a Bash tool command into simple commands, for the PreToolUse guards.

Used by pre-commit-gate.sh. Not a shell parser: it handles quotes, line
continuations, unquoted newlines, heredoc bodies, `;` `&&` `||` `|` `( )` separators, and drops redirects.
Anything it cannot tokenise yields no segment, so callers fail open.
"""
import os
import re
import shlex

ASSIGN = re.compile(r'^[A-Za-z_][A-Za-z0-9_]*=')
HEREDOC = re.compile(r"<<-?\s*['\"]?([A-Za-z_][A-Za-z0-9_]*)['\"]?")
WRAPPERS = {'sudo', 'command', 'builtin', 'exec', 'nohup', 'time', 'env', 'nice', 'xargs'}
SEP = set(';&|()')


def logical_lines(cmd):
    """Split on unquoted newlines; join backslash-newline continuations; drop heredoc bodies."""
    lines, buf, quote, i, n = [], [], None, 0, len(cmd)
    while i < n:
        c = cmd[i]
        if quote:
            buf.append(c)
            if c == '\\' and quote == '"' and i + 1 < n:
                i += 1
                buf.append(cmd[i])
            elif c == quote:
                quote = None
        elif c == '\\' and i + 1 < n:
            i += 1
            if cmd[i] != '\n':
                buf.extend(('\\', cmd[i]))
        elif c in '\'"':
            quote = c
            buf.append(c)
        elif c == '\n':
            line = ''.join(buf)
            buf = []
            lines.append(line)
            for word in HEREDOC.findall(line):
                nl = cmd.find('\n', i + 1)
                while nl != -1 or i + 1 < n:
                    end = nl if nl != -1 else n
                    body = cmd[i + 1:end]
                    i = end
                    if body.strip() == word or nl == -1:
                        break
                    nl = cmd.find('\n', i + 1)
        else:
            buf.append(c)
        i += 1
    lines.append(''.join(buf))
    return [ln for ln in lines if ln.strip()]


def drop_redirects(seg):
    """Remove `< f`, `> f`, `2>&1`-style tokens so a redirect target is never read as an operand."""
    out, i = [], 0
    while i < len(seg):
        t = seg[i]
        nxt = seg[i + 1] if i + 1 < len(seg) else ''
        if t and set(t) <= set('<>&'):
            i += 2
        elif t.isdigit() and nxt and set(nxt) <= set('<>&'):
            i += 3
        else:
            out.append(t)
            i += 1
    return out


def segments(cmd):
    """List of token lists, one per simple command, in order."""
    segs = []
    for line in logical_lines(cmd):
        try:
            lex = shlex.shlex(line, posix=True, punctuation_chars=True)
            lex.whitespace_split = True
            lex.commenters = '#'
            toks = list(lex)
        except ValueError:
            continue
        cur = []
        for t in toks:
            if t and set(t) <= SEP:
                if cur:
                    segs.append(cur)
                cur = []
            else:
                cur.append(t)
        if cur:
            segs.append(cur)
    return [drop_redirects(s) for s in segs]


def strip_prefix(seg):
    """Drop leading VAR=value words and wrappers (sudo, env, command, xargs ...)."""
    i = 0
    while i < len(seg):
        t = seg[i]
        if ASSIGN.match(t) or os.path.basename(t) in WRAPPERS:
            i += 1
            if os.path.basename(t) in ('xargs', 'env', 'sudo', 'nice'):
                while i < len(seg) and seg[i].startswith('-'):
                    i += 1
        else:
            break
    return seg[i:]


def git_parts(seg):
    """(subcommand, -C directory or None, remaining args) for a segment that starts with git."""
    i, repo = 1, None
    while i < len(seg) and seg[i].startswith('-'):
        if seg[i] == '-C' and i + 1 < len(seg):
            repo = seg[i + 1]
            i += 2
        elif seg[i] in ('-c', '--git-dir', '--work-tree', '--namespace') and i + 1 < len(seg):
            i += 2
        else:
            i += 1
    return (seg[i] if i < len(seg) else ''), repo, seg[i + 1:]
