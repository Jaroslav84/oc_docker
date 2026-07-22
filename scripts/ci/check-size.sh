#!/bin/bash
# check-size.sh — line-count report for runtime source. Grandfathered offenders
# (KNOWN list) stay advisory. Any NEW file over the cap HARD-FAILS.
# Sweet spot 200, hard cap 500. macOS bash 3.2-safe.
set -u
SRC="$(cd "$(dirname "$0")/../../src" && pwd)"
CAP=500
# Files we already know exceed the cap (split is planned / accepted):
KNOWN="cld ocd server.py jobs.py docker_log.sh build_queue.py"

_TALLY="$(mktemp)"
trap '/bin/rm -f "$_TALLY"' EXIT
printf '0\n' > "$_TALLY"

echo "── runtime files over $CAP lines ──"
find "$SRC" -type f \( -name '*.sh' -o -name 'cld' -o -name 'ocd' -o -name '*.py' \) \
    ! -path '*/lib/ywizz/*' ! -path '*/quake_api/*' \
    ! -name 'install_devpack.sh' ! -name 'install_cli.sh' -print0 \
  | while IFS= read -r -d '' f; do
        n=$(wc -l < "$f" | tr -d ' ')
        [ "$n" -le "$CAP" ] && continue
        base="$(basename "$f")"
        tag="NEW — split me"; is_known=0
        for k in $KNOWN; do [ "$base" = "$k" ] && { tag="known/pending"; is_known=1; }; done
        printf '  %4d  %-26s [%s]\n' "$n" "${f#$SRC/}" "$tag"
        if [ "$is_known" -eq 0 ]; then
            # Piped subshell — mutate via tempfile so parent sees the count.
            _c="$(cat "$_TALLY")"
            printf '%d\n' "$((_c + 1))" > "$_TALLY"
        fi
    done

_over_new="$(cat "$_TALLY")"
if [ "$_over_new" -gt 0 ]; then
    echo "check-size: FAIL — $_over_new new file(s) over $CAP lines (not on KNOWN list)" >&2
    exit 1
fi
echo "check-size: clean ✓"
