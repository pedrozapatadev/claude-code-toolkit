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

# --- protected-files
PF="$HERE/protected-files.sh"
pf() { printf '{"tool_input":{"file_path":"%s"}}' "$1" | bash "$PF" >/dev/null 2>&1; echo $?; }
for p in /p/.env /p/.env.local "$HOME/.app.env" /p/x.env /p/sub/prod.env /p/.git/config /p/package-lock.json; do
  expect "block $p" 2 "$(pf "$p")"
done
for p in /p/src/a.ts /p/README.md /p/environment.ts; do expect "allow $p" 0 "$(pf "$p")"; done
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
