#!/bin/bash
# test.sh — fixtures for pre-commit-gate.sh (secret/credential gate, chain-aware) and protected-files.sh.
# PreToolUse payloads are piped in the way Claude Code does; HOME is a sandbox, every repo lives under it,
# no network. Exit 1 on any failed expectation.
set -u
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GATE="$HERE/pre-commit-gate.sh"
T=$(mktemp -d /tmp/commit-guard-test.XXXXXX); trap 'rm -rf "$T"' EXIT
# The macOS python3 shim is ~100 ms slower under an unfamiliar HOME unless it is told where the toolchain is.
[ -z "${DEVELOPER_DIR:-}" ] && command -v xcode-select >/dev/null 2>&1 && export DEVELOPER_DIR="$(xcode-select -p 2>/dev/null)"
export HOME="$T/home"; mkdir -p "$HOME/repos"
N=0

payload() {  # $1 command  $2 cwd
    jq -nc --arg c "$1" --arg d "$2" '{tool_name: "Bash", tool_input: {command: $c}, cwd: $d, hook_event_name: "PreToolUse"}'
}
# Each case runs as a background job (the python3 start-up dominates) and leaves PASS or a FAIL line in $T/res.<n>.
job() { N=$((N+1)); ( "$@" > "$T/res.$N" 2>&1 ) & }
_gate() {  # $1 label  $2 expected rc  $3 command  $4 cwd
    local rc; payload "$3" "$4" | bash "$GATE" >/dev/null 2>"$T/err.$N"; rc=$?
    [ "$rc" -eq "$2" ] && echo PASS || echo "FAIL $1: rc=$rc, expected $2 ($(head -c 200 "$T/err.$N"))"
}
gate() { job _gate "$1" "$2" "$3" "$4"; }
expect() { N=$((N+1)); if [ "$2" = "$3" ]; then echo PASS; else echo "FAIL $1 (want $2, got $3)"; fi > "$T/res.$N"; }

# --- pre-commit-gate
SK="sk-$(printf 'a%.0s' $(seq 1 40))"; GH="ghp_$(printf 'b%.0s' $(seq 1 30))"; AK="AKIA$(printf 'C%.0s' $(seq 1 16))"
R="$HOME/repos/repo"; S="$HOME/repos/staged"; M="$HOME/repos/modified"
for d in "$R" "$S" "$M"; do
    mkdir -p "$d"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t
    echo base > "$d/base.txt"; git -C "$d" add base.txt; git -C "$d" commit -q -m base
done
echo "key = $SK" > "$R/x"; echo "hello" > "$R/clean"; echo "task-$(printf 'a%.0s' $(seq 1 40))" > "$R/task.txt"
echo "$GH" > "$R/gh"; echo "$AK" > "$R/ak"; echo "TOKEN=1" > "$R/.env"
echo "key = $SK" > "$S/x"; git -C "$S" add x
echo "key = $SK" >> "$M/base.txt"

gate 'git add x && git commit (sk- fixture)' 2 'git add x && git commit -m m' "$R"
gate 'git add clean && git commit' 0 'git add clean && git commit -m m' "$R"
gate "task- text is not a key" 0 'git add task.txt && git commit -m m' "$R"
gate 'ghp_ fixture' 2 'git add gh && git commit -m m' "$R"
gate 'AKIA fixture' 2 'git add ak && git commit -m m' "$R"
gate '.env via git add' 2 'git add .env && git commit -m m' "$R"
gate 'git add . && git commit' 2 'git add . && git commit -m m' "$R"
gate 'cd repo, from another cwd' 2 "cd $R && git add x && git commit -m m" "$T"
gate 'git -C <repo> commit fast path (nothing staged)' 0 "git -C $M commit -m m" "$T"
gate 'git -C <repo> commit, staged secret' 2 "git -C $S commit -m m" "$T"
gate 'git -c k=v commit, staged secret' 2 'git -c user.name=a commit -m m' "$S"
gate 'commit -am, tracked modified secret' 2 'git commit -am m' "$M"
gate 'commit --all' 2 'git commit --all -m m' "$M"
gate 'plain commit does not stage the modified file' 0 'git commit -m m' "$M"
gate 'heredoc message is not scanned' 0 "$(printf 'git add clean && git commit -m "$(cat <<'"'"'EOF'"'"'\nmention %s here\nEOF\n)"' "$SK")" "$R"
gate 'git log --grep commit passes' 0 'git log --grep commit' "$R"
gate 'not a git repo passes' 0 'git commit -m m' "$T"
gate 'ls passes' 0 'ls' "$R"

# -- add -f lists gitignored files; wrappers (bash -c, eval) are expanded; jq fallback; caps; warn; credential paths
F="$HOME/repos/ignored"; Q="$HOME/repos/tracked"; W="$HOME/repos/warn"; NH="$HOME/repos/nohead"
BIG="$HOME/repos/many"; HUGE="$HOME/repos/toomany"; C="$HOME/repos/cred"
for d in "$F" "$Q" "$W" "$C"; do
    mkdir -p "$d"; git -C "$d" init -q; git -C "$d" config user.email t@t; git -C "$d" config user.name t
done
mkdir -p "$NH" "$BIG" "$HUGE"; git -C "$NH" init -q; git -C "$BIG" init -q; git -C "$HUGE" init -q
printf '.env\nsecret.txt\n' > "$F/.gitignore"; echo "TOKEN=1" > "$F/.env"; echo "key = $SK" > "$F/secret.txt"; echo hello > "$F/clean"
echo "key = $SK" > "$NH/x"
echo one > "$Q/sp ace.txt"; echo one > "$Q/ünï.txt"; echo one > "$Q/ok.txt"; echo one > "$Q/bad.txt"
git -C "$Q" add . ; git -C "$Q" commit -q -m base
echo "key = $SK" >> "$Q/sp ace.txt"; echo "key = $SK" >> "$Q/ünï.txt"; echo "more" >> "$Q/ok.txt"; echo "key = $SK" >> "$Q/bad.txt"
seq 1 500 | sed 's/^/line /' > "$W/big"; echo small > "$W/small"
( cd "$BIG" && seq -w 1 600 | sed 's/^/zz-/' | xargs touch ) ; echo "key = $SK" > "$BIG/zz-499"
( cd "$HUGE" && seq 1 5100 | sed 's/^/f/' | xargs touch )
mkdir -p "$C/config" "$C/docs" "$C/src"
for f in .env.example .env.sample .env.template config/credentials.json credentials docs/credentials-guide.md \
         src/credentialsForm.tsx id_rsa id_ed25519 a.pem .env.local .env.production; do echo x > "$C/$f"; done
mkdir -p "$T/gatejq" "$T/gateemptyjq"
printf '#!/bin/sh\nexit 1\n' > "$T/gatejq/jq"; printf '#!/bin/sh\nexit 0\n' > "$T/gateemptyjq/jq"
chmod +x "$T/gatejq/jq" "$T/gateemptyjq/jq"

_gate_msg() {  # $1 label  $2 expected rc  $3 stderr pattern (leading ! = must not match)  $4 command  $5 cwd
    local rc pat="$3" want=1; payload "$4" "$5" | bash "$GATE" >/dev/null 2>"$T/err.$N"; rc=$?
    case "$pat" in '!'*) pat="${pat#!}"; want=0 ;; esac
    grep -qE "$pat" "$T/err.$N"; local got=$?
    if [ "$rc" -ne "$2" ]; then echo "FAIL $1: rc=$rc, expected $2 ($(head -c 200 "$T/err.$N"))"
    elif { [ "$want" -eq 1 ] && [ "$got" -ne 0 ]; } || { [ "$want" -eq 0 ] && [ "$got" -eq 0 ]; }; then
        echo "FAIL $1: stderr vs /$3/ ($(head -c 200 "$T/err.$N"))"
    else echo PASS; fi
}
gate_msg() { job _gate_msg "$1" "$2" "$3" "$4" "$5"; }
_gate_fast() {  # $1 label  $2 expected rc  $3 max seconds  $4 command  $5 cwd
    local rc t0=$SECONDS; payload "$4" "$5" | bash "$GATE" >/dev/null 2>"$T/err.$N"; rc=$?
    local dt=$((SECONDS - t0))
    if [ "$rc" -ne "$2" ]; then echo "FAIL $1: rc=$rc, expected $2 ($(head -c 200 "$T/err.$N"))"
    elif [ "$dt" -ge "$3" ]; then echo "FAIL $1: took ${dt}s (limit ${3}s)"
    else echo PASS; fi
}
# Timed alone: wait for the background jobs first so their load does not count against the limit.
gate_fast() { wait; N=$((N+1)); _gate_fast "$1" "$2" "$3" "$4" "$5" > "$T/res.$N" 2>&1; }
_gate_nojq() {  # $1 label  $2 expected rc  $3 stub dir  $4 command  $5 cwd
    local rc; payload "$4" "$5" | PATH="$T/$3:$PATH" bash "$GATE" >/dev/null 2>"$T/err.$N"; rc=$?
    [ "$rc" -eq "$2" ] && echo PASS || echo "FAIL $1: rc=$rc, expected $2 ($(head -c 200 "$T/err.$N"))"
}
gate_nojq() { job _gate_nojq "$1" "$2" "$3" "$4" "$5"; }

# 1) git add -f / --force reaches gitignored files
gate 'add -f .env (gitignored)' 2 'git add -f .env && git commit -m m' "$F"
gate 'add --force secret.txt (gitignored)' 2 'git add --force secret.txt && git commit -m m' "$F"
gate 'add -fv .env (flag cluster)' 2 'git add -fv .env && git commit -m m' "$F"
gate 'add -f -- .env' 2 'git add -f -- .env && git commit -m m' "$F"
gate 'add .env without -f (git refuses ignored)' 0 'git add .env && git commit -m m' "$F"
gate 'add -f clean' 0 'git add -f clean && git commit -m m' "$F"
# 2) wrappers
gate 'bash -c wrapper' 2 "bash -c 'git add x && git commit -m m'" "$R"
gate 'sh -c wrapper (double quotes)' 2 'sh -c "git add x && git commit -m m"' "$R"
gate 'zsh -c wrapper' 2 "zsh -c 'git add x && git commit -m m'" "$R"
gate 'dash -c wrapper' 2 "dash -c 'git add x && git commit -m m'" "$R"
gate 'bash -lc wrapper' 2 "bash -lc 'git add x && git commit -m m'" "$R"
gate 'bash -o pipefail -c wrapper' 2 "bash -o pipefail -c 'git add x && git commit -m m'" "$R"
gate 'eval wrapper' 2 'eval "git add x && git commit -m m"' "$R"
gate 'sudo env bash -c wrapper' 2 "sudo env A=1 bash -c 'git add x && git commit -m m'" "$R"
gate 'add outside, commit inside bash -c' 2 "git add x && bash -c 'git commit -m m'" "$R"
gate 'bash -c with cd, other cwd' 2 "bash -c 'cd $R && git add x && git commit -m m'" "$T"
gate 'nested wrappers (3 deep)' 2 "bash -c \"sh -c 'eval \\\"git add x && git commit -m m\\\"'\"" "$R"
gate 'bash -c clean passes' 0 "bash -c 'git add clean && git commit -m m'" "$R"
gate 'eval clean passes' 0 'eval "git add clean && git commit -m m"' "$R"
gate 'bash script file is not -c' 0 'bash run.sh && git commit -m m' "$R"
# 3) jq missing or useless -> python3 fallback
gate_nojq 'jq failing stub, sk- blocked' 2 gatejq 'git add x && git commit -m m' "$R"
gate_nojq 'jq failing stub, clean passes' 0 gatejq 'git add clean && git commit -m m' "$R"
gate_nojq 'jq empty stub, sk- blocked' 2 gateemptyjq 'git add x && git commit -m m' "$R"
gate_nojq 'jq failing stub, cwd honoured' 2 gatejq 'git commit -am m' "$M"
# 4) batching, speed and cap
gate_fast '600 files staged, late one holds the key, under 5 s' 2 5 'git add . && git commit -m m' "$BIG"
gate_msg '5100 files staged is blocked' 2 'more than 5000 files' 'git add . && git commit -m m' "$HUGE"
gate 'no HEAD yet: untracked file read from disk' 2 'git add x && git commit -m m' "$NH"
gate 'tracked modified file with a space in its name' 2 "git add 'sp ace.txt' && git commit -m m" "$Q"
gate 'tracked modified file with non-ASCII name' 2 'git add ünï.txt && git commit -m m' "$Q"
gate 'secret in a different modified file is not blamed on ok.txt' 0 'git add ok.txt && git commit -m m' "$Q"
gate 'git add -u picks the tracked secret' 2 'git add -u && git commit -m m' "$Q"
# 5) size warning counts what the command stages
gate_msg 'add big (500 lines) warns' 0 'WARNING' 'git add big && git commit -m m' "$W"
gate_msg 'add small does not warn' 0 '!WARNING' 'git add small && git commit -m m' "$W"
# 6) credential-shaped paths
for f in .env.example .env.sample .env.template docs/credentials-guide.md src/credentialsForm.tsx; do
    gate "allow $f" 0 "git add $f && git commit -m m" "$C"
done
for f in config/credentials.json credentials id_rsa id_ed25519 a.pem .env.local .env.production; do
    gate "block $f" 2 "git add $f && git commit -m m" "$C"
done

# --- protected-files
PF="$HERE/protected-files.sh"
pf() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$PF" >/dev/null 2>&1; echo $?; }
for p in /p/.env /p/.env.local "$HOME/.app.env" /p/x.env /p/sub/prod.env /p/.git/config /p/package-lock.json; do
  expect "block $p" 2 "$(pf "$p")"
done
for p in /p/src/a.ts /p/README.md /p/environment.ts /p/.env.example /p/.env.sample /p/src/lib/secrets.ts /p/docs/credentials-guide.md /p/secrets-rotator/main.go; do expect "allow $p" 0 "$(pf "$p")"; done
for p in /p/config/credentials.json /p/credentials /p/deploy/secrets.yaml /p/certs/key.pem; do expect "block $p" 2 "$(pf "$p")"; done
for p in /p/.claude/verify.sh /p/.claude/settings.json /p/.claude/settings.local.json; do
  out=$(printf '{"tool_input":{"file_path":"%s"}}' "$p" | bash "$PF" 2>/dev/null); rc=$?
  expect "ask $p" "0 ask" "$rc $(printf '%s' "$out" | jq -r .hookSpecificOutput.permissionDecision 2>/dev/null)"
done
expect "empty stdin allowed" 0 "$(printf '' | bash "$PF" >/dev/null 2>&1; echo $?)"

# jq shadowed by a failing stub -> python3 fallback must still block
mkdir -p "$T/failjq" "$T/emptyjq"
printf '#!/bin/sh\nexit 1\n' > "$T/failjq/jq"; printf '#!/bin/sh\nexit 0\n' > "$T/emptyjq/jq"
chmod +x "$T/failjq/jq" "$T/emptyjq/jq"
for stub in failjq emptyjq; do
  rc=$(printf '{"tool_input":{"file_path":"/p/.env.local"}}' | PATH="$T/$stub:$PATH" bash "$PF" >/dev/null 2>&1; echo $?)
  expect "$stub fallback blocks .env.local" 2 "$rc"
  rc=$(printf '{"tool_input":{"file_path":"/p/src/a.ts"}}' | PATH="$T/$stub:$PATH" bash "$PF" >/dev/null 2>&1; echo $?)
  expect "$stub fallback allows a.ts" 0 "$rc"
done

wait
PASS=$(cat "$T"/res.* | grep -c '^PASS$'); FAILS=$((N - PASS))
cat "$T"/res.* | grep -v '^PASS$'
[ "$FAILS" -eq 0 ] && { echo "commit-guard: $PASS passed"; exit 0; }
echo "commit-guard: $FAILS failed, $PASS passed"; exit 1
