# setup/mask.sh — display-mask helper for printing secrets safely.
#
# Yaro's format: first 3 chars + `*******` + last 3 chars for values ≥8 chars;
# fully masked `********` for shorter values (any first/last 3 chars would
# leak too much of a short secret).

_mask_secret_display() {
    local V="$1"
    local n=${#1}
    if [ "$n" -lt 8 ]; then
        printf '********'
    else
        printf '%s*******%s' "${V:0:3}" "${V: -3}"
    fi
}
