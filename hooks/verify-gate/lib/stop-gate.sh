#!/bin/bash
# stop-gate.sh — shared plumbing for Stop-gate hooks (sourced, never executed), e.g. ../auto-verify.sh.
# One place for: the in-hook timeout that RELEASES the stop, the consecutive-identical-block
# counter, the per-repo baseline of known failures, and the log.
#
# State (all under ~/.claude/state, gitignored):
#   stop-gate.log                         one line per non-trivial event:
#                                         <ISO-UTC> hook=<hook> repo=<root> event=<event> [detail]
#                                         events: timeout · released-cap · preexisting · generated-only
#   stop-gate/<md5 of repo root>/
#     root                                the repo root (human-readable key)
#     <hook>.counter                      "<fingerprint> <n>" — consecutive identical blocks
#     <hook>.baseline                     normalized failure lines to ignore from now on
#     last-verified-sha, last-verify.txt  auto-verify only: HEAD at the last pass, last pass output
# Rule: block 1 and 2 of an identical failure block; the 3rd RELEASES the stop (exit 0), logs
# released-cap and records the failure lines in the baseline so the next turn is not trapped again.
# A different failure resets the count to 1; a pass resets it to 0.

SG_BASE="$HOME/.claude/state"
SG_LOG="$SG_BASE/stop-gate.log"
SG_CAP=3
SG_TIMEOUT_RC=124
SG_GENERATED_RE='(^|/)(\.next|\.nuxt|\.svelte-kit|\.astro|\.turbo|\.vercel|\.output|\.cache|dist|generated|__generated__)/'
SG_VERDICT=""; SG_TEXT=""; SG_WHY=""

sg_md5() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d' ' -f1; fi; }

# sg_init <hook> <repo-root> — returns non-zero when state cannot be set up (caller fails open)
sg_init() {
    SG_HOOK="$1"; SG_ROOT="$2"
    SG_DIR="$SG_BASE/stop-gate/$(printf '%s' "$2" | sg_md5)"
    mkdir -p "$SG_DIR" 2>/dev/null || return 1
    SG_TMP=$(mktemp -d "${TMPDIR:-/tmp}/stop-gate.XXXXXX" 2>/dev/null) || return 1
    trap 'rm -rf "$SG_TMP"' EXIT
    [ -f "$SG_DIR/root" ] || printf '%s\n' "$2" > "$SG_DIR/root" 2>/dev/null
    return 0
}

# sg_log <event> [detail]
sg_log() {
    printf '%s hook=%s repo=%s event=%s%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$SG_HOOK" "$SG_ROOT" "$1" "${2:+ $2}" >> "$SG_LOG" 2>/dev/null
    if [ "$(wc -l < "$SG_LOG" 2>/dev/null || echo 0)" -gt 2000 ]; then
        tail -n 1000 "$SG_LOG" > "$SG_LOG.tmp" 2>/dev/null && mv "$SG_LOG.tmp" "$SG_LOG"
    fi
    return 0
}

# sg_run <default-seconds> <command...> — portable timeout (perl alarm; macOS ships no `timeout`).
# Kills the whole process group on expiry and returns SG_TIMEOUT_RC (124). STOP_GATE_TIMEOUT overrides
# the seconds (used by ../test.sh only).
sg_run() {
    local secs="$1"; shift
    case "${STOP_GATE_TIMEOUT:-}" in ''|*[!0-9]*) ;; *) secs="$STOP_GATE_TIMEOUT" ;; esac
    perl -e '
        my $t = shift; my $pid = fork(); defined $pid or exit 127;
        if (!$pid) { setpgrp(0, 0); exec @ARGV or exit 127; }
        $SIG{ALRM} = sub { kill "TERM", -$pid; select(undef, undef, undef, 0.5); kill "KILL", -$pid; waitpid($pid, 0); exit 124; };
        alarm $t; waitpid($pid, 0); alarm 0;
        my $s = $?; exit($s & 127 ? 128 + ($s & 127) : $s >> 8);
    ' "$secs" "$@"
}

sg_strip_ansi() { LC_ALL=C sed -E $'s/\033\\[[0-9;]*[A-Za-z]//g'; }

# sg_norm — line-preserving normalization: drops line:col numbers, timestamps, durations
sg_norm() {
    LC_ALL=C sed -E \
        -e 's/^[[:space:]]+[0-9]+:[0-9]+[[:space:]]+/  /' \
        -e 's/\([0-9]+,[0-9]+\)//g' \
        -e 's/(\.[A-Za-z0-9]+):[0-9]+(:[0-9]+)?/\1/g' \
        -e 's/[0-9]{4}-[0-9]{2}-[0-9]{2}[T ][0-9:.]+Z?//g' \
        -e 's/[0-9]{1,2}:[0-9]{2}:[0-9]{2}(\.[0-9]+)?//g' \
        -e 's/([^A-Za-z0-9_.])[0-9]+(\.[0-9]+)? ?(ms|s|sec|secs|seconds)([^A-Za-z0-9_]|$)/\1<t>\4/g' \
        -e 's/[[:space:]]+$//'
}

# sg_scope <generated|changed> [changed-files-list] — filter by the file an error is located in.
# Understands tsc (`path(l,c): error`), `path:l:c: error` / `path:l:c - error`, and eslint stylish
# (a path header line, then indented findings). Unlocated lines always pass through.
sg_scope() {
    awk -v mode="$1" -v cf="${2:-}" -v root="$SG_ROOT/" -v genre="$SG_GENERATED_RE" '
    BEGIN { if (mode == "changed") while ((getline l < cf) > 0) if (l != "") ch[l] = 1; ctx = 0; hdrp = 0 }
    function rel(f) { if (index(f, root) == 1) f = substr(f, length(root) + 1); sub(/^\.\//, "", f); return f }
    function suffix(a, b) { return length(a) >= length(b) && substr(a, length(a) - length(b) + 1) == b && (length(a) == length(b) || substr(a, length(a) - length(b), 1) == "/") }
    function want(f,   k) {
        f = rel(f)
        if (mode == "generated") return !(f ~ genre)
        for (k in ch) if (suffix(f, k) || suffix(k, f)) return 1
        return 0
    }
    {
        line = $0
        if (line ~ /^[ \t]*$/) { ctx = 0; hdrp = 0; print; next }
        if (line ~ /^[^ \t]/) {
            loc = ""
            if (match(line, /\([0-9]+,[0-9]+\): (error|warning)/) && RSTART > 1) loc = substr(line, 1, RSTART - 1)
            else if (match(line, /:[0-9]+:[0-9]+(: | - )(error|warning)/) && RSTART > 1) loc = substr(line, 1, RSTART - 1)
            if (loc != "") { ctx = 1; hdrp = 0; k = want(loc); if (k) print; next }
            if (line ~ /^[^ \t]+\.(ts|tsx|js|jsx|mjs|cjs|css|scss|astro|svelte|vue|html|json|md)$/) { hdr = line; hdrp = 1; ctx = 1; k = want(line); next }
            ctx = 0; hdrp = 0; print; next
        }
        if (ctx) { if (k) { if (hdrp) { print hdr; hdrp = 0 } print } next }
        print
    }'
}

# summary lines that mean nothing once the located errors they count were filtered away
sg_drop_noise() { grep -vE '^(Found [0-9]+ errors?|✖ [0-9]+ problems?|Errors +Files|[[:space:]]+[0-9]+[[:space:]]+[^[:space:]]+:[0-9]+$)'; true; }

# sg_failure <output> <changed-files-list|""> <generated|""> <max-lines>
# Sets SG_VERDICT = pass | block | release, SG_TEXT (block text), SG_WHY (why a pass), and logs.
sg_failure() {
    local out="$1" changed="${2:-}" gen="${3:-}" max="${4:-15}" text before base fp last n=0 total
    base="$SG_DIR/$SG_HOOK.baseline"; : >> "$base" 2>/dev/null
    text=$(printf '%s\n' "$out" | sg_strip_ansi)
    [ -n "$(printf '%s' "$text" | tr -d '[:space:]')" ] || text="(the command failed with no output)"
    SG_WHY=""
    if [ "$gen" = generated ]; then
        before=$text; text=$(printf '%s\n' "$text" | sg_scope generated)
        [ "$text" != "$before" ] && { SG_WHY=generated-only; text=$(printf '%s\n' "$text" | sg_drop_noise); }
    fi
    if [ -n "$changed" ]; then
        before=$text; text=$(printf '%s\n' "$text" | sg_scope changed "$changed")
        [ "$text" != "$before" ] && { SG_WHY=preexisting; text=$(printf '%s\n' "$text" | sg_drop_noise); }
    fi
    printf '%s\n' "$text" > "$SG_TMP/raw"; sg_norm < "$SG_TMP/raw" > "$SG_TMP/norm"
    before=$text
    text=$(awk 'FILENAME == ARGV[1] { b[$0] = 1; next } FILENAME == ARGV[2] { nl[FNR] = $0; next } $0 !~ /^[[:space:]]*$/ && !(nl[FNR] in b) { print }' "$base" "$SG_TMP/norm" "$SG_TMP/raw")
    [ "$text" != "$(printf '%s\n' "$before" | grep -v '^[[:space:]]*$')" ] && SG_WHY=preexisting
    if [ -z "$(printf '%s' "$text" | tr -d '[:space:]')" ]; then
        SG_VERDICT=pass; rm -f "$SG_DIR/$SG_HOOK.counter"
        sg_log "${SG_WHY:-preexisting}"; return 0
    fi
    printf '%s\n' "$text" > "$SG_TMP/raw"; sg_norm < "$SG_TMP/raw" > "$SG_TMP/norm"
    fp=$(grep -v '^[[:space:]]*$' "$SG_TMP/norm" | sort -u | sg_md5)
    read -r last n 2>/dev/null < "$SG_DIR/$SG_HOOK.counter"
    if [ "$fp" = "${last:-}" ]; then n=$(( ${n:-0} + 1 )); else n=1; fi
    if [ "$n" -ge "$SG_CAP" ]; then
        grep -v '^[[:space:]]*$' "$SG_TMP/norm" | sort -u >> "$base"
        rm -f "$SG_DIR/$SG_HOOK.counter"
        SG_VERDICT=release; sg_log released-cap "fingerprint=$fp lines=$(grep -vc '^[[:space:]]*$' "$SG_TMP/norm")"
        return 0
    fi
    printf '%s %s\n' "$fp" "$n" > "$SG_DIR/$SG_HOOK.counter"
    total=$(printf '%s\n' "$text" | wc -l | tr -d ' ')
    SG_TEXT=$(printf '%s\n' "$text" | head -n "$max")
    [ "$total" -gt "$max" ] && SG_TEXT=$(printf '%s\n... (%d more lines)' "$SG_TEXT" $((total - max)))
    SG_VERDICT=block
}

sg_pass() { rm -f "$SG_DIR/$SG_HOOK.counter"; }

# sg_emit_block <reason> — the Stop-hook block decision
sg_emit_block() { jq -n --arg r "$1" '{decision: "block", reason: $r}'; }
