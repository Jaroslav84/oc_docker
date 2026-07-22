#!/bin/bash
# check-launcher-softskip.sh — unit tests for launcher's builder-api soft-skip
# path. Isolates HOME to a temp dir, plants fake api_config shards, sources
# launcher.sh with just enough stubs, and asserts _project_shard_lookup +
# _maybe_start_api behave for: missing dir, missing block, bare block header,
# quoted block header, and port extraction.
#
# Runs under macOS bash 3.2 + GNU bash. Exit 0 on green, 1 on any failure.
set -u

_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
_ORIG_HOME="$HOME"
_TMP="$(mktemp -d)"
trap 'HOME="$_ORIG_HOME"; /bin/rm -rf "$_TMP"' EXIT
export HOME="$_TMP"

_fail=0
_pass=0
_check() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then
        _pass=$((_pass + 1))
        printf '  ✓ %s\n' "$desc"
    else
        _fail=$((_fail + 1))
        printf '  ✗ %s\n    expected: %s\n    actual:   %s\n' "$desc" "$expected" "$actual"
    fi
}

# Stub out the deps launcher.sh expects at source time.
_log() { echo "LOG:$*"; }
_read_env_var() { :; }
SCRIPT_DIR="$_ROOT/src"
START_API=true

# shellcheck source=/dev/null
. "$_ROOT/src/setup/launcher.sh"

echo "── 1. no api_config dir at all ──"
_out="$(_maybe_start_api CLD /some/project/foo 2>&1)"
case "$_out" in
    *WARNING*doesn\'t\ exist*) _check "no-dir → WARNING" "yes" "yes" ;;
    *) _check "no-dir → WARNING" "yes" "no ($_out)" ;;
esac

echo "── 2. dir exists, no matching block ──"
mkdir -p "$HOME/.llm-docker/api_config"
cat > "$HOME/.llm-docker/api_config/builder-api.toml" <<'EOF'
[project.otherproj]
port = 6800
root = "/tmp"
EOF
_out="$(_maybe_start_api CLD /some/project/foo 2>&1)"
case "$_out" in
    *WARNING*no\ \[project.foo\]*) _check "no-block → WARNING with hint" "yes" "yes" ;;
    *) _check "no-block → WARNING with hint" "yes" "no ($_out)" ;;
esac

echo "── 3. bare block header ──"
cat >> "$HOME/.llm-docker/api_config/builder-api.toml" <<'EOF'

[project.foo]
port = 6900
root = "/tmp"
EOF
_out="$(_project_shard_lookup foo --exists)"
_check "bare block --exists" "yes" "$_out"
_out="$(_project_shard_lookup foo port)"
_check "bare block port" "6900" "$_out"

echo "── 4. quoted block header ──"
cat > "$HOME/.llm-docker/api_config/quoted-name.toml" <<'EOF'
[project."quoted-name"]
port = 7100
root = "/tmp"
EOF
_out="$(_project_shard_lookup quoted-name --exists)"
_check "quoted block --exists" "yes" "$_out"
_out="$(_project_shard_lookup quoted-name port)"
_check "quoted block port" "7100" "$_out"

echo "── 5. dotted name in quoted block ──"
cat > "$HOME/.llm-docker/api_config/my.dotted.name.toml" <<'EOF'
[project."my.dotted.name"]
port = 7200
root = "/tmp"
EOF
_out="$(_project_shard_lookup my.dotted.name --exists)"
_check "dotted name --exists" "yes" "$_out"
_out="$(_project_shard_lookup my.dotted.name port)"
_check "dotted name port" "7200" "$_out"

echo "── 6. substring collision (foo vs foobar) ──"
cat > "$HOME/.llm-docker/api_config/foobar.toml" <<'EOF'
[project.foobar]
port = 7300
root = "/tmp"
EOF
# Look up "foo" — should NOT match [project.foobar]. But `foo` also has
# an earlier match in builder-api.toml (from test 3), so this returns 6900.
# The real check: `foobar` returns 7300, not 6900. And `foo` isn't cross-
# contaminated by the foobar block.
_out="$(_project_shard_lookup foobar port)"
_check "foobar port (isolated)" "7300" "$_out"

echo "── 7. missing project → exit 1 ──"
if _project_shard_lookup nonexistent --exists >/dev/null 2>&1; then
    _check "missing project returns non-zero" "yes" "no (returned 0)"
else
    _check "missing project returns non-zero" "yes" "yes"
fi

echo
if [ "$_fail" -gt 0 ]; then
    printf '── check-launcher-softskip: %d passed, %d FAILED\n' "$_pass" "$_fail"
    exit 1
fi
printf '── check-launcher-softskip: %d passed ✓\n' "$_pass"
exit 0
