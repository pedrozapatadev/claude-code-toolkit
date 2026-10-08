#!/bin/bash
# Stop hook: per-project auto-verification — the agent cannot end its turn on a broken build.
# Runs $PROJECT_ROOT/.claude/verify.sh when source files changed; on failure emits
# {"decision":"block","reason":...} so the agent fixes breakage before stopping.
# Opt-in: projects without .claude/verify.sh are untouched.
# Never traps a session; all plumbing lives in lib/stop-gate.sh:
#   - a verify run over 100 s (settings timeout is 120) RELEASES the stop and is logged;
#   - the 3rd consecutive identical failure RELEASES the stop and baselines those lines;
#   - "changed" means changed since the last verified HEAD (so a turn that commits is still
#     verified), and errors located in files unchanged since then are out of scope (preexisting);
#   - the debounce marker and last-verified sha live under ~/.claude/state (see lib/stop-gate.sh), not in the repo.

INPUT=$(cat)

# Never loop: if we're already continuing from a stop hook, allow the stop.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)
[ "$STOP_ACTIVE" = "true" ] && exit 0

CWD=$(echo "$INPUT" | jq -r '.cwd // ""' 2>/dev/null)
[ -z "$CWD" ] || [ ! -d "$CWD" ] && exit 0

ROOT=$(git -C "$CWD" rev-parse --show-toplevel 2>/dev/null)
[ -z "$ROOT" ] && exit 0

VERIFY="$ROOT/.claude/verify.sh"
[ ! -f "$VERIFY" ] && exit 0

LIB="$(cd "$(dirname "$0")" && pwd)/lib/stop-gate.sh"
[ -f "$LIB" ] || exit 0
. "$LIB"
sg_init auto-verify "$ROOT" || exit 0

# Changed = working tree status plus everything differing from the last verified HEAD
LAST=$(cat "$SG_DIR/last-verified-sha" 2>/dev/null)
{
    git -C "$ROOT" status --porcelain 2>/dev/null | awk '{print $NF}'
    if [ -n "$LAST" ] && git -C "$ROOT" cat-file -e "$LAST^{commit}" 2>/dev/null; then
        git -C "$ROOT" diff --name-only "$LAST" 2>/dev/null
    fi
} | sort -u > "$SG_TMP/changed-all"
CHANGED=$(grep -E '\.(ts|tsx|js|jsx|mjs|css|scss|astro|svelte|vue|html)$' "$SG_TMP/changed-all")
[ -z "$CHANGED" ] && exit 0

# Debounce: skip if the last pass is newer than every changed source file
MARKER="$SG_DIR/last-verify.txt"
if [ -f "$MARKER" ]; then
    NEWER=$(echo "$CHANGED" | while IFS= read -r f; do
        [ -f "$ROOT/$f" ] && [ "$ROOT/$f" -nt "$MARKER" ] && echo newer && break
    done)
    [ -z "$NEWER" ] && exit 0
fi

# Run the project's verify command; expiry (100 s < the 120 s settings timeout) releases the stop
OUTPUT=$(cd "$ROOT" && set -o pipefail && sg_run 100 bash "$VERIFY" 2>&1)
STATUS=$?

if [ $STATUS -eq "$SG_TIMEOUT_RC" ]; then
    sg_log timeout "exit=$STATUS"
    exit 0
fi

mark_verified() {  # a pass (or a release): remember the output as the debounce marker
    printf '%s\n' "$OUTPUT" > "$MARKER" 2>/dev/null
}

if [ $STATUS -eq 0 ]; then
    sg_pass
    mark_verified
    git -C "$ROOT" rev-parse HEAD > "$SG_DIR/last-verified-sha" 2>/dev/null
    exit 0
fi

sg_failure "$OUTPUT" "${LAST:+$SG_TMP/changed-all}" "" 15
case "$SG_VERDICT" in
    pass)
        mark_verified
        git -C "$ROOT" rev-parse HEAD > "$SG_DIR/last-verified-sha" 2>/dev/null ;;
    release)
        mark_verified ;;
    block)
        REASON=$(printf 'auto-verify failed (%s/.claude/verify.sh, exit %d). Fix before stopping (errors in files you did not change are ignored):\n%s' "$ROOT" "$STATUS" "$SG_TEXT")
        sg_emit_block "$REASON" ;;
esac
exit 0
