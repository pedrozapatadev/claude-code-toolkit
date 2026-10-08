#!/bin/bash
# test.sh — fixtures for context-nudge.sh. Exit 1 on any failed expectation.
HOOK="$(cd "$(dirname "$0")" && pwd)/context-nudge.sh"
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT; export CONTEXT_NUDGE_STATE_DIR="$T/state"
TP="$T/transcript.jsonl"; : > "$TP"
PASS=0; FAILS=0
call() {  # $1 context tokens for a main-chain call   $2 isSidechain (true|false)
    jq -cn --argjson r "$1" --argjson s "$2" \
      '{type:"assistant", isSidechain:$s, message:{usage:{input_tokens:10, cache_read_input_tokens:$r, cache_creation_input_tokens:0}}}' >> "$TP"
}
run() {  # $1 expect: fire|silent   $2 label   $3 session id   $4 prompt (optional)
    out=$(jq -n --arg s "$3" --arg t "$TP" --arg p "${4:-carry on}" '{session_id:$s, transcript_path:$t, prompt:$p}' | bash "$HOOK" 2>/dev/null)
    if [ "$1" = fire ]; then
        if [ -n "$out" ] && echo "$out" | jq -e '.hookSpecificOutput.additionalContext and .systemMessage' >/dev/null; then PASS=$((PASS+1)); else echo "FAIL expected fire: $2"; FAILS=$((FAILS+1)); fi
    else
        if [ -z "$out" ]; then PASS=$((PASS+1)); else echo "FAIL expected silence: $2"; FAILS=$((FAILS+1)); fi
    fi
}
call 120000 false;                     run silent "below 400k" s1
call 420000 false;                     run fire   "crosses 400k" s1
call 450000 false;                     run silent "400k band already nudged" s1
                                       run fire   "another session, same size, own state" s2
call 900000 true;                      run silent "sidechain (subagent) usage is ignored" s1
call 710000 false;                     run fire   "crosses 700k" s1
call 720000 false;                     run silent "700k band already nudged" s1
echo '{"type":"system","subtype":"compact_boundary"}' >> "$TP"
call 430000 false;                     run fire   "compaction re-arms the bands" s1
                                       run silent "no session id" ""
call 800000 false;                     run silent "task notification is not a prompt" s3 "<task-notification>done</task-notification>"
echo "context-nudge: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
