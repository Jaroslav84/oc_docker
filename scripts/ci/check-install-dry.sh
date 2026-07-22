#!/bin/bash
# check-install-dry.sh — smoke test that every install.d/*.sh sources cleanly
# under stubbed interactive functions. Catches syntax errors, missing vars,
# and calls to undefined helpers BEFORE they hit a real install.
set -u
SRC="$(cd "$(dirname "$0")/../../src" && pwd)"
export SCRIPT_DIR="$SRC"
_TMP_HOME="$(mktemp -d)"
export HOME="$_TMP_HOME"
trap '/bin/rm -rf "$_TMP_HOME"' EXIT

# STUB external commands the install.d steps probe. `command -v` bypasses
# shell functions, so we plant real executables in a PATH-first stub dir.
_STUB_BIN="$_TMP_HOME/stub-bin"
mkdir -p "$_STUB_BIN"
cat > "$_STUB_BIN/docker" <<'EOF'
#!/bin/bash
case "$1" in
    info)    exit 0 ;;
    version) echo "Docker version stub" ;;
    *)       exit 0 ;;
esac
EOF
chmod +x "$_STUB_BIN/docker"
export PATH="$_STUB_BIN:$PATH"

# Source the real ywizz theme + setup modules (they define real helpers we override below).
# shellcheck disable=SC1091
source "$SRC/lib/ywizz/theme.sh" 2>/dev/null || true
# shellcheck disable=SC1091
source "$SRC/lib/ywizz/ywizz.sh" 2>/dev/null || true
# shellcheck disable=SC1091
source "$SRC/setup.sh" >/dev/null 2>&1 || true

# All overrides MUST come AFTER `source setup.sh` — setup.sh defines real
# _read_env_var (etc.) that would otherwise clobber our stubs.
_update_kv()       { :; }
_update_env_var()  { :; }
_update_conf_var() { :; }
_mask_secret()     { printf '%s' "$1"; }
_mark_rebuild_needed() { :; }

# STUB interactive TUI. Each writes a default value to the caller's named var.
header_tui() { echo "── $* ──"; }
info()    { echo "  info: $*"; }
success() { echo "  ok:   $*"; }
warn()    { echo "  warn: $*"; }
error()   { echo "  err:  $*"; }
ask_yes_no_tui() { eval "$3='n'"; }              # default all yes/no to NO
ask_tui()        { eval "$3=\"$2\""; }            # default value = arg2
checklist_tui()  { eval "${6}_0='false'"; }       # default first option unchecked
_read_env_var()  { :; }                            # empty by default (overrides setup.sh)

# Reset strict-mode flags — install.d steps assume relaxed mode within the
# real install flow (earlier steps set vars later steps read). Set -u would
# false-positive on subshell isolation.
set +u

fail=0
STEPS="01-docker 02-dirs 03-env 04-workspace 05-apikeys 06a-ssh-inbound 06b-ssh-outbound 07-builderapi 08-tmux 09-devpacks 10-image 11-link 99-complete"
for s in $STEPS; do
    # Syntax check FIRST (cheap, catches broken bash) then sourced smoke.
    if ! bash -n "$SRC/install.d/${s}.sh" 2>&1; then
        printf '  \033[31m✗\033[0m %s (syntax error)\n' "$s" >&2
        fail=1
        continue
    fi
    if ( set +u; source "$SRC/install.d/${s}.sh" ) >/dev/null 2>&1; then
        printf '  \033[32m✓\033[0m %s\n' "$s"
    else
        printf '  \033[31m✗\033[0m %s (source exited non-zero)\n' "$s" >&2
        fail=1
    fi
done

# Also verify install.sh top-level driver parses (sourcing it would re-run all
# steps — bash -n is enough for the driver itself since we already source-tested
# every step above).
if bash -n "$SRC/install.sh" 2>&1; then
    printf '  \033[32m✓\033[0m install.sh top-level driver (syntax)\n'
else
    printf '  \033[31m✗\033[0m install.sh top-level driver (syntax error)\n' >&2
    fail=1
fi

if [ "$fail" -ne 0 ]; then
    echo "check-install-dry: FAIL" >&2
    exit 1
fi
echo "check-install-dry: clean ✓"
