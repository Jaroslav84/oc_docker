#!/bin/bash
# Show the latest from all Q3IDE log files.
# Usage: ./scripts/check_logs.sh [--follow|-f] [--errors|-e]

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
LOG_DIR="$ROOT/logs"
BUILD_DIR="$ROOT/quake3e/build"

# Collect all log files
LOGS=()
[ -f "$LOG_DIR/build.log" ]   && LOGS+=("$LOG_DIR/build.log")
[ -f "$LOG_DIR/engine.log" ]  && LOGS+=("$LOG_DIR/engine.log")

# Capture dylib logs (in build dirs)
for f in "$BUILD_DIR"/*/logs/q3ide_capture.log; do
    [ -f "$f" ] && LOGS+=("$f")
done

# Quake3e console log
for f in "$BUILD_DIR"/*/baseq3/qconsole.log; do
    [ -f "$f" ] && LOGS+=("$f")
done

if [ ${#LOGS[@]} -eq 0 ]; then
    echo "No log files found. Run build.sh first."
    exit 1
fi

MODE="tail"
FILTER=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--follow) MODE="follow"; shift ;;
        -e|--errors) FILTER="error|ERROR|WARN|warning|MISMATCH|FAIL|panic"; shift ;;
        *) shift ;;
    esac
done

for log in "${LOGS[@]}"; do
    echo ""
    echo "═══ $(basename "$log") ═══  ($log)"
    echo "───────────────────────────────────────"
    if [ -n "$FILTER" ]; then
        grep -iE "$FILTER" "$log" | tail -20
    else
        tail -20 "$log"
    fi
done

if [ "$MODE" = "follow" ]; then
    echo ""
    echo "═══ Following all logs (Ctrl-C to stop) ═══"
    tail -f "${LOGS[@]}"
fi
