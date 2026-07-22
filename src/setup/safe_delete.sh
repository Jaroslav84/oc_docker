# setup/safe_delete.sh — one helper for the "trash if possible, refuse if not"
# pattern used across install.d + setup. Kept OUT of docker/ (rm-guard.sh
# has its own richer container-side routing that also goes through the
# builder-api host trash job).
#
# Usage:  safe_delete <path> [<path>...]
#   - Prefers `trash` (macOS default: brew install trash), then `trash-put`
#     (Linux trash-cli), then loud refuse to stderr + return 1.
#   - Best-effort per path: continues after individual failures, returns
#     0 iff all paths were trashed, non-zero if any refused.

safe_delete() {
    local rc=0
    local tool=""
    local _p
    if command -v trash >/dev/null 2>&1; then
        tool="trash"
    elif command -v trash-put >/dev/null 2>&1; then
        tool="trash-put"
    fi
    if [ -z "$tool" ]; then
        printf 'safe_delete: WARNING: no trash tool found (need `trash` on macOS or `trash-cli` on Linux). Refusing to delete:\n' >&2
        for _p in "$@"; do printf '  %s\n' "$_p" >&2; done
        return 1
    fi
    for _p in "$@"; do
        # No `--` — macOS `brew install trash` doesn't accept it. Paths that
        # start with `-` are a rare edge case; callers should absolute-path them.
        "$tool" "$_p" 2>/dev/null || {
            printf 'safe_delete: failed to trash %s\n' "$_p" >&2
            rc=1
        }
    done
    return "$rc"
}
