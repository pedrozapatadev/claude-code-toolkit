#!/usr/bin/env bash
# Runs every piece's fixture suite. Sandboxed: temp dirs and temp git repos only, no network.
set -u
cd "$(dirname "$0")" || exit 1
FAILED=0
for t in hooks/*/test.sh scripts/*/test.sh; do
  printf '%-32s ' "$t"
  if out=$(bash "$t" 2>&1); then echo "$out" | tail -1; else FAILED=1; echo "FAILED"; echo "$out" | sed 's/^/    /'; fi
done
exit $FAILED
