#!/bin/bash
# Q3IDE Setup Wizard — run via: ./scripts/build.sh --setup

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PARAMS_H="$ROOT/quake3e/code/q3ide/q3ide_params.h"
AUTOEXEC="$ROOT/baseq3/autoexec.cfg"
SETUP_CFG="$ROOT/baseq3/q3ide_setup.cfg"

_G='\033[32m'; _Y='\033[33m'; _C='\033[36m'; _DIM='\033[2m'; _B='\033[1m'; _R0='\033[0m'

_step()  { printf "\n${_B}  ══════════════════════════════════════\n  Step %s: %s\n  ══════════════════════════════════════${_R0}\n" "$1" "$2"; }
_ok()    { printf "  ${_G}✅  %s${_R0}\n" "$1"; }
_warn()  { printf "  ${_Y}⚠️   %s${_R0}\n" "$1"; }
_info()  { printf "  %s\n" "$1"; }
_dim()   { printf "  ${_DIM}%s${_R0}\n" "$1"; }
_ask()   { printf "\n  ${_B}▶ %s${_R0} " "$1"; }
_blank() { printf "\n"; }

PARAMS_CHANGED=0

# ── Pre-detect everything for the banner ──────────────────────────────────────
if [ "$(uname -s)" = "Darwin" ]; then
    _PRE_GPU=$(system_profiler SPDisplaysDataType 2>/dev/null | awk -F': ' '/Chipset Model:/{print $2; exit}')
    _PRE_MON=$(system_profiler SPDisplaysDataType 2>/dev/null | grep -c "Resolution:" 2>/dev/null || echo "?")
else
    _PRE_GPU=$(lspci 2>/dev/null | grep -i "vga\|3d\|display" | head -1 | sed 's/.*: //' || echo "unknown")
    _PRE_MON=$(xrandr --listmonitors 2>/dev/null | awk 'NR==1{print $2}' || echo "?")
fi
[ -z "$_PRE_GPU" ] && _PRE_GPU="unknown"
_PRE_CIN=$(ls "$ROOT/baseq3/zzzpak"*.pk3 2>/dev/null | wc -l | tr -d ' ')
_PRE_MAX=$(python3 -c "
import re, sys
src = open('$PARAMS_H').read()
m = re.search(r'#define\s+Q3IDE_MAX_MONITORS\s*\\\\\s*\n\s*(\d+)', src) or re.search(r'#define\s+Q3IDE_MAX_MONITORS\s+(\d+)', src)
print(m.group(1) if m else '?')
" 2>/dev/null || echo "?")

# ── Banner ────────────────────────────────────────────────────────────────────
_RDIV="──────────────────────────────────────────"
_CIN_STR="$( [ "$_PRE_CIN" -gt 0 ] 2>/dev/null && echo "✅  $_PRE_CIN packs" || echo "⛔  not installed" )"
_A=(
    ""
    "       .,o'           \`o,."
    "     o8'                \`8o"
    "   o8:                    ;8o"
    "  .88                      88."
    "  :88.                    ,88:"
    "  \`888                    888'"
    "   888o   \`888 88 888'   o888"
    "  \`888o,. \`88 88 88' .,o888'"
    "    \`888888888 88 8888888888'"
    "     \`8888888 88 88888888'"
    "         \`::88 88 ;88;:'"
    "           88 88 88"
    "           88 88 88"
    "            8 88 8"
    ""
    "       Quake III IDE"
    ""
)
_R=(
    "Q3IDE  SETUP WIZARD"
    "$_RDIV"
    "$(printf '%-14s%s' 'GPU'       "$_PRE_GPU")"
    "$(printf '%-14s%s' 'Monitors'  "$_PRE_MON detected  (MAX=$_PRE_MAX)")"
    "$(printf '%-14s%s' 'CiNEmatic' "$_CIN_STR")"
    "$_RDIV"
    "Steps:"
    "  1.  CiNEmatic HD textures"
    "  2.  Monitor count"
    "  3.  Monitor layout"
    "  4.  Renderer"
    ""
    ""
    ""
    ""
    ""
    ""
    ""
)
printf '\n'
printf '  ╔══════════════════════════════════════════════════════════════════════════════════════════\n'
for _i in 0 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17; do
    printf '  ║  %-32s  │  %s\n' "${_A[$_i]}" "${_R[$_i]}"
done
printf '  ╚══════════════════════════════════════════════════════════════════════════════════════════\n'

# ── Q3IDE Colossal art ────────────────────────────────────────────────────────
printf '\n'
printf '  ${_DIM}'
printf '   .d88888b.  .d8888b.  8888888 8888888b.  8888888888\n'
printf '  d88P   Y88bd88P  Y88b   888   888   Y88b 888\n'
printf '  888     888      .d88P   888   888    888 888\n'
printf '  888     888     8888"    888   888    888 8888888\n'
printf '  888     888      "Y8b.   888   888    888 888\n'
printf '  Y88b. .d88PY88b  d88P   888   888   d88P 888\n'
printf '   "Y88888P"  "Y8888P" 8888888 8888888P"  8888888888\n'
printf '           "Y8b.\n'
printf '${_R0}\n'

# ═════════════════════════════════════════════════════════════════════════════
# STEP 1 — CiNEmatic HD Textures
# ═════════════════════════════════════════════════════════════════════════════
_step 1 "CiNEmatic HD Textures"

if [ "$_PRE_CIN" -gt 0 ] 2>/dev/null; then
    _ok "Already installed — $_PRE_CIN pack(s) in baseq3/"
else
    _blank
    _info "Replaces all vanilla Q3 textures with HD versions. Optional but dramatic."
    _blank
    _info "  🔗  https://www.moddb.com/mods/cinematic-mod-8k-and-16k-resolution-textures/downloads"
    _blank
    _info "  Download all 6 part zips → save to:  $ROOT"
    _ask "Press Enter when zips are in place — or type 'skip':"
    read -r _INPUT

    if [ "$_INPUT" = "skip" ] || [ "$_INPUT" = "s" ]; then
        _warn "Skipped"
    else
        _ZIPS=()
        for z in "$ROOT"/[Cc]i[Nn][Ee][Mm]atic*.zip "$ROOT"/[Cc]inematic*.zip; do
            [ -f "$z" ] && _ZIPS+=("$z")
        done
        if [ "${#_ZIPS[@]}" -eq 0 ]; then
            _warn "No CiNEmatic zips found in $ROOT — skipping"
        else
            _info "Found ${#_ZIPS[@]} zip(s) — extracting..."
            for z in "${_ZIPS[@]}"; do
                _dim "  $(basename "$z")"
                unzip -o "$z" -d "$ROOT/baseq3/" '*.pk3' 2>/dev/null || \
                    unzip -o "$z" -d "$ROOT/baseq3/" 2>/dev/null || true
            done
            _INSTALLED=$(ls "$ROOT/baseq3/zzzpak"*.pk3 2>/dev/null | wc -l | tr -d ' ')
            if [ "$_INSTALLED" -gt 0 ]; then
                _ok "$_INSTALLED pack(s) installed"
                for z in "${_ZIPS[@]}"; do
                    trash "$z" 2>/dev/null || mv "$z" ~/.Trash/ 2>/dev/null || true
                done
            else
                _warn "No zzzpak*.pk3 found after extraction — check zip contents"
            fi
        fi
    fi
fi
_SUMMARY_CIN="$( ls "$ROOT/baseq3/zzzpak"*.pk3 2>/dev/null | wc -l | tr -d ' ' ) packs"

# ═════════════════════════════════════════════════════════════════════════════
# STEP 2 — Monitor Count
# ═════════════════════════════════════════════════════════════════════════════
_step 2 "Monitor Count"

_DETECTED="$_PRE_MON"
! echo "$_DETECTED" | grep -qE '^[0-9]+$' && _DETECTED=1
[ "$_DETECTED" -lt 1 ] && _DETECTED=1

_dim "macOS detected $_DETECTED monitor(s). MAX_MONITORS currently $_PRE_MAX in params.h."
_ask "How many monitors will you use? [${_DETECTED}]:"
read -r _MON_INPUT
_MON_COUNT="${_MON_INPUT:-$_DETECTED}"

if ! echo "$_MON_COUNT" | grep -qE '^[0-9]+$' || [ "$_MON_COUNT" -lt 1 ]; then
    _warn "Invalid — using $_DETECTED"
    _MON_COUNT="$_DETECTED"
fi

if [ "$_MON_COUNT" != "$_PRE_MAX" ]; then
    python3 - "$PARAMS_H" "$_MON_COUNT" <<'PYEOF'
import sys, re
path, v = sys.argv[1], sys.argv[2]
src = open(path).read()
src2 = re.sub(r'(#define\s+Q3IDE_MAX_MONITORS\s*\\\s*\n\s*)(\d+)', lambda m: m.group(1)+v, src)
if src2 == src:
    src2 = re.sub(r'(#define\s+Q3IDE_MAX_MONITORS\s+)(\d+)', lambda m: m.group(1)+v, src)
open(path, 'w').write(src2)
PYEOF
    PARAMS_CHANGED=1
    _ok "$_MON_COUNT monitor(s) — Q3IDE_MAX_MONITORS updated (rebuild required)"
else
    _ok "$_MON_COUNT monitor(s) — no change needed"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 3 — Monitor Layout
# ═════════════════════════════════════════════════════════════════════════════
_step 3 "Monitor Layout"

_DEFAULT_ORDER=$(seq 0 $(( _MON_COUNT - 1 )) | tr '\n' ' ' | sed 's/ $//')
_LAYOUT_TYPE="h"
_LAYOUT_ORDER="$_DEFAULT_ORDER"

if [ "$_MON_COUNT" -eq 1 ]; then
    _ok "Single monitor — nothing to configure"
else
    _dim "Display positions are detected automatically from physical x coordinates at runtime."
    _blank
    if [ "$_MON_COUNT" -le 2 ]; then
        _info "  h  — horizontal  (default)"
        _info "  v  — vertical"
    else
        _SQRT=$(python3 -c "import math; print(int(math.ceil(math.sqrt(int('$_MON_COUNT')))))")
        _info "  h  — horizontal, single row      (default)"
        _info "  v  — vertical, single column"
        _info "  c  — custom grid ${_SQRT}×${_SQRT}  (enter display order)"
    fi
    _ask "Layout [h]:"
    read -r _LAYOUT_INPUT
    _LAYOUT_INPUT="${_LAYOUT_INPUT:-h}"

    case "$_LAYOUT_INPUT" in
        v|vertical)
            _LAYOUT_TYPE="v" ;;
        c|custom|grid)
            _LAYOUT_TYPE="c"
            _blank
            _dim "Enter display indices space-separated. Use '-' for empty slot."
            _dim "Example — 7 monitors in 3×3: 0 1 2 3 4 5 6"
            _ask "Order [${_DEFAULT_ORDER}]:"
            read -r _CUSTOM
            _LAYOUT_ORDER="${_CUSTOM:-$_DEFAULT_ORDER}" ;;
        *)
            _LAYOUT_TYPE="h" ;;
    esac

    # Visual matrix
    _blank
    python3 - "$_LAYOUT_ORDER" "$_LAYOUT_TYPE" "$_MON_COUNT" <<'PYEOF'
import sys, math
raw, layout, n = sys.argv[1].split(), sys.argv[2], int(sys.argv[3])
MAX = 8
order = [x if x != '-' else None for x in raw]
while len(order) < n:
    order.append(str(len(order)))

if layout == 'h':
    rows, extra = [order[:min(n, MAX)]], max(0, n - MAX)
elif layout == 'v':
    show = min(n, MAX)
    rows, extra = [[order[i]] for i in range(show)], max(0, n - show)
else:
    g = math.ceil(math.sqrt(n))
    all_rows = [[order[r*g+c] if r*g+c < len(order) else None for c in range(g)] for r in range(g)]
    shown, rows = 0, []
    for row in all_rows:
        rc = sum(1 for x in row if x is not None)
        if shown + rc > MAX and shown > 0: break
        rows.append(row); shown += rc
    extra = max(0, n - sum(1 for r in rows for x in r if x is not None))

ct = lambda v: '┌─────┐' if v is not None else '┌·····┐'
cm = lambda v: ('│' + f'[{v}]'.center(5) + '│') if v is not None else '│  ─  │'
cb = lambda v: '└─────┘' if v is not None else '└·····┘'
sep = '  '
for row in rows:
    print('  ' + sep.join(ct(v) for v in row))
    print('  ' + sep.join(cm(v) for v in row))
    print('  ' + sep.join(cb(v) for v in row))
if extra > 0:
    print(f'         ···  +{extra} more monitor{"s" if extra != 1 else ""}')
PYEOF
    _blank

    # Display order is auto-detected at runtime from physical x coordinates — no compile-time constants needed.

    _ok "$( [ "$_LAYOUT_TYPE" = "h" ] && echo "Horizontal" || [ "$_LAYOUT_TYPE" = "v" ] && echo "Vertical" || echo "Custom grid" ) — [${_LAYOUT_ORDER}]"
fi

# Save layout config
cat > "$SETUP_CFG" <<CFGEOF
// q3ide_setup.cfg — generated by build.sh --setup
set q3ide_setup_monitors  "$_MON_COUNT"
set q3ide_setup_layout    "$_LAYOUT_ORDER"
CFGEOF
if [ -f "$AUTOEXEC" ] && ! grep -q "q3ide_setup.cfg" "$AUTOEXEC"; then
    printf '\nexec q3ide_setup.cfg\n' >> "$AUTOEXEC"
fi

# ═════════════════════════════════════════════════════════════════════════════
# STEP 4 — Renderer
# ═════════════════════════════════════════════════════════════════════════════
_step 4 "Renderer"

_GPU="$_PRE_GPU"
case "$_GPU" in
    *AMD*|*Radeon*|*NVIDIA*|*GeForce*) _REC="vulkan"  ;;
    *) _REC="opengl1" ;;
esac

_dim "GPU: $_GPU"
_blank

# Show options — highlight recommended
for _opt in opengl1 opengl2 vulkan; do
    case "$_opt" in
        opengl1) _desc="Classic OpenGL. Safe, compatible. No bloom/HDR." ;;
        opengl2) _desc="OpenGL 2. Cascaded shadow maps. Slower." ;;
        vulkan)  _desc="Vulkan. Bloom, HDR, stencil shadows." ;;
    esac
    if [ "$_opt" = "$_REC" ]; then
        printf "  ${_G}★ %-10s${_R0}— %s  ${_G}← Recommended${_R0}\n" "$_opt" "$_desc"
    else
        printf "    ${_DIM}%-10s${_R0}— %s\n" "$_opt" "$_desc"
    fi
done

_ask "Renderer [${_REC}]:"
read -r _REND_INPUT
_REND="${_REND_INPUT:-$_REC}"
case "$_REND" in
    opengl1|opengl2|vulkan) ;;
    *) _warn "Unknown — using $_REC"; _REND="$_REC" ;;
esac

printf 'set q3ide_setup_renderer  "%s"\n' "$_REND" >> "$SETUP_CFG"
_ok "Renderer: $_REND"

# ═════════════════════════════════════════════════════════════════════════════
# Done — Summary
# ═════════════════════════════════════════════════════════════════════════════
_blank
printf '  ╔═══════════════════════════════════════════╗\n'
printf '  ║           Setup Complete                  ║\n'
printf '  ╠═══════════════════════════════════════════╣\n'
printf '  ║  %-12s  %-28s║\n' "CiNEmatic"  "$_SUMMARY_CIN"
printf '  ║  %-12s  %-28s║\n' "Monitors"   "$_MON_COUNT"
printf '  ║  %-12s  %-28s║\n' "Layout"     "$_LAYOUT_ORDER"
printf '  ║  %-12s  %-28s║\n' "Renderer"   "$_REND"
printf '  ╚═══════════════════════════════════════════╝\n'
_blank

if [ "$PARAMS_CHANGED" -eq 1 ]; then
    printf "  ${_Y}⚠  params.h changed — --clean required${_R0}\n"
    _blank
    printf "  ${_B}→  ./scripts/build.sh --clean --run --level 0${_R0}\n"
else
    printf "  ${_B}→  ./scripts/build.sh --run --level 0${_R0}\n"
fi
_blank

Q3IDE_SETUP_RENDERER="$_REND"
Q3IDE_SETUP_PARAMS_CHANGED="$PARAMS_CHANGED"
export Q3IDE_SETUP_RENDERER Q3IDE_SETUP_PARAMS_CHANGED
