#!/bin/bash
# Stop hook: per-project auto-verification — the agent cannot end its turn on a broken build.
# Runs $PROJECT_ROOT/.claude/verify.sh when source files changed; on failure emits
# {"decision":"block","reason":...} so the agent fixes breakage before stopping.
# Opt-in: projects without .claude/verify.sh are untouched.
# Never traps a session; all plumbing lives in lib/stop-gate.sh:
#   - a verify run over 100 s (settings timeout is 120) RELEASES the stop and is logged;
#   - the 3rd consecutive identical failure RELEASES the stop and baselines those lines;
#   - within one turn, the AUTO_VERIFY_CHAIN_CAP-th consecutive block (default 5) RELEASES, even if every
#     failure differs (Claude Code's own continuation cap resets on each tool call, so it cannot bound this);
#   - "changed" means changed since the last verified HEAD (so a turn that commits is still
#     verified), and errors located in files unchanged since then are out of scope (preexisting);
#   - the debounce marker and last-verified sha live under ~/.claude/state (see lib/stop-gate.sh), not in the repo.

INPUT=$(cat)

# stop_hook_active = this stop follows a block. It does NOT skip the check (the fix must be re-verified);
# it only continues the per-turn block chain counted below.
STOP_ACTIVE=$(echo "$INPUT" | jq -r '.stop_hook_active // false' 2>/dev/null)

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

CHAIN="$SG_DIR/auto-verify.chain"
[ "$STOP_ACTIVE" = "true" ] || rm -f "$CHAIN"

# Changed = staged + unstaged vs HEAD (deletions included), every untracked file (not just its folder),
# plus everything differing from the last verified HEAD
LAST=$(cat "$SG_DIR/last-verified-sha" 2>/dev/null)
{
    git -C "$ROOT" -c core.quotepath=off diff --name-only HEAD 2>/dev/null \
        || git -C "$ROOT" -c core.quotepath=off diff --name-only --cached 2>/dev/null
    git -C "$ROOT" -c core.quotepath=off ls-files --others --exclude-standard 2>/dev/null
    if [ -n "$LAST" ] && git -C "$ROOT" cat-file -e "$LAST^{commit}" 2>/dev/null; then
        git -C "$ROOT" diff --name-only "$LAST" 2>/dev/null
    fi
} | sort -u > "$SG_TMP/changed-all"
CHANGED=$(grep -E '\.(ts|tsx|js|jsx|mjs|css|scss|astro|svelte|vue|html)$' "$SG_TMP/changed-all")
[ -z "$CHANGED" ] && exit 0

# Debounce: skip only when the changed set is the one last verified AND no file in it is newer than that run
# (a deleted or newly listed file changes the set, so a delete-only turn is still verified)
MARKER="$SG_DIR/last-verify.txt"
SETFP=$(printf '%s\n' "$CHANGED" | sg_md5)
if [ -f "$MARKER" ] && [ "$(cat "$SG_DIR/last-verify.set" 2>/dev/null)" = "$SETFP" ]; then
    NEWER=$(printf '%s\n' "$CHANGED" | while IFS= read -r f; do
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

mark_verified() {  # a pass (or a release): remember the output and the changed set as the debounce marker
    printf '%s\n' "$OUTPUT" > "$MARKER" 2>/dev/null
    printf '%s\n' "$SETFP" > "$SG_DIR/last-verify.set" 2>/dev/null
    rm -f "$CHAIN"
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
        N=$(( $(cat "$CHAIN" 2>/dev/null || echo 0) + 1 ))
        CAP=${AUTO_VERIFY_CHAIN_CAP:-5}; case "$CAP" in ''|*[!0-9]*) CAP=5 ;; esac
        if [ "$N" -ge "$CAP" ]; then
            sg_log released-chain "blocks=$N"
            mark_verified
            exit 0
        fi
        printf '%s\n' "$N" > "$CHAIN"
        if [ -n "$LAST" ]; then SCOPE="errors in files unchanged since the last passing run are ignored"
        else SCOPE="no passing run is on record for this repo yet, so every error counts"; fi
        REASON=$(printf 'auto-verify failed (%s/.claude/verify.sh, exit %d; block %d of at most %d this turn). Fix before stopping (%s):\n%s' "$ROOT" "$STATUS" "$N" "$((CAP - 1))" "$SCOPE" "$SG_TEXT")
        sg_emit_block "$REASON" ;;
esac
exit 0
