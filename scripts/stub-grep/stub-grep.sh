#!/usr/bin/env bash
# stub-grep.sh - fail when ADDED lines carry stub markers (TODO, FIXME, XXX, HACK, "not implemented",
# "// stub", lorem ipsum). Scans every file changed vs a base (committed, staged, unstaged, untracked);
# lines that already existed in the base are never reported.
# Usage: stub-grep.sh [--base <ref>]   default base: merge-base of HEAD with origin/main, main, origin/master, master
# Exit: 0 clean, 1 stubs found (file:line: text on stdout), 2 usage error or not a git repo.
set -u
# Paths never scanned (git pathspec globs; * crosses directories). Tests stay scanned.
IGNORE=('*.md' '*.lock' '*lock.json' '*lock.yaml' '*.snap' '*.map' '*.min.*' '*stub-grep*'
        'node_modules/*' '*/node_modules/*' 'dist/*' 'build/*' '.next/*' 'coverage/*' '*/generated/*')
BASE=
while [ $# -gt 0 ]; do
  case $1 in
    --base) [ $# -ge 2 ] || { echo "stub-grep: --base needs a ref" >&2; exit 2; }; BASE=$2; shift 2 ;;
    -h|--help) sed -n 2,6p "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "usage: stub-grep.sh [--base <ref>]" >&2; exit 2 ;;
  esac
done
ROOT=$(git rev-parse --show-toplevel 2>/dev/null) || { echo "stub-grep: not a git repository" >&2; exit 2; }
cd "$ROOT" || exit 2
if [ -n "$BASE" ]; then
  git rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "stub-grep: unknown base ref $BASE" >&2; exit 2; }
else
  for ref in origin/main main origin/master master; do
    git rev-parse --verify -q "$ref^{commit}" >/dev/null && BASE=$(git merge-base HEAD "$ref" 2>/dev/null) && [ -n "$BASE" ] && break
    BASE=
  done
  if [ -z "$BASE" ]; then
    # No main/master ref (e.g. a shallow single-branch CI checkout): only uncommitted changes can be scanned.
    echo "stub-grep: no main/master ref found; scanning uncommitted changes only (pass --base <ref>; in CI use fetch-depth: 0)" >&2
    BASE=$(git rev-parse --verify -q HEAD || git hash-object -t tree /dev/null)
  fi
fi
SPEC=(--); for g in "${IGNORE[@]}"; do SPEC+=(":!$g"); done
# Unified diff with zero context; untracked files diff against /dev/null so all their lines count as added.
OUT=$({
  git diff -U0 --no-color "$BASE" "${SPEC[@]}"
  git ls-files -z --others --exclude-standard "${SPEC[@]}" |
    while IFS= read -r -d '' f; do git diff --no-index -U0 --no-color /dev/null "$f"; done
} 2>/dev/null | awk '
  /^\+\+\+ /   { file = substr($0, 7); next }
  /^@@ /       { split($3, a, ","); n = substr(a[1], 2) + 0; next }
  /^\+/        { line = substr($0, 2)
                 if (line ~ /(^|[^A-Za-z0-9_])(TODO|FIXME|XXX|HACK)([^A-Za-z0-9_]|$)|[Nn]ot [Ii]mplemented|(\/\/|#) *[Ss]tub([^A-Za-z0-9_]|$)|[Ll]orem [Ii]psum/)
                   print file ":" n ": " substr(line, 1, 200)
                 n++ }
')
[ -z "$OUT" ] && exit 0
printf '%s\n' "$OUT"
echo "stub-grep: $(printf '%s\n' "$OUT" | wc -l | tr -d ' ') stub marker(s) in added lines; finish or remove them" >&2
exit 1
