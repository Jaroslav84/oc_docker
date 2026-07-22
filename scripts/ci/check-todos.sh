#!/bin/bash
# check-todos.sh — ADVISORY (always exit 0) list of outstanding TODOs.
# Lists every `TODO:` and `TODO(...):` comment across src/ + scripts/ so
# they don't rot silently. Prefix with a tag like `TODO(s3c-gorilla-tag):`
# to group related concerns for grepping.
set -u
REPO="$(cd "$(dirname "$0")/../.." && pwd)"

echo "── outstanding TODOs ──"
_count=0
while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '  %s\n' "$line"
    _count=$((_count + 1))
done < <(
    grep -rn -E '(^|[^A-Za-z0-9_])TODO(\([^)]*\))?:' \
        "$REPO/src" "$REPO/scripts" "$REPO/plans" 2>/dev/null \
        | grep -v '/\.git/' \
        | grep -v 'scripts/ci/check-todos\.sh'
)

echo "── grouped by tag ──"
while IFS= read -r line; do
    [ -z "$line" ] && continue
    printf '  %s\n' "$line"
done < <(
    grep -rh --exclude-dir=.git --exclude='check-todos.sh' -E 'TODO\([^)]+\)' \
        "$REPO/src" "$REPO/scripts" "$REPO/plans" 2>/dev/null \
        | grep -oE 'TODO\([a-zA-Z][-a-zA-Z0-9_]*\)' \
        | sort | uniq -c | sort -rn
)

echo "(advisory only — total: $_count TODO(s))"
exit 0
