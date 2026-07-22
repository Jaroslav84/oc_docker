# setup/clipboard.sh — cross-platform "copy to clipboard" helper.
# Detects pbcopy (macOS), xclip (X11), or wl-copy (Wayland) in that order.
# Returns 0 on success, 1 if no clipboard tool is available.
#
# Usage:  _copy_to_clipboard "text to copy"

_copy_to_clipboard() {
    if command -v pbcopy >/dev/null 2>&1; then
        printf '%s' "$1" | pbcopy
        return $?
    elif command -v xclip >/dev/null 2>&1; then
        printf '%s' "$1" | xclip -selection clipboard
        return $?
    elif command -v wl-copy >/dev/null 2>&1; then
        printf '%s' "$1" | wl-copy
        return $?
    fi
    return 1
}
