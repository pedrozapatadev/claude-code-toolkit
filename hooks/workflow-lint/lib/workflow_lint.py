#!/usr/bin/env python3
"""workflow_lint.py - lint a Workflow-tool script (called by ../workflow-lint.sh; python3 stdlib only).

Rule A (pins): every agent(prompt, opts) call needs an object-literal opts containing a `model` key, or the marker
    /* model: session */   inside the call's argument text, on the same line before `agent(`,
or alone on the line above it. No opts, an identifier / spread / expression as opts, or opts without `model` is flagged.
Rule B (width): a script that calls parallel( or pipeline( must declare `const NAME = <...number...>` with NAME
UPPER_SNAKE and containing MAX, WIDTH, CONCURRENCY, LIMIT, CAP, WORKERS or PER_.

The script is tokenised first (comments, strings, regex literals and template text never count; code inside ${...}
does), so `agent(` in a comment or string is ignored and `x.agent(` / `subagent(` are not agent calls.

CLI:  workflow_lint.py --mode warn|reject --source name|path|inline [--file PATH]   (inline reads the script from stdin)
Prints one hook-output JSON object when there are findings, nothing when clean, appends a line to
$HOME/.claude/state/workflow-lint.jsonl, and ALWAYS exits 0 (fails open on any internal error).
"""
import bisect
import json
import os
import re
import sys
import time

MARKER_RX = re.compile(r"model:\s*session\b")
WIDTH_NAME_RX = re.compile(r"^[A-Z][A-Z0-9]*(?:_[A-Z0-9]+)*$")
WIDTH_WORDS = ("MAX", "WIDTH", "CONCURRENCY", "LIMIT", "CAP", "WORKERS", "PER_")
FANOUT_CALLS = frozenset(("parallel", "pipeline"))
OPEN = frozenset(("(", "[", "{"))
CLOSE = frozenset((")", "]", "}"))
# an identifier token after which a "/" starts a regex literal rather than a division
REGEX_AFTER_KW = frozenset(("return", "typeof", "instanceof", "in", "of", "new", "delete", "void", "throw", "case",
                            "do", "else", "yield", "await"))
# a token that, at the start of the next line, continues the previous statement (or, at the end of a line, awaits more)
CONTINUATION = frozenset(("||", "&&", "??", "+", "-", "*", "/", "%", "?", ":", ".", "?.", "==", "===", "!=", "!==", "<",
                          ">", "<=", ">=", "=>", "|", "&", "^", "**", "<<", ">>", "="))
OPS3 = frozenset(("...", "===", "!=="))
OPS2 = frozenset(("=>", "?.", "==", "!=", "<=", ">=", "&&", "||", "??", "++", "--", "+=", "-=", "*=", "%=", "&=", "|=",
                  "^=", "**", "<<", ">>"))
NUM_RX = re.compile(r"0[xX][0-9a-fA-F_]+n?|0[bB][01_]+n?|0[oO][0-7_]+n?"
                    r"|(?:\d[\d_]*(?:\.[\d_]*)?|\.\d[\d_]*)(?:[eE][+-]?\d[\d_]*)?n?")
IDENT_RX = re.compile(r"(?:[^\W\d]|\$)(?:\w|\$)*")

REASON_NO_OPTS = "has no opts argument, so there is no model: pin"
REASON_NOT_LITERAL = "opts is not an object literal (identifier, spread or expression), so model: cannot be verified"
REASON_NO_MODEL = "opts has no model: key"


class Tok(object):
    __slots__ = ("kind", "text", "pos", "line")

    def __init__(self, kind, text, pos, line):
        self.kind, self.text, self.pos, self.line = kind, text, pos, line


def isp(tok, text):
    return tok.kind == "p" and tok.text == text


class Lexer(object):
    """Splits JS source into code tokens; comments are collected separately. Lenient: never raises on bad input."""

    def __init__(self, src):
        self.s = src
        self.n = len(src)
        self.toks = []
        self.comments = []  # (start, end, text)
        self.line_starts = [0] + [m.end() for m in re.finditer("\n", src)]
        self.scan(0, False)

    def line_of(self, pos):
        return bisect.bisect_right(self.line_starts, pos)

    def line_bounds(self, line):
        start = self.line_starts[line - 1]
        end = self.line_starts[line] - 1 if line < len(self.line_starts) else self.n
        return start, end

    def add(self, kind, text, pos):
        self.toks.append(Tok(kind, text, pos, self.line_of(pos)))

    def regex_allowed(self):
        if not self.toks:
            return True
        t = self.toks[-1]
        if t.kind in ("num", "str", "tpl", "regex"):
            return False
        if t.kind == "id":
            return t.text in REGEX_AFTER_KW
        return t.text not in (")", "]", "++", "--")

    def regex_end(self, i):
        s, n = self.s, self.n
        j, in_class = i + 1, False
        while j < n:
            c = s[j]
            if c == "\n":
                return 0
            if c == "\\":
                j += 2
                continue
            if in_class:
                if c == "]":
                    in_class = False
            elif c == "[":
                in_class = True
            elif c == "/":
                j += 1
                while j < n and (s[j].isalnum() or s[j] in "_$"):
                    j += 1
                return j
            j += 1
        return 0

    def string_end(self, i):
        s, n = self.s, self.n
        quote, j = s[i], i + 1
        while j < n:
            c = s[j]
            if c == "\\":
                j += 2
                continue
            if c == quote:
                return j + 1, s[i + 1:j]
            if c == "\n":
                return j, s[i + 1:j]  # unterminated: stop at the newline
            j += 1
        return n, s[i + 1:n]

    def template(self, i):
        """Consume a template literal starting at the backtick; its ${...} code becomes ( tokens ) in the stream."""
        s, n = self.s, self.n
        self.add("tpl", "`", i)
        i += 1
        while i < n:
            c = s[i]
            if c == "\\":
                i += 2
            elif c == "`":
                return i + 1
            elif c == "$" and i + 1 < n and s[i + 1] == "{":
                self.add("p", "(", i)
                i = self.scan(i + 2, True)
                self.add("p", ")", min(i, n - 1))
                i += 1
            else:
                i += 1
        return n

    def scan(self, i, in_subst):
        """Tokenise code from i. In a ${...} substitution, return the index of its closing brace."""
        s, n = self.s, self.n
        depth = 0
        while i < n:
            c = s[i]
            if c.isspace() or c == "\ufeff":
                i += 1
                continue
            if c == "/":
                nxt = s[i + 1] if i + 1 < n else ""
                if nxt == "/":
                    j = s.find("\n", i)
                    j = n if j < 0 else j
                    self.comments.append((i, j, s[i:j]))
                    i = j
                    continue
                if nxt == "*":
                    j = s.find("*/", i + 2)
                    j = n if j < 0 else j + 2
                    self.comments.append((i, j, s[i:j]))
                    i = j
                    continue
                if self.regex_allowed():
                    j = self.regex_end(i)
                    if j:
                        self.add("regex", s[i:j], i)
                        i = j
                        continue
                self.add("p", "/", i)
                i += 1
                continue
            if c == "'" or c == '"':
                j, value = self.string_end(i)
                self.add("str", value, i)
                i = j
                continue
            if c == "`":
                i = self.template(i)
                continue
            if c.isdigit() or (c == "." and i + 1 < n and s[i + 1].isdigit()):
                m = NUM_RX.match(s, i)
                end = m.end() if m and m.end() > i else i + 1
                self.add("num", s[i:end], i)
                i = end
                continue
            m = IDENT_RX.match(s, i)
            if m:
                self.add("id", m.group(0), i)
                i = m.end()
                continue
            if c == "}" and in_subst and depth == 0:
                return i
            if c == "{":
                depth += 1
            elif c == "}":
                depth -= 1
            three, two = s[i:i + 3], s[i:i + 2]
            if three in OPS3:
                op = three
            elif two in OPS2 and not (two == "?." and i + 2 < n and s[i + 2].isdigit()):
                op = two
            else:
                op = c
            self.add("p", op, i)
            i += len(op)
        return n


def match_close(toks, i):
    """Index of the bracket closing the one at toks[i]; len(toks) when unbalanced."""
    depth = 0
    for j in range(i, len(toks)):
        t = toks[j]
        if t.kind == "p":
            if t.text in OPEN:
                depth += 1
            elif t.text in CLOSE:
                depth -= 1
                if depth == 0:
                    return j
    return len(toks)


def split_top(toks, open_idx, close_idx):
    """Token lists of the comma-separated items between toks[open_idx] and toks[close_idx] (top level only)."""
    items, cur, depth = [], [], 0
    for t in toks[open_idx + 1:close_idx]:
        if t.kind == "p":
            if t.text in OPEN:
                depth += 1
            elif t.text in CLOSE:
                depth -= 1
            elif t.text == "," and depth == 0:
                items.append(cur)
                cur = []
                continue
        cur.append(t)
    if cur or items:
        items.append(cur)
    if items and not items[-1]:
        items.pop()  # trailing comma
    return items


def find_calls(toks, names):
    """Yield (name_idx, open_idx, close_idx) for each call `name(` in code. Skips x.name(, function name( and name(){ ."""
    for k, t in enumerate(toks):
        if t.kind != "id" or t.text not in names or k + 1 >= len(toks) or not isp(toks[k + 1], "("):
            continue
        if k and toks[k - 1].kind == "p" and toks[k - 1].text in (".", "?."):
            continue  # method call (a spread `...agent(` is a separate token and still counts)
        if k and toks[k - 1].kind == "id" and toks[k - 1].text == "function":
            continue
        close = match_close(toks, k + 1)
        if close + 1 < len(toks) and isp(toks[close + 1], "{"):
            continue  # a method / function definition, not a call
        yield k, k + 1, close


def is_model_prop(prop):
    if not prop:
        return False
    t = prop[0]
    if t.kind in ("id", "str") and t.text == "model":
        return len(prop) == 1 or (prop[1].kind == "p" and prop[1].text in (":", "("))
    return len(prop) >= 3 and isp(t, "[") and prop[1].kind == "str" and prop[1].text == "model" and isp(prop[2], "]")


def opts_problem(arg):
    """None when the second agent() argument is an object literal with a model key, else the reason."""
    if arg is None:
        return REASON_NO_OPTS
    if not arg or not isp(arg[0], "{") or match_close(arg, 0) != len(arg) - 1:
        return REASON_NOT_LITERAL
    for prop in split_top(arg, 0, len(arg) - 1):
        if is_model_prop(prop):
            return None
    return REASON_NO_MODEL


def has_marker(lx, markers, agent_tok, open_tok, close_pos):
    for a, b in markers:
        if open_tok.pos <= a < close_pos:
            return True
        if a < agent_tok.pos:
            end_line = lx.line_of(max(b - 1, a))
            if end_line == agent_tok.line:
                return True
            if end_line == agent_tok.line - 1:
                start = lx.line_bounds(lx.line_of(a))[0]
                end = lx.line_bounds(end_line)[1]
                if not lx.s[start:a].strip() and not lx.s[b:end].strip():
                    return True  # the marker is alone on the line above
    return False


def init_end(toks, start):
    """Index just past the initializer that starts at toks[start]."""
    depth, j = 0, start
    while j < len(toks):
        t = toks[j]
        if t.kind == "p":
            if t.text in OPEN:
                depth += 1
            elif t.text in CLOSE:
                if depth == 0:
                    break
                depth -= 1
            elif depth == 0 and t.text in (";", ","):
                break
        if depth == 0 and j > start and t.line > toks[j - 1].line:
            prev = toks[j - 1]
            if not (t.kind == "p" and t.text in CONTINUATION) and not (prev.kind == "p" and prev.text in CONTINUATION):
                break
        j += 1
    return j


def width_const_declared(toks):
    for k, t in enumerate(toks):
        if t.kind != "id" or t.text != "const":
            continue
        j = k + 1
        while j + 1 < len(toks) and toks[j].kind == "id" and isp(toks[j + 1], "="):
            end = init_end(toks, j + 2)
            name = toks[j].text
            if WIDTH_NAME_RX.match(name) and any(w in name for w in WIDTH_WORDS) \
                    and any(x.kind == "num" for x in toks[j + 2:end]):
                return True
            if end < len(toks) and isp(toks[end], ","):
                j = end + 1
            else:
                break
    return False


def lint(src):
    """Return {'unpinned': [(line, reason)], 'fanout': (call, line) | None, 'width_ok': bool}."""
    lx = Lexer(src)
    toks = lx.toks
    markers = [(a, b) for a, b, text in lx.comments if MARKER_RX.search(text)]
    unpinned = []
    for k, open_idx, close in find_calls(toks, ("agent",)):
        args = split_top(toks, open_idx, close)
        reason = opts_problem(args[1] if len(args) > 1 else None)
        if reason is None:
            continue
        close_pos = toks[close].pos if close < len(toks) else lx.n
        if has_marker(lx, markers, toks[k], toks[open_idx], close_pos):
            continue
        unpinned.append((toks[k].line, reason))
    fanout = None
    for k, _, _ in find_calls(toks, FANOUT_CALLS):
        fanout = (toks[k].text, toks[k].line)
        break
    width_ok = fanout is None or width_const_declared(toks)
    return {"unpinned": unpinned, "fanout": fanout, "width_ok": width_ok}


FIX_PIN = ("Pin every agent() with a model in its opts: model: 'haiku' for scouts (search, extraction, classification), "
           "model: 'sonnet' for workers (coding, focused reasoning), model: 'opus' for judgment (planning, review, "
           "synthesis). For a call that must deliberately inherit the session model, add the marker "
           "/* model: session */ inside the call or alone on the line above it.")
FIX_WIDTH = ("Declare the fan-out width once, e.g. const MAX_WIDTH = 4, and cap the parallel()/pipeline() input with it "
             "(UPPER_SNAKE name containing MAX, WIDTH, CONCURRENCY, LIMIT, CAP, WORKERS or PER_, initialised with a number).")


def describe(res):
    """(short, details, fixes): the findings as a one-line summary, a list of detail lines and the fix advice."""
    short, details, fixes = [], [], []
    if res["unpinned"]:
        lines = ", ".join(str(n) for n, _ in res["unpinned"])
        short.append("%d agent() call(s) without a model pin at line(s) %s" % (len(res["unpinned"]), lines))
        details += ["line %d: agent() %s" % (n, why) for n, why in res["unpinned"]]
        fixes.append(FIX_PIN)
    if not res["width_ok"]:
        call, line = res["fanout"]
        short.append("fan-out without a width constant (%s() at line %d)" % (call, line))
        details.append("line %d: fan-out without a width constant (%s() is used but no const MAX_/WIDTH/CONCURRENCY/"
                       "LIMIT/CAP/WORKERS/PER_ NAME = <number> is declared)" % (line, call))
        fixes.append(FIX_WIDTH)
    return "; ".join(short), details, fixes


def build_output(mode, res):
    """The hook-output dict for a script with findings. Warn mode never carries a permissionDecision."""
    short, details, fixes = describe(res)
    bullets = "\n".join("  - " + d for d in details)
    if mode == "reject":
        reason = "workflow-lint (reject mode): %s.\n%s\n%s Set WORKFLOW_LINT_MODE=warn to downgrade this to a warning." % (
            short, bullets, " ".join(fixes))
        return {"systemMessage": "workflow-lint rejected the Workflow call: " + short,
                "hookSpecificOutput": {"hookEventName": "PreToolUse", "permissionDecision": "deny",
                                       "permissionDecisionReason": reason}}
    context = "workflow-lint (warn only, the Workflow call proceeds): %d finding(s) in this script.\n%s\nHow to fix: %s" % (
        len(details), bullets, " ".join(fixes))
    return {"systemMessage": "workflow-lint: " + short + " (warn only)",
            "hookSpecificOutput": {"hookEventName": "PreToolUse", "additionalContext": context}}


def write_log(mode, source, file, res, decision):
    home = os.environ.get("HOME") or os.path.expanduser("~")
    state = os.path.join(home, ".claude", "state")
    try:
        os.makedirs(state, exist_ok=True)
        entry = {"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "mode": mode, "source": source,
                 "file": file or None, "unpinned": [n for n, _ in res["unpinned"]], "width_ok": res["width_ok"],
                 "decision": decision}
        with open(os.path.join(state, "workflow-lint.jsonl"), "a") as fh:
            fh.write(json.dumps(entry) + "\n")
    except Exception:
        pass  # a log failure never blocks the hook


def parse_args(argv):
    opts = {"mode": "warn", "source": "inline", "file": ""}
    i = 0
    while i < len(argv):
        if argv[i] in ("--mode", "--source", "--file") and i + 1 < len(argv):
            opts[argv[i][2:]] = argv[i + 1]
            i += 1
        i += 1
    return opts


def main(argv):
    opts = parse_args(argv)
    mode = "reject" if opts["mode"] == "reject" else "warn"
    source = opts["source"] if opts["source"] in ("name", "path", "inline") else "inline"
    if source == "inline":
        src = sys.stdin.buffer.read().decode("utf-8", "replace")
    else:
        with open(opts["file"], "rb") as fh:
            src = fh.read().decode("utf-8", "replace")
    res = lint(src)
    clean = not res["unpinned"] and res["width_ok"]
    decision = "clean" if clean else ("deny" if mode == "reject" else "warn")
    write_log(mode, source, opts["file"] if source != "inline" else "", res, decision)
    if not clean:
        sys.stdout.write(json.dumps(build_output(mode, res)) + "\n")


if __name__ == "__main__":
    try:
        main(sys.argv[1:])
    except BaseException:
        if os.environ.get("WORKFLOW_LINT_DEBUG"):
            import traceback
            traceback.print_exc()
    sys.exit(0)
