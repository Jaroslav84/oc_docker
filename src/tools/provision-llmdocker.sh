#!/usr/bin/env bash
# provision-llmdocker.sh — set up the `llmdocker` user on a remote server.
#
# Runs on the REMOTE server. Two invocation shapes:
#
#   From llm-docker's installer (bash-piped, pubkey on stdin):
#     printf '%s\n' "$PUBKEY" | ssh admin@host bash -s -- --pubkey-stdin < provision-llmdocker.sh
#
#   Standalone (curl-piped by the user later):
#     curl -fsSL <RAW_URL>/src/tools/provision-llmdocker.sh | ssh admin@host \
#         bash -s -- --pubkey 'ssh-ed25519 AAAA... llmdocker@my-mac'
#
# What it does on the remote server:
#   1. Creates user `llmdocker` (home /home/llmdocker, shell bash) if missing.
#   2. Installs the caller-provided pubkey into ~llmdocker/.ssh/authorized_keys.
#   3. Drops /etc/sudoers.d/llmdocker with FULL NOPASSWD sudo plus a small
#      block-list against typo mistakes that would take out root itself
#      (deleting root, changing root's password, `su`-ing to root as a shell,
#      `rm /root`). This is a SPEED-BUMP against fat-finger mistakes, NOT a
#      security boundary — llmdocker effectively IS root. Only run this on
#      servers YOU FULLY CONTROL.
#   4. `visudo -c` verifies the sudoers snippet before commit.
#
# Supports Debian/Ubuntu, RHEL/Rocky/Alma, Alpine. Idempotent — safe to re-run.
#
# Exit codes:
#   0  success
#   1  argument error (no pubkey provided)
#   2  distro not supported
#   3  useradd failed
#   4  sudoers validation failed

set -euo pipefail

# ─── Parse args ──────────────────────────────────────────────────────────────
PUBKEY=""
PUBKEY_FROM_STDIN=false
while [ $# -gt 0 ]; do
    case "$1" in
        --pubkey)         PUBKEY="$2"; shift 2 ;;
        --pubkey-stdin)   PUBKEY_FROM_STDIN=true; shift ;;
        -h|--help)
            sed -n '1,32p' "$0" | sed 's/^# \{0,1\}//'
            exit 0 ;;
        *) echo "unknown arg: $1" >&2; exit 1 ;;
    esac
done

if [ "$PUBKEY_FROM_STDIN" = true ]; then
    PUBKEY="$(cat)"
fi

if [ -z "$PUBKEY" ]; then
    echo "[provision] ERROR: no pubkey supplied (use --pubkey '<key>' or --pubkey-stdin)" >&2
    exit 1
fi

# Sanity — pubkey looks like an ssh public key line.
case "$PUBKEY" in
    ssh-ed25519\ *|ssh-rsa\ *|ecdsa-sha2-*\ *|sk-ssh-ed25519@openssh.com\ *) ;;
    *) echo "[provision] ERROR: pubkey doesn't look like an ssh public key" >&2; exit 1 ;;
esac

# ─── Detect distro ───────────────────────────────────────────────────────────
DISTRO_ID=""
if [ -r /etc/os-release ]; then
    . /etc/os-release
    DISTRO_ID="${ID:-unknown}"
fi

case "$DISTRO_ID" in
    debian|ubuntu|raspbian|linuxmint|pop|kali)     FAMILY=debian ;;
    rhel|centos|rocky|almalinux|fedora|amzn)       FAMILY=redhat ;;
    alpine)                                        FAMILY=alpine ;;
    *) echo "[provision] ERROR: unsupported distro (ID=$DISTRO_ID). Edit provision-llmdocker.sh." >&2; exit 2 ;;
esac

echo "[provision] distro family: $FAMILY (ID=$DISTRO_ID)"

# ─── Root check ──────────────────────────────────────────────────────────────
if [ "$(id -u)" -ne 0 ]; then
    echo "[provision] ERROR: must run as root (via sudo or root ssh login)" >&2
    exit 1
fi

# Audit trail — one line per invocation, tagged so it's grep-able in syslog.
logger -t llmdocker-provision -p daemon.info \
    "provision starting by user=${SUDO_USER:-$(id -un)} ssh_client=${SSH_CLIENT:-local}" \
    2>/dev/null || true

# ─── 1. Create llmdocker user ────────────────────────────────────────────────
if id -u llmdocker >/dev/null 2>&1; then
    echo "[provision] user 'llmdocker' already exists — reusing"
else
    case "$FAMILY" in
        debian|redhat)
            useradd --create-home --shell /bin/bash --user-group llmdocker \
                || { echo "[provision] useradd failed" >&2; exit 3; }
            ;;
        alpine)
            adduser -D -s /bin/bash -h /home/llmdocker llmdocker \
                || { echo "[provision] adduser failed" >&2; exit 3; }
            ;;
    esac
    echo "[provision] created user llmdocker"
fi

HOME_DIR="$(getent passwd llmdocker | awk -F: '{print $6}')"
SSH_DIR="$HOME_DIR/.ssh"
AUTH_KEYS="$SSH_DIR/authorized_keys"

install -d -m 700 -o llmdocker -g llmdocker "$SSH_DIR"
touch "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"
chown llmdocker:llmdocker "$AUTH_KEYS"

# ─── 2. Install pubkey (idempotent) ──────────────────────────────────────────
if grep -qF -- "$PUBKEY" "$AUTH_KEYS" 2>/dev/null; then
    echo "[provision] pubkey already present in $AUTH_KEYS"
else
    printf '%s\n' "$PUBKEY" >> "$AUTH_KEYS"
    echo "[provision] added pubkey to $AUTH_KEYS"
fi

# ─── 3. Sudoers: full NOPASSWD + typo-guard block-list ─────────────────────
# Full sudo (llmdocker effectively IS root) with a small block-list against
# typo mistakes that would take out root itself. Speed-bump, NOT a boundary.
SUDOERS_FILE="/etc/sudoers.d/llmdocker"
SUDOERS_TMP="$(mktemp)"

cat > "$SUDOERS_TMP" <<'SUDO'
# llmdocker — llm-docker's remote user
# ─────────────────────────────────────
# Full NOPASSWD sudo (llmdocker effectively IS root) with a small typo-guard
# block-list against fat-fingers that would take out root itself. Denials
# cover: deleting root, changing root's password, modifying root's login
# shell/home/groups, su-ing to root as a shell, and rm'ing /root. NOT a
# security boundary — only run this on servers YOU FULLY CONTROL.
Defaults env_keep+="DEBIAN_FRONTEND"

# Explicit denials (see manual to understand `!` semantics in sudoers).
Cmnd_Alias LLMD_DENY = \
    /usr/sbin/userdel root, /sbin/userdel root, \
    /usr/sbin/deluser root, /sbin/deluser root, \
    /usr/bin/passwd root, /usr/bin/passwd -l root, /usr/bin/passwd -d root, \
    /usr/bin/chage * root, \
    /usr/sbin/usermod * root, /sbin/usermod * root, \
    /usr/bin/su, /usr/bin/su -, /usr/bin/su root, /usr/bin/su - root, /bin/su, /bin/su -, /bin/su root, /bin/su - root, \
    /bin/rm -rf /root, /bin/rm -r /root, /bin/rm /root, \
    /usr/bin/rm -rf /root, /usr/bin/rm -r /root, /usr/bin/rm /root, \
    /bin/rm -rf /root/*, /usr/bin/rm -rf /root/*

llmdocker ALL=(ALL) NOPASSWD: ALL, !LLMD_DENY
SUDO

# Validate before installing. visudo -c -f exits non-zero on any syntax error.
if ! visudo -c -f "$SUDOERS_TMP" >/dev/null; then
    echo "[provision] ERROR: sudoers snippet failed visudo -c" >&2
    cat "$SUDOERS_TMP" >&2
    /bin/rm -f "$SUDOERS_TMP"
    exit 4
fi

install -m 440 -o root -g root "$SUDOERS_TMP" "$SUDOERS_FILE"
/bin/rm -f "$SUDOERS_TMP"

echo "[provision] wrote $SUDOERS_FILE — full NOPASSWD sudo, denials for root deletion/takeover only"

# ─── 4. Canary tests (verify the typo-guards actually deny) ─────────────────
# `sudo -l -U USER CMD` asks "would USER be allowed CMD?" without running it.
# Exit 0 = ALLOWED, non-zero = DENIED. For canaries we WANT non-zero.
# Some minimal sudo builds (busybox) don't support `-l -U`; skip cleanly there.
if ! sudo -l -U root true >/dev/null 2>&1; then
    echo "[provision] canaries skipped — this sudo doesn't support -l -U"
    _final_canary="skipped"
else
    _canary_pass=true
    _run_canary() {
        local _desc="$1"; shift
        if sudo -l -U llmdocker "$@" >/dev/null 2>&1; then
            echo "[provision] WARN: canary '$_desc' should be DENIED but was ALLOWED — block-list not enforcing"
            _canary_pass=false
        else
            echo "[provision] canary: '$_desc' denied ✓"
        fi
    }
    _run_canary "rm -r /root"   /bin/rm -r /root
    _run_canary "passwd root"   /usr/bin/passwd root
    _run_canary "su -"          /bin/su -
    if [ "$_canary_pass" = true ]; then
        echo "[provision] all canaries passed — typo-guard block-list is enforcing"
    else
        echo "[provision] WARN: one or more canaries FAILED — inspect $SUDOERS_FILE" >&2
    fi
    _final_canary="$_canary_pass"
    unset -f _run_canary
    unset _canary_pass
fi

# ─── 5. Done ─────────────────────────────────────────────────────────────────
_HOSTNAME="$(hostname 2>/dev/null || echo unknown)"
logger -t llmdocker-provision -p daemon.info \
    "provision complete on ${_HOSTNAME}; canaries_passed=${_final_canary:-unknown}" \
    2>/dev/null || true
unset _final_canary
echo "[provision] llmdocker set up on ${_HOSTNAME} — $(id llmdocker)"
echo "[provision] Test: ssh llmdocker@${_HOSTNAME}"
