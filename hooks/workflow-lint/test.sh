#!/usr/bin/env bash
# test.sh: tests for the PreToolUse(Workflow) lint hook (./workflow-lint.sh + ./lib/workflow_lint.py).
# Hook-level cases cover the I/O contract (warn JSON, reject deny, name/path resolution, modes, fail-open, the jsonl log);
# one in-process python batch covers the tokenizer/parser edge cases. Runs in a sandboxed HOME under mktemp:
# no network, no real state dir, a few seconds. Needs bash, jq, python3 and git.
set -u
SRC=$(cd "$(dirname "$0")" && pwd); HOOK="$SRC/workflow-lint.sh"; LIBDIR="$SRC/lib"
for tool in jq python3 git; do
  command -v "$tool" >/dev/null 2>&1 || { echo "workflow-lint: missing required tool: $tool"; exit 1; }
done
T=$(mktemp -d "${TMPDIR:-/tmp}/wflint-test.XXXXXX"); trap 'rm -rf "$T"' EXIT
H="$T/home"; mkdir -p "$H/.claude/workflows" "$T/s" "$T/work" "$T/proj/.claude/workflows" "$T/proj/sub/deep" "$T/scripts"
git -C "$T/proj" init -q 2>/dev/null
P=0; FL=0
check() { if eval "$2"; then echo "ok    $1"; P=$((P+1)); else echo "FAIL  $1"; FL=$((FL+1)); fi; }
mkjs() { cat > "$T/s/$1.js"; }
M=warn
# run the hook with $1 as stdin; sets OUT (stdout) and RC
hook() { OUT=$(printf '%s' "$1" | HOME="$H" WORKFLOW_LINT_MODE="$M" bash "$HOOK" 2>/dev/null); RC=$?; }
inline() { hook "$(jq -cn --rawfile s "$T/s/$1.js" --arg cwd "$T/work" '{tool_input: {script: $s}, cwd: $cwd}')"; }
by_path() { hook "{\"tool_input\":{\"scriptPath\":\"$1\"},\"cwd\":\"${2:-$T/work}\"}"; }
by_name() { hook "{\"tool_input\":{\"name\":\"$1\",\"args\":\"x\"},\"cwd\":\"${2:-$T/work}\"}"; }
silent() { [ "$RC" = 0 ] && [ -z "$OUT" ]; }
# warn JSON naming line $1: valid, one-line systemMessage, PreToolUse context with the line + fix advice, no permissionDecision
warned() { [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e --arg l "$1" '
    (.systemMessage | type == "string" and (contains("\n") | not) and startswith("workflow-lint"))
    and .hookSpecificOutput.hookEventName == "PreToolUse"
    and (.hookSpecificOutput.additionalContext | contains("line " + $l + ":") and contains("model: '"'"'haiku'"'"'")
         and contains("/* model: session */"))
    and ((.hookSpecificOutput | has("permissionDecision")) | not) and (has("permissionDecision") | not)' >/dev/null 2>&1; }
denied() { [ "$RC" = 0 ] && printf '%s' "$OUT" | jq -e --arg l "$1" '
    .hookSpecificOutput.permissionDecision == "deny" and .hookSpecificOutput.hookEventName == "PreToolUse"
    and (.hookSpecificOutput.permissionDecisionReason | contains("line " + $l))' >/dev/null 2>&1; }

mkjs unpinned <<'EOF'
const MAX_WIDTH = 3
const a = await agent("one", { label: "a", model: "haiku" })
const b = await agent("two", { label: "b" })
EOF
[ ! -e "$H/.claude/state" ] && FRESH=1 || FRESH=0
M=warn; inline unpinned
check "unpinned inline script, warn: JSON naming line 3, no permissionDecision" 'warned 3'
check "first lint creates \$HOME/.claude/state/workflow-lint.jsonl" '[ "$FRESH" = 1 ] && [ -s "$H/.claude/state/workflow-lint.jsonl" ]'
M=reject; inline unpinned
check "same script, reject: permissionDecision deny naming line 3" 'denied 3'
M=warn

mkjs marker <<'EOF'
const a = await agent("one", { label: "a" /* model: session */ })
/* model: session */
const b = await agent("two")
const c = /* model: session */ await agent("three", { label: "c" })
EOF
inline marker
check "calls carrying the session marker (inside args, line above, same line before) are clean" 'silent'
mkjs pinned <<'EOF'
const model = "sonnet"
const a = await agent("one", { label: "a", model: "haiku", effort: "low" })
const b = await agent("two", { model })
const c = await agent(`three ${1 + 1}`, { "model": "opus", schema: { type: "object" } })
const d = await agent("four", { ...base, model: "sonnet" })
EOF
inline pinned
check "every agent() pinned (key, shorthand, quoted key, spread plus model) is clean" 'silent'
mkjs fanout <<'EOF'
const a = await parallel([() => agent("x", { model: "haiku" })])
EOF
inline fanout
check "parallel() without a width constant is flagged" '[ "$RC" = 0 ] && [[ "$OUT" == *"fan-out without a width constant"* ]] && [[ "$OUT" == *"line 1:"* ]] && [[ "$OUT" != *permissionDecision* ]]'
mkjs fanout-ok <<'EOF'
const MAX_ITEMS = 4
const a = await pipeline([1, 2], (x) => agent("x" + x, { model: "haiku" }))
EOF
inline fanout-ok
check "pipeline() with const MAX_ITEMS = 4 is clean" 'silent'
mkjs notcounted <<'EOF'
// agent("in a line comment")
/* agent("in a block comment") */
const s1 = 'agent("single")'
const s2 = "agent('double')"
const t = `agent("template text") and agent(x, {})`
EOF
inline notcounted
check "agent( inside a comment, a string and a template literal's text is not counted" 'silent'
mkjs subst <<'EOF'
const t = `header
line two ${await agent("inside substitution")}
done`
EOF
inline subst
check "agent() inside a template's \${...} is counted (line 2)" 'warned 2'
mkjs optsid <<'EOF'
const opts = { label: "a", model: "haiku" }
const a = await agent("one", opts)
EOF
inline optsid
check "opts passed as an identifier is flagged (line 2)" 'warned 2'

# name resolution
mkjs bad-agent <<'EOF'
const a = await agent("unpinned", {})
EOF
mkjs good-agent <<'EOF'
const a = await agent("pinned", { model: "haiku" })
EOF
cp "$T/s/bad-agent.js" "$T/proj/.claude/workflows/proj-wf.js"; cp "$T/s/bad-agent.js" "$H/.claude/workflows/user-wf.js"
cp "$T/s/good-agent.js" "$T/proj/.claude/workflows/shared-wf.js"; cp "$T/s/bad-agent.js" "$H/.claude/workflows/shared-wf.js"
by_name proj-wf "$T/proj"
check "name resolves to <cwd>/.claude/workflows/<name>.js" 'warned 1'
by_name proj-wf "$T/proj/sub/deep"
check "name resolves to <git toplevel>/.claude/workflows/<name>.js from a subdirectory" 'warned 1'
by_name user-wf "$T/work"
check "name resolves to \$HOME/.claude/workflows/<name>.js" 'warned 1'
by_name shared-wf "$T/proj"
check "project workflow wins over the user one of the same name" 'silent'
by_name some-builtin-workflow "$T/proj"
check "built-in name with no file anywhere is silent" 'silent'
by_name "../etc/passwd" "$T/proj"
check "a name with path separators is ignored silently" 'silent'

# scriptPath
by_path "$T/s/unpinned.js"
check "scriptPath to an unpinned file is flagged" 'warned 3'
by_path "$T/s/does-not-exist.js"
check "missing scriptPath is silent" 'silent'
by_path "s/unpinned.js" "$T"
check "relative scriptPath resolves against cwd" 'warned 3'
for M in warn reject; do
  FLAGGED=warned; [ "$M" = reject ] && FLAGGED=denied
  by_path "$T/s/unpinned.js"
  check "scriptPath to an unpinned file is flagged the mode's way ($M)" "$FLAGGED 3"
done
M=warn

# fail open and modes
hook 'this is not json {'
check "malformed stdin JSON: exit 0, silent" 'silent'
hook ''
check "empty stdin: exit 0, silent" 'silent'
hook '{"tool_input":"a string","cwd":"/tmp"}'
check "tool_input of the wrong type: exit 0, silent" 'silent'
M=off; inline unpinned
check "mode off is silent" 'silent'
M=bogus; inline unpinned
check "unknown mode behaves as warn (no permissionDecision)" 'warned 3'
M=warn

# jsonl log (the sandbox log so far holds earlier calls; start a fresh one for exact assertions)
LOG="$H/.claude/state/workflow-lint.jsonl"; : > "$LOG"
M=warn; inline unpinned; M=reject; inline unpinned; M=warn; inline pinned; by_name user-wf "$T/work"; by_path "$T/s/fanout.js"
check "log: one line per linted call (5), all valid JSON" '[ "$(wc -l < "$LOG" | tr -d " ")" = 5 ] && jq -e . "$LOG" >/dev/null'
check "log: warn inline line has ts/mode/source/file/unpinned/width_ok/decision" \
  '[ "$(sed -n 1p "$LOG" | jq -c "[(.ts|test(\"^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9:]{8}Z$\")), .mode, .source, .file, .unpinned, .width_ok, .decision]")" = "[true,\"warn\",\"inline\",null,[3],true,\"warn\"]" ]'
check "log: reject line is decision deny, mode reject" '[ "$(sed -n 2p "$LOG" | jq -c "[.mode, .decision, .unpinned]")" = "[\"reject\",\"deny\",[3]]" ]'
check "log: clean script is decision clean with no unpinned lines" '[ "$(sed -n 3p "$LOG" | jq -c "[.decision, .unpinned, .width_ok]")" = "[\"clean\",[],true]" ]'
check "log: name source records the resolved file" '[ "$(sed -n 4p "$LOG" | jq -c "[.source, .file, .unpinned]")" = "[\"name\",\"$H/.claude/workflows/user-wf.js\",[1]]" ]'
check "log: path source with fan-out and no width records width_ok false" '[ "$(sed -n 5p "$LOG" | jq -c "[.source, .width_ok, .decision]")" = "[\"path\",false,\"warn\"]" ]'
M=off; inline unpinned; M=warn
check "log: off mode writes nothing" '[ "$(wc -l < "$LOG" | tr -d " ")" = 5 ]'

# speed: ~450-line script, whole hook well under 1 s
{ echo 'const MAX_WIDTH = 4'
  i=0; while [ $i -lt 110 ]; do
    echo "// agent(\"comment $i\")"; echo "const t$i = \`text \${await agent(\"p$i\", { label: \"l$i\","; echo "  model: \"haiku\" })} agent(x)\`"; echo "const r$i = /['\"]/g; const d$i = a / b / c"; i=$((i+1)); done; } > "$T/s/big.js"
T0=$(python3 -c 'import time; print(int(time.time()*1000))'); inline big; T1=$(python3 -c 'import time; print(int(time.time()*1000))')
check "450-line script: clean, hook under 1 s ($((T1-T0)) ms)" 'silent && [ $((T1-T0)) -lt 1000 ] && [ "$(wc -l < "$T/s/big.js" | tr -d " ")" -ge 440 ]'

# tokenizer/parser edge cases: one python process, calling lint() directly
cat > "$T/batch.py" <<'PY'
import sys
sys.path.insert(0, sys.argv[1])
import workflow_lint as w

CASES = [
 # (name, source, expected unpinned lines, expected width_ok)
 ("escaped quote inside a string hides agent(", r"""const s = 'it\'s agent(x)'
agent(p)""", [2], True),
 ("not agent calls: x.agent(, subagent(, $agent(, agent_x(, function agent(", r"""x.agent(p)
subagent(p)
$agent(p)
agent_x(p)
function agent(p, o) { return 1 }
const m = { agent(p, o) { return 1 } }""", [], True),
 ("a spread call ...agent(x) still counts", "f(...agent(x))\n", [1], True),
 ("nested template substitution is scanned", "const t = `a ${ `b ${ agent(x) }` } c`\nagent(y)\n", [1, 2], True),
 ("regex literal with a quote does not swallow the next line", "const r = /'/g\nagent(p)\nconst q = /[\"`]/\nagent(q)\n", [2, 4], True),
 ("division is not a regex", "const d = a / b / c\nconst e = (a + b) / 2\nagent(p)\n", [3], True),
 ("line numbers survive a multi-line template, a block comment and a multi-line call", "const t = `a\nb\nc`\n/* x\ny */\nagent(\n  p,\n  {}\n)\n", [6], True),
 ("CRLF line endings", "const a = 1\r\nagent(p)\r\nagent(q, {model: 'x'})\r\n", [2], True),
 ("opts variants", "agent(p, opts)\nagent(p, {...o})\nagent(p, {label: 'a'})\nagent(p, {schema: {model: 1}})\nagent(p, cond ? {model: 'a'} : {})\nagent(p, {'model': 1})\nagent(p, {['model']: 1})\nagent(p, {model})\nagent(p, {model: 'a'},)\n", [1, 2, 3, 4, 5], True),
 ("marker two lines above does not count; marker alone on the line above does", "/* model: session */\n\nagent(p)\n/* model: session */\nagent(q)\n", [3], True),
 ("marker in a trailing comment of the previous statement does not exempt the next call", "const a = 1 /* model: session */\nagent(q)\n", [2], True),
 ("marker must be a whole word: model: sessions does not exempt", "/* model: sessions */\nagent(p)\n", [2], True),
 ("marker spacing: model:session in a block comment exempts", "/*model:session*/\nagent(p)\n", [], True),
 ("width: initializer without a numeric literal fails", "const MAX_ITEMS = Number(x)\nparallel(a)\n", [], False),
 ("width: non-UPPER name fails", "const maxItems = 4\nparallel(a)\n", [], False),
 ("width: UPPER name without a keyword fails", "const FOO = 4\nparallel(a)\n", [], False),
 ("width: each keyword is accepted", "const A_WIDTH = 1\nconst B_CONCURRENCY = 1\nconst C_LIMIT = 1\nconst D_CAP = 1\nconst E_WORKERS = 1\nconst VOTES_PER_CLAIM = 3\npipeline(a)\n", [], True),
 ("width: later declarator and continuation lines", "const A = 1, MAX_X = 4\nparallel(a)\n", [], True),
 ("width: initializer continued on the next line", "const MAX_X =\n  5\nparallel(a)\n", [], True),
 ("width: a number on the NEXT statement does not count", "const MAX_X = foo\nconst Y = 5\nparallel(a)\n", [], False),
 ("width: parallel only in comments or strings needs no constant", "// parallel(a)\nconst s = 'pipeline(a)'\nx.parallel(a)\n", [], True),
 ("width: constant name must be a const declaration", "let MAX_X = 4\nparallel(a)\n", [], False),
 ("garbage does not raise", "agent(\n`unterminated ${ agent(\n'abc\n/* never closed", None, None),
]
for name, src, lines, width_ok in CASES:
    try:
        res = w.lint(src)
    except Exception as e:
        print("FAIL  py: %s (raised %r)" % (name, e)); continue
    if lines is None:
        print("ok    py: %s" % name); continue
    got = [n for n, _ in res["unpinned"]]
    if got == lines and res["width_ok"] == width_ok:
        print("ok    py: %s" % name)
    else:
        print("FAIL  py: %s (lines %r want %r, width_ok %r want %r)" % (name, got, lines, res["width_ok"], width_ok))
PY
PYOUT=$(PYTHONDONTWRITEBYTECODE=1 python3 "$T/batch.py" "$LIBDIR" 2>&1)
while IFS= read -r line; do
  case "$line" in ok*) P=$((P+1)); echo "$line" ;; *) FL=$((FL+1)); echo "FAIL  python batch: ${line#FAIL  }" ;; esac
done <<< "$PYOUT"
check "python batch reported all 23 cases" '[ "$(printf "%s\n" "$PYOUT" | grep -c "^\(ok\|FAIL\) ")" = 23 ]'

echo "workflow-lint: $P passed, $FL failed"
[ "$FL" = 0 ]
