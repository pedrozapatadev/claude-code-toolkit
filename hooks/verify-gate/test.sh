#!/bin/bash
# test.sh — fixtures for auto-verify.sh (built on lib/stop-gate.sh). Exit 1 on any failed expectation.
# Sandbox only: HOME is a mktemp dir (state + log land there), repos are temp git repos with a fake
# .claude/verify.sh. No real repo, no network. STOP_GATE_TIMEOUT=1 makes the timeout case take ~1 s.
set -u
AV="$(cd "$(dirname "$0")" && pwd)/auto-verify.sh"
T=$(mktemp -d /tmp/stop-gate-test.XXXXXX); trap 'rm -rf "$T"' EXIT
export HOME="$T/home"; mkdir -p "$HOME"
LOG="$HOME/.claude/state/stop-gate.log"
PASS=0; FAILS=0; BUMP=0
ok()   { PASS=$((PASS+1)); }
bad()  { echo "FAIL $1"; FAILS=$((FAILS+1)); }
git_() { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}" >/dev/null 2>&1; }

# ---- helpers ----
md5_() { if command -v md5 >/dev/null 2>&1; then md5 -q; else md5sum | cut -d" " -f1; fi; }
future() {  # $1 file — mtime strictly newer than any marker written during this run
    BUMP=$((BUMP+1)); perl -e 'utime $ARGV[1], $ARGV[1], $ARGV[0]' "$1" $(( $(date +%s) + 60 * BUMP ))
}
edit() { echo "// edit $RANDOM" >> "$1"; future "$1"; }
run_hook() {  # $1 hook  $2 cwd  [$3 mode] → $T/out, $T/err, $RC
    printf '{"cwd":"%s","stop_hook_active":false}' "$2" | bash "$1" ${3:-} >"$T/out" 2>"$T/err"; RC=$?
}
events() { grep -c "hook=$1 .*event=$2" "$LOG" 2>/dev/null || true; }
expect_silent() {  # $1 label
    if [ "$RC" -eq 0 ] && [ ! -s "$T/out" ]; then ok; else bad "expected silent pass (rc=$RC): $1 :: $(head -c 200 "$T/out")"; fi
}
expect_block() {  # $1 label  $2.. substrings the reason must contain
    local label=$1; shift
    if [ "$RC" -ne 0 ] || ! jq -e '.decision == "block"' "$T/out" >/dev/null 2>&1; then bad "expected block (rc=$RC): $label"; return; fi
    local reason; reason=$(jq -r '.reason' "$T/out")
    for s in "$@"; do case "$reason" in *"$s"*) ;; *) bad "block reason lacks '$s': $label"; return ;; esac; done
    ok
}
expect_event() {  # $1 label  $2 hook  $3 event  $4 expected count so far
    local n; n=$(events "$2" "$3"); [ "$n" = "$4" ] && ok || bad "expected $4 x event=$3 for $2 (got $n): $1"
}

# ---- auto-verify ----
R="$T/repo"; mkdir -p "$R/src" "$R/.claude"
cat > "$R/.claude/verify.sh" <<'V'
#!/bin/bash
case "$(cat "$HOME/mode")" in
    pass) exit 0 ;;
    fail) cat "$HOME/out"; exit 1 ;;
    sleep) sleep 30 ;;
esac
V
printf 'export const a = 1;\n' > "$R/src/a.ts"; printf 'export const b = 1;\n' > "$R/src/legacy.ts"
git -C "$R" init -q 2>/dev/null; git_ "$R" add -A; git_ "$R" commit -m c0
mode() { printf '%s' "$1" > "$HOME/mode"; }
out()  { printf '%s\n' "$1" > "$HOME/out"; }
STATE() { echo "$HOME/.claude/state/stop-gate/$(printf "%s" "$(git -C "$R" rev-parse --show-toplevel)" | md5_)"; }

# 1. pass -> silent, remembers the verified HEAD
mode pass; edit "$R/src/a.ts"; run_hook "$AV" "$R"
expect_silent "av pass"
[ "$(cat "$(STATE)/last-verified-sha" 2>/dev/null)" = "$(git -C "$R" rev-parse HEAD)" ] && ok || bad "av pass: last-verified-sha not stored in state"
[ ! -e "$R/.claude/last-verify.txt" ] && [ -f "$(STATE)/last-verify.txt" ] && ok || bad "av marker must live in state, not the repo"
# debounce: file older than the marker -> the failing verify is not even run
mode fail; out "src/a.ts(3,5): error TS2322: nope"; perl -e 'utime 1000000000,1000000000,$ARGV[0]' "$R/src/a.ts"
run_hook "$AV" "$R"; expect_silent "av debounce"

# 2. one failure blocks, with the failure text
edit "$R/src/a.ts"; run_hook "$AV" "$R"
expect_block "av block 1" "src/a.ts(3,5): error TS2322: nope" "auto-verify failed"

# 3. same failure (line numbers moved) -> block 2, then 3rd consecutive releases + logs; then baselined
out "src/a.ts(9,1): error TS2322: nope"; run_hook "$AV" "$R"; expect_block "av block 2" "TS2322"
run_hook "$AV" "$R"; expect_silent "av 3rd identical releases"; expect_event "av released-cap" auto-verify released-cap 1
run_hook "$AV" "$R"; expect_silent "av baseline keeps the next turn free"; expect_event "av baseline preexisting" auto-verify preexisting 1

# 3b. a DIFFERENT failure resets the counter and blocks again (never capped by a per-session total)
out "src/a.ts(1,1): error TS2304: other"; run_hook "$AV" "$R"; expect_block "av distinct error blocks" "TS2304"

# 4. timeout -> released (no block), logged, and fast
mode sleep; edit "$R/src/a.ts"; S=$SECONDS; STOP_GATE_TIMEOUT=1 run_hook "$AV" "$R"
expect_silent "av timeout releases"; expect_event "av timeout" auto-verify timeout 1
[ $((SECONDS - S)) -le 4 ] && ok || bad "av timeout took $((SECONDS - S)) s"

# 5. pre-existing: error in a file unchanged since the last verified HEAD -> pass + preexisting
mode pass; edit "$R/src/a.ts"; run_hook "$AV" "$R"; expect_silent "av re-pass"     # sha = HEAD again
mode fail; out "src/legacy.ts(2,2): error TS2322: old"; edit "$R/src/a.ts"; run_hook "$AV" "$R"
expect_silent "av preexisting passes"; expect_event "av preexisting file" auto-verify preexisting 2
out "$(printf 'src/legacy.ts(2,2): error TS2322: old\nsrc/a.ts(4,4): error TS2322: mine')"; edit "$R/src/a.ts"; run_hook "$AV" "$R"
expect_block "av keeps only the changed file's error" "src/a.ts(4,4)"
jq -r .reason "$T/out" | grep -q 'legacy.ts' && bad "av reason still lists the unchanged file" || ok

# 6. a turn that commits before stopping is still verified (clean tree, HEAD moved)
mode pass; edit "$R/src/a.ts"; run_hook "$AV" "$R"; expect_silent "av pass before commit-turn"
edit "$R/src/a.ts"; git_ "$R" add -A; git_ "$R" commit -m c1
mode fail; out "src/a.ts(7,7): error TS2322: committed"; run_hook "$AV" "$R"
expect_block "av commit-turn verified" "committed"
[ -z "$(git -C "$R" status --porcelain)" ] && ok || bad "av commit-turn: tree should be clean"

echo "verify-gate: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
