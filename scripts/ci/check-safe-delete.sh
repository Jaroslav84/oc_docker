#!/bin/bash
# check-safe-delete.sh — unit tests for src/setup/safe_delete.sh.
# Isolates PATH to a stub bin dir, sources the helper, calls it against
# fixtures, asserts exit codes + stderr behavior.
set -u

_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_TMP="$(mktemp -d)"
trap '/bin/rm -rf "$_TMP"' EXIT

_fail=0
_pass=0
_check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass=$((_pass + 1))
        printf '  ✓ %s\n' "$desc"
    else
        _fail=$((_fail + 1))
        printf '  ✗ %s (expected %s, got %s)\n' "$desc" "$expected" "$actual" >&2
    fi
}

# shellcheck source=/dev/null
. "$_ROOT/src/setup/safe_delete.sh"

echo "── 1. real trash present → succeeds ──"
_STUB="$_TMP/stub"
mkdir -p "$_STUB"
cat > "$_STUB/trash" <<'EOF'
#!/bin/bash
exit 0
EOF
chmod +x "$_STUB/trash"
touch "$_TMP/f1"
PATH="$_STUB:/usr/bin:/bin" safe_delete "$_TMP/f1" >/dev/null 2>&1
_check "trash present → rc=0" "0" "$?"

echo "── 2. no trash tool → warns + rc=1 ──"
mkdir -p "$_TMP/empty"
_STDERR="$_TMP/stderr"
PATH="$_TMP/empty" safe_delete "$_TMP/f1" 2>"$_STDERR" >/dev/null
_rc=$?
_check "no trash → rc=1" "1" "$_rc"
if grep -q "no trash tool found" "$_STDERR"; then
    _check "warns on stderr" "yes" "yes"
else
    _check "warns on stderr" "yes" "no"
fi

echo "── 3. multi-path, all succeed → rc=0 ──"
touch "$_TMP/a" "$_TMP/b" "$_TMP/c"
PATH="$_STUB:/usr/bin:/bin" safe_delete "$_TMP/a" "$_TMP/b" "$_TMP/c" >/dev/null 2>&1
_check "multi-path all-ok → rc=0" "0" "$?"

echo "── 4. multi-path, one fails → rc=1 ──"
cat > "$_STUB/trash" <<'EOF'
#!/bin/bash
# Fails on any path containing "fail-me"
case "$*" in *fail-me*) exit 1 ;; *) exit 0 ;; esac
EOF
chmod +x "$_STUB/trash"
touch "$_TMP/ok1" "$_TMP/fail-me" "$_TMP/ok2"
PATH="$_STUB:/usr/bin:/bin" safe_delete "$_TMP/ok1" "$_TMP/fail-me" "$_TMP/ok2" >/dev/null 2>&1
_check "multi-path one-fail → rc=1" "1" "$?"

echo
if [ "$_fail" -gt 0 ]; then
    printf '── check-safe-delete: %d passed, %d FAILED\n' "$_pass" "$_fail" >&2
    exit 1
fi
printf '── check-safe-delete: %d passed ✓\n' "$_pass"
exit 0
