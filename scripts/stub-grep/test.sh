#!/bin/bash
# test.sh - fixtures for stub-grep.sh.
# Sandbox only: temp git repos under mktemp -d, no network.
# Prints "N passed, M failed"; exit 1 on any failure.
set -u
SG="$(cd "$(dirname "$0")" && pwd)/stub-grep.sh"
T=$(mktemp -d /tmp/stub-grep-test.XXXXXX); trap 'rm -rf "$T"' EXIT
PASS=0; FAILS=0
ok()  { PASS=$((PASS+1)); }
bad() { echo "FAIL $1"; FAILS=$((FAILS+1)); }
g()   { git -C "$1" -c user.email=t@t -c user.name=t -c commit.gpgsign=false "${@:2}" >/dev/null 2>&1; }
expect() { # expect <name> <want rc> <got rc>
  if [ "$2" = "$3" ]; then ok; else bad "$1 (want rc $2, got $3)"; fi
}

# ---- stub-grep ----
R="$T/repo"; mkdir -p "$R/src"; g "$R" init -q
printf 'export const a = 1;\n// TODO: old debt\n' > "$R/src/old.ts"
echo "# notes" > "$R/README.md"
g "$R" add -A; g "$R" commit -m base
run() { (cd "$R" && bash "$SG" --base HEAD 2>&1); }

OUT=$(run); expect "clean tree" 0 $?
echo 'export const b = 2;' > "$R/src/clean.ts"; OUT=$(run); expect "(b) clean change" 0 $?
echo '// TODO: wire this' >> "$R/src/old.ts"; OUT=$(run); RC=$?
expect "(a) added TODO" 1 $RC
case "$OUT" in *"src/old.ts:3: // TODO: wire this"*) ok ;; *) bad "(a) output lacks file:line: $OUT" ;; esac
case "$OUT" in *"old debt"*) bad "(c) pre-existing TODO reported" ;; *) ok ;; esac
git -C "$R" checkout -q -- src/old.ts; OUT=$(run); expect "(c) pre-existing TODO untouched" 0 $?
echo "TODO: write docs" >> "$R/README.md"; OUT=$(run); expect "(d) TODO in .md" 0 $?
printf 'export function f() { throw new Error("Not implemented"); }\n' > "$R/src/new.ts"; OUT=$(run); expect "untracked not-implemented" 1 $?
rm "$R/src/new.ts"; printf 'return null; // stub\n' > "$R/src/s.ts"; g "$R" add src/s.ts; OUT=$(run); expect "staged stub" 1 $?
(cd "$R" && bash "$SG" --base nonexistent >/dev/null 2>&1); expect "bad base ref" 2 $?
(cd "$T" && bash "$SG" >/dev/null 2>&1); expect "not a git repo" 2 $?

# shallow / no-main checkout: falls back out loud
N="$T/nomain"; mkdir -p "$N"; g "$N" init -q -b feature; echo x > "$N/a.ts"; g "$N" add -A; g "$N" commit -m c
ERR=$( (cd "$N" && bash "$SG") 2>&1 >/dev/null ); case "$ERR" in *"no main/master ref"*) ok ;; *) bad "fallback is silent: $ERR" ;; esac

echo "stub-grep: $PASS passed, $FAILS failed"
[ "$FAILS" -eq 0 ]
