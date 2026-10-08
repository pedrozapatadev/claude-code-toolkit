#!/bin/bash
# PreToolUse(Edit|Write) hook: guard files an agent should not edit.
# Receives JSON on stdin with tool_input.file_path.
# Exit 2 = block the tool call. A JSON permissionDecision "ask" = the user approves or denies.
# Exit 0 with no output = allow.
# Scope: Edit and Write only. A Bash redirect (echo > .env) does not pass through here.

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

BASE=${FILE_PATH##*/}

# Templates are meant to be edited
case "$BASE" in
    .env.example|.env.sample|.env.template|*.env.example) exit 0 ;;
esac

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

# Block credential/secret files, by file name (src/lib/secrets.ts is code, not a secret store)
case "$BASE" in
    credentials|credentials.*|*.credentials|.secrets|secrets.json|secrets.yml|secrets.yaml|secrets.toml|secrets.env|*.pem|id_rsa|id_ed25519)
        echo "BLOCKED: Cannot edit credential/secret files: $FILE_PATH" >&2
        exit 2 ;;
esac

# The project's definition of done and its hook settings: editing them can switch off the gates
# that check the agent, so a human approves each edit.
case "$FILE_PATH" in
    */.claude/verify.sh|*/.claude/settings.json|*/.claude/settings.local.json)
        jq -n --arg r "Editing $FILE_PATH changes how this agent is checked (verify gate / hooks). Approve only if you asked for it." \
            '{hookSpecificOutput: {hookEventName: "PreToolUse", permissionDecision: "ask", permissionDecisionReason: $r}}' 2>/dev/null \
            || printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"ask","permissionDecisionReason":"Editing the project verify script or hook settings needs your approval."}}\n'
        exit 0 ;;
esac

# Allow everything else
exit 0
