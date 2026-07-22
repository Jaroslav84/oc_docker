#!/bin/bash
# check-py-tests.sh — pytest smoke over builder-api unit tests. Skipped
# gracefully if pytest isn't installed (CI machines that only want the
# fast import smoke can skip this file).
set -u
if ! command -v pytest >/dev/null 2>&1; then
    echo "check-py-tests: pytest not installed — skipping (install with: pip install pytest)"
    exit 0
fi
SRC="$(cd "$(dirname "$0")/../../src" && pwd)"
cd "$SRC/builder-api" && pytest tests/ -q --tb=short
