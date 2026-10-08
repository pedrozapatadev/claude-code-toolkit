#!/bin/bash
# UserPromptSubmit hook: a soft nudge when the session's context grows large. Never compacts,
# never blocks — it speaks only when the user sends a prompt (a natural boundary), once per band
# (400k, 700k by default; CONTEXT_NUDGE_BANDS overrides) per compaction generation, so a long
# build is never interrupted mid-step. Why: on 1M-context models auto-compaction only starts near
# ~967k, so a session can run for hours at 400k+ while every call re-reads all of it.
# Fixtures: ./test.sh.
INPUT=$(cat)
SID=$(printf '%s' "$INPUT" | jq -r '.session_id // ""' 2>/dev/null | tr -cd 'A-Za-z0-9-')
TP=$(printf '%s' "$INPUT" | jq -r '.transcript_path // ""' 2>/dev/null)
PROMPT=$(printf '%s' "$INPUT" | jq -r '.prompt // ""' 2>/dev/null)
[ -n "$SID" ] && [ -f "$TP" ] || exit 0
printf '%s' "$PROMPT" | grep -qE '^\[SYSTEM NOTIFICATION|<task-notification>' && exit 0

# Context of the latest main-chain call = input + cache read + cache write, from the transcript tail.
CTX=$(tail -c 4000000 "$TP" 2>/dev/null | python3 -c '
import json, sys
last = 0
for line in sys.stdin:
    if "\"usage\"" not in line:
        continue
    try:
        o = json.loads(line)
    except ValueError:
        continue
    if o.get("isSidechain") or o.get("type") != "assistant":
        continue
    u = (o.get("message") or {}).get("usage") or {}
    t = sum(u.get(k) or 0 for k in ("input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"))
    if t:
        last = t
print(last)' 2>/dev/null)
CTX=${CTX:-0}

BAND=0
for B in ${CONTEXT_NUDGE_BANDS:-400000 700000}; do [ "$CTX" -ge "$B" ] && BAND=$B; done
[ "$BAND" -gt 0 ] || exit 0

# Once per band per compaction generation; a compaction re-arms both bands.
GEN=$(grep -c '"subtype":"compact_boundary"' "$TP" 2>/dev/null); GEN=${GEN:-0}
SD="${CONTEXT_NUDGE_STATE_DIR:-$HOME/.claude/hooks/state/context-nudge}"
mkdir -p "$SD" 2>/dev/null || exit 0
{ read -r S_GEN S_BAND < "$SD/$SID"; } 2>/dev/null
[ "$S_GEN" = "$GEN" ] && [ "${S_BAND:-0}" -ge "$BAND" ] && exit 0
printf '%s %s\n' "$GEN" "$BAND" > "$SD/$SID"
find "$SD" -type f -mtime +14 -delete 2>/dev/null

K=$((CTX / 1000))
MSG="[context-nudge] This session's context is ~${K}k tokens (auto-compaction only near ~967k). Every call re-reads all of it, and very long contexts weaken instruction-following. If this prompt starts a NEW task or phase: first write the handoff (docs/build-state.md or tasks/todo.md — state, decisions, exact next step), then suggest the user continue in a fresh session. If it continues the current unit of work, finish it — never break off mid-build. Mention this at most once, in one line."
jq -n --arg ctx "$MSG" --arg sys "Context ~${K}k tokens — a fresh session at the next natural checkpoint will be cheaper and sharper." \
  '{systemMessage: $sys, hookSpecificOutput: {hookEventName: "UserPromptSubmit", additionalContext: $ctx}}'
exit 0
