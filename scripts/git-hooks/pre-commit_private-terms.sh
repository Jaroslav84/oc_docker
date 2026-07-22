#!/bin/bash
# pre-commit_private-terms.sh — blocks commits that ADD lines mentioning
# private-project names to this PUBLIC repo. Only new additions in the diff
# trigger; existing content is not flagged.
#
# Path whitelist (skipped even if they contain terms): CLAUDE.md, MEMORY.md,
# docs/, plans/, .git-hooks/, memory/. Extend via
# .git-hooks/private-terms-whitelist.txt (one glob per line, # comments OK).
#
# Per-file opt-out: any file whose first 5 lines contain
#   # private-terms: allowed
# or
#   <!-- private-terms: allowed -->
# is skipped from the check.
#
# Terms override: put one term per line in .git-hooks/private-terms.txt to
# extend/replace the hardcoded list. Blank lines and #-comments ignored.
# If the override file is present but yields NO terms, the hardcoded list
# stays in force (so a mis-authored override doesn't disable protection).
#
# Bypass (only if truly intentional):  git commit --no-verify
set -u

REPO="$(git rev-parse --show-toplevel 2>/dev/null)" || exit 0   # no repo? skip
TERMS_FILE="$REPO/.git-hooks/private-terms.txt"
WHITELIST_FILE="$REPO/.git-hooks/private-terms-whitelist.txt"
TERMS='slav-ai|purpletech|slav-it\.com|lounge'

if [ -f "$TERMS_FILE" ]; then
    _TERMS_FROM_FILE="$(grep -Ev '^[[:space:]]*(#|$)' "$TERMS_FILE" | tr '\n' '|' | sed 's/|$//')"
    if [ -n "$_TERMS_FROM_FILE" ]; then
        TERMS="$_TERMS_FROM_FILE"
    fi
fi

# Default whitelist globs. Files matching any of these are skipped entirely.
_default_whitelist='CLAUDE.md */CLAUDE.md MEMORY.md */MEMORY.md docs/* plans/* .git-hooks/* memory/* */memory/*'
_extra_whitelist=""
if [ -f "$WHITELIST_FILE" ]; then
    _extra_whitelist="$(grep -Ev '^[[:space:]]*(#|$)' "$WHITELIST_FILE" | tr '\n' ' ')"
fi

_is_whitelisted() {
    local f="$1" pat
    for pat in $_default_whitelist $_extra_whitelist; do
        # shellcheck disable=SC2254
        case "$f" in $pat) return 0 ;; esac
    done
    return 1
}

_has_optout_marker() {
    local f="$1"
    if git show ":$f" 2>/dev/null | head -5 | grep -qE '(#|<!--)[[:space:]]*private-terms:[[:space:]]*allowed'; then
        return 0
    fi
    if [ -f "$REPO/$f" ] && head -5 "$REPO/$f" 2>/dev/null | grep -qE '(#|<!--)[[:space:]]*private-terms:[[:space:]]*allowed'; then
        return 0
    fi
    return 1
}

# Build the list of files to actually scan.
_files_to_check=""
while IFS= read -r f; do
    [ -z "$f" ] && continue
    if _is_whitelisted "$f"; then continue; fi
    if _has_optout_marker "$f"; then continue; fi
    _files_to_check="$_files_to_check $f"
done <<EOF
$(git diff --cached --name-only 2>/dev/null)
EOF

if [ -z "$_files_to_check" ]; then
    exit 0
fi

# shellcheck disable=SC2086
HITS="$(git diff --cached -U0 -- $_files_to_check 2>/dev/null | grep -E '^\+[^+]' | grep -Ei "$TERMS" || true)"

if [ -n "$HITS" ]; then
    printf '\n\033[31m‼️ pre-commit block:\033[0m staged changes ADD lines mentioning private terms.\n' >&2
    printf '   Terms: %s\n' "$TERMS" >&2
    printf '   Offending lines:\n' >&2
    printf '%s\n' "$HITS" | sed 's/^/     /' >&2
    printf '\n   Options:\n' >&2
    printf '   1. Reword generically, then re-stage.\n' >&2
    printf '   2. Add the file path to .git-hooks/private-terms-whitelist.txt (if it belongs there).\n' >&2
    printf '   3. Add `# private-terms: allowed` to the file top (if it discusses the terms as examples).\n' >&2
    printf '   4. Bypass with `git commit --no-verify` (only if truly intentional).\n\n' >&2
    exit 1
fi
exit 0
