#!/bin/bash
# PreToolUse(Workflow) hook: lints the script a Workflow call is about to run.
#   Rule A  every agent() call pins `model:` in an object-literal opts (or carries the marker /* model: session */)
#   Rule B  a script that calls parallel()/pipeline() declares an UPPER_SNAKE width constant
#           (const MAX_/WIDTH/CONCURRENCY/LIMIT/CAP/WORKERS/PER_ NAME = <number>)
# Input: hook JSON on stdin: .tool_input.script (inline) | .scriptPath (file) | .name (saved workflow), and .cwd.
# A name resolves to the first existing of <cwd>/.claude/workflows/<name>.js, <git toplevel of cwd>/.claude/workflows/<name>.js,
# $HOME/.claude/workflows/<name>.js; a built-in name (no file) passes silently, as does a missing/unreadable scriptPath.
# WORKFLOW_LINT_MODE: warn (default; unknown values too) = exit 0 + systemMessage/additionalContext, never a permissionDecision;
# reject = permissionDecision "deny" when there are findings; off = do nothing.
# Each linted call appends a line to $HOME/.claude/state/workflow-lint.jsonl.
# Fails OPEN: any internal error exits 0 with no output. Needs jq and python3. Parser: ./lib/workflow_lint.py, tests: ./test.sh.
# Paths are resolved relative to this file, so it works under ${CLAUDE_PLUGIN_ROOT}.

INPUT=$(cat)

MODE=$(printf '%s' "${WORKFLOW_LINT_MODE:-warn}" | tr '[:upper:]' '[:lower:]')
case "$MODE" in off) exit 0 ;; reject) ;; *) MODE=warn ;; esac
command -v jq >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1 || exit 0
LIB="$(cd "$(dirname "$0")" 2>/dev/null && pwd)/lib/workflow_lint.py"
[ -f "$LIB" ] || exit 0

IFS=$'\x1f' read -r KIND NAME SPATH CWD < <(printf '%s' "$INPUT" | jq -r '
    .tool_input as $t
    | [ (if ($t.script | type) == "string" and ($t.script | length) > 0 then "inline"
         elif ($t.scriptPath | type) == "string" and ($t.scriptPath | length) > 0 then "path"
         elif ($t.name | type) == "string" and ($t.name | length) > 0 then "name"
         else "" end),
        ($t.name // "" | tostring), ($t.scriptPath // "" | tostring), (.cwd // "" | tostring) ]
    | join("\u001f")' 2>/dev/null)
[ -n "${KIND:-}" ] || exit 0

FILE=""

case "$KIND" in
    inline) ;;
    path)
        FILE="$SPATH"
        case "$FILE" in "~/"*) FILE="$HOME/${FILE#\~/}" ;; /*) ;; *) FILE="${CWD:-.}/$FILE" ;; esac
        ;;
    name)
        [[ "$NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || exit 0
        if [ -n "$CWD" ] && [ -f "$CWD/.claude/workflows/$NAME.js" ]; then FILE="$CWD/.claude/workflows/$NAME.js"
        else
            TOP=""; [ -n "$CWD" ] && TOP=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
            if [ -n "$TOP" ] && [ -f "$TOP/.claude/workflows/$NAME.js" ]; then FILE="$TOP/.claude/workflows/$NAME.js"
            elif [ -f "$HOME/.claude/workflows/$NAME.js" ]; then FILE="$HOME/.claude/workflows/$NAME.js"
            else exit 0; fi                     # a built-in workflow: nothing to lint
        fi
        ;;
esac

if [ "$KIND" != inline ]; then
    [ -f "$FILE" ] && [ -r "$FILE" ] || exit 0
    python3 "$LIB" --mode "$MODE" --source "$KIND" --file "$FILE" 2>/dev/null </dev/null
else
    printf '%s' "$INPUT" | jq -j '.tool_input.script' 2>/dev/null | python3 "$LIB" --mode "$MODE" --source inline 2>/dev/null
fi
exit 0
