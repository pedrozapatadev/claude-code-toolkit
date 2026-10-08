#!/bin/bash
# PreToolUse hook: Block edits to protected files globally
# Receives JSON on stdin with tool_input.file_path
# Exit 2 = block the tool call, Exit 0 = allow

INPUT=$(cat)

# Parse with jq (as the sibling hooks do). python3 is a fallback only: if jq is
# missing, fails, or yields an empty path for non-empty input, an empty parse
# must not silently disable the guard.
FILE_PATH=$(printf '%s' "$INPUT" | jq -r '.tool_input.file_path // empty' 2>/dev/null)
if [ -z "$FILE_PATH" ] && [ -n "$INPUT" ]; then
    FILE_PATH=$(printf '%s' "$INPUT" | python3 -c "
import sys, json
try:
    print(json.load(sys.stdin).get('tool_input', {}).get('file_path', ''))
except Exception:
    print('')
" 2>/dev/null)
fi

# Exit silently if no file path
[ -z "$FILE_PATH" ] && exit 0

# Block .env files (all variants)
case "$FILE_PATH" in
    *.env|*.env.*|*/.env|*/.env.*)
        echo "BLOCKED: Cannot edit environment file: $FILE_PATH" >&2
        exit 2 ;;
esac

# Block lock files
case "$FILE_PATH" in
    */package-lock.json|*/yarn.lock|*/pnpm-lock.yaml)
        echo "BLOCKED: Cannot edit lock file: $FILE_PATH" >&2
        exit 2 ;;
esac

# Block node_modules
case "$FILE_PATH" in
    */node_modules/*)
        echo "BLOCKED: Cannot edit node_modules: $FILE_PATH" >&2
        exit 2 ;;
esac

# Block .git internals
case "$FILE_PATH" in
    */.git/*)
        echo "BLOCKED: Cannot edit .git internals: $FILE_PATH" >&2
        exit 2 ;;
esac

# Block SSH keys and config
case "$FILE_PATH" in
    */.ssh/*|$HOME/.ssh/*)
        echo "BLOCKED: Cannot edit SSH files: $FILE_PATH" >&2
        exit 2 ;;
esac

# Block AWS credentials
case "$FILE_PATH" in
    */.aws/*|$HOME/.aws/*)
        echo "BLOCKED: Cannot edit AWS config: $FILE_PATH" >&2
        exit 2 ;;
esac

# Block credential/secret files
case "$FILE_PATH" in
    *credentials*|*secrets*)
        echo "BLOCKED: Cannot edit credential/secret files: $FILE_PATH" >&2
        exit 2 ;;
esac

# Allow everything else
exit 0
