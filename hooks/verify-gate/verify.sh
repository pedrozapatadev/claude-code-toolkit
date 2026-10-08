#!/usr/bin/env bash
# Definition of done, in two tiers. Copy to <repo>/.claude/verify.sh.
# Runs from the auto-verify Stop hook (auto-verify.sh) and by hand:
#   bash .claude/verify.sh                  DEFAULT tier, budget 80 s: typecheck -> lint -> test
#   VERIFY_FULL=1 bash .claude/verify.sh    FULL tier, budget 900 s: the default steps plus test:e2e and build
#                                           (each only when package.json defines it). Run it with the Bash
#                                           tool timeout maximum, 600000 ms, or in the background.
# Wire the FULL tier into a pre-push hook so no unverified commit leaves the machine.
#
# Steps come from package.json scripts (typecheck, lint, test, test:e2e, build); a repo without a
# typecheck script but with tsconfig.json falls back to `tsc --noEmit`. A missing step is reported
# as SKIP, never silently. Exit codes: 0 pass, 1 a step failed or cannot run, 124 the time budget
# is spent (the Stop hook releases and logs 124, since a slow machine proves nothing broken; pre-push should still block).
# VERIFY_BUDGET=<seconds> overrides the budget. Keep the default under the Stop hook's 100 s window.
# Tune the per-project details (extra env, a lint cache flag, a narrower default test command) here.
set -u
cd "$(dirname "$0")/.." || exit 1

if [ "${VERIFY_FULL:-}" = 1 ]; then BUDGET="${VERIFY_BUDGET:-900}"; else BUDGET="${VERIFY_BUDGET:-80}"; fi
START=$SECONDS
STEP_PID=
export CI=1 NEXT_TELEMETRY_DISABLED=1 NO_COLOR=1 # no prompts, no telemetry, no ANSI in the logs
unset FORCE_COLOR
LOGS=$(mktemp -d "${TMPDIR:-/tmp}/verify.XXXXXX") || { echo "verify: cannot create a temp dir"; exit 1; }

tree() { # a pid and everything under it
  local child
  echo "$1"
  for child in $(pgrep -P "$1" 2>/dev/null); do tree "$child"; done
}

stop_tree() { # TERM, wait up to 2 s, then KILL what is still alive, so no step is left running
  local pids i
  pids=$(tree "$1")
  kill -TERM $pids 2>/dev/null
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20; do kill -0 "$1" 2>/dev/null || break; sleep 0.1; done
  kill -KILL $pids 2>/dev/null
}
trap '[ -n "$STEP_PID" ] && stop_tree "$STEP_PID"; exit 1' HUP INT TERM

fail() { # fail <step> <why> [log]
  echo "verify: $1 FAIL - $2"
  if [ -s "${3:-}" ]; then
    echo "verify: full log $3"
    echo "verify: key lines:"
    grep -E 'FAIL|Error:|error TS[0-9]|[0-9]+:[0-9]+ +error|Failed to compile|Module not found|ELIFECYCLE' "$3" | cut -c1-200 | head -6
    echo "verify: last 40 lines:"
    tail -40 "$3"
  fi
  echo "verify: FAILED at $1; later steps not run"
  exit "${FAIL_RC:-1}" # 124 only for a spent time budget (see the header)
}

step() { # step <name> <command...>: stdin closed, output to a log, stopped when the budget is spent
  local name=$1 log="$LOGS/$1.log" t0=$SECONDS rc=0
  shift
  "$@" >"$log" 2>&1 </dev/null &
  STEP_PID=$!
  while kill -0 "$STEP_PID" 2>/dev/null; do
    if [ $((SECONDS - START)) -ge "$BUDGET" ]; then
      stop_tree "$STEP_PID"
      # The first line stays identical from run to run (no log path, no output): the Stop hook fingerprints it.
      FAIL_RC=124 fail "$name" "TIMEOUT, the ${BUDGET}s budget is spent (VERIFY_BUDGET=n changes it); $name NOT verified" "$log"
    fi
    sleep 0.2
  done
  wait "$STEP_PID" || rc=$?
  STEP_PID=
  [ "$rc" -eq 0 ] || fail "$name" "exit $rc after $((SECONDS - t0))s ($*)" "$log"
  echo "verify: $name PASS ($((SECONDS - t0))s)"
}

has_script() { # has_script <name>: package.json defines that script
  [ -f package.json ] && node -e 'process.exit((require("./package.json").scripts||{})[process.argv[1]]?0:1)' "$1" 2>/dev/null
}

if [ -f pnpm-lock.yaml ]; then PM=pnpm; elif [ -f yarn.lock ]; then PM=yarn; else PM=npm; fi
command -v "$PM" >/dev/null 2>&1 || fail setup "$PM is not on PATH"
command -v node >/dev/null 2>&1 || fail setup "node is not on PATH"
[ -d node_modules ] || fail setup "node_modules is missing; install dependencies first"

run_script() { # run_script <script> [fallback command...]: SKIP out loud when neither exists
  local s=$1
  shift
  if has_script "$s"; then step "$s" "$PM" run "$s"
  elif [ $# -gt 0 ]; then step "$s" "$@"
  else echo "verify: $s SKIP (no \"$s\" script in package.json)"; fi
}

if [ -f tsconfig.json ]; then run_script typecheck npx --no-install tsc --noEmit; else run_script typecheck; fi
run_script lint
run_script test
if [ "${VERIFY_FULL:-}" = 1 ]; then
  run_script test:e2e
  run_script build
fi

rm -rf "$LOGS"
if [ "${VERIFY_FULL:-}" = 1 ]; then SCOPE="full tier"; else SCOPE="default tier; VERIFY_FULL=1 adds e2e and build"; fi
echo "verify: OK ($((SECONDS - START))s); $SCOPE"
