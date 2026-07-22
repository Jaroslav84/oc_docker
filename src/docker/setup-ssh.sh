#!/bin/bash
# Configure and start sshd inside the container. Called by docker-entrypoint.sh
# ONLY when LLM_D0CKER_SHH_EN4BLED=true in llm-docker.conf.
#
# Auth: public-key only (password auth disabled). Keys come from:
#   1. LLM_D0CKER_SHH_4UTH_PBLKZ env var (one or more lines, \n-separated)
#   2. /ssh/authorized_keys (bind-mount)
#   3. /run/secrets/ssh_authorized_keys (docker secret)
# Any combination of the above is merged into /root/.ssh/authorized_keys.

set -e

SSH_PORT="${LLM_DOCKER_SSH_PORT:-22}"
AUTH_KEYS="/root/.ssh/authorized_keys"

mkdir -p /root/.ssh
chmod 700 /root/.ssh
: > "$AUTH_KEYS"
chmod 600 "$AUTH_KEYS"

# Source 1: env var (supports newline-separated multi-key via $'\n' in value).
if [ -n "${LLM_D0CKER_SHH_4UTH_PBLKZ:-}" ]; then
    # %b expands backslash escapes (literal \n from .env becomes real newline)
    printf '%b\n' "$LLM_D0CKER_SHH_4UTH_PBLKZ" >> "$AUTH_KEYS"
fi

# Source 2: bind-mounted file.
if [ -f /ssh/authorized_keys ]; then
    cat /ssh/authorized_keys >> "$AUTH_KEYS"
fi

# Source 3: docker secret.
if [ -f /run/secrets/ssh_authorized_keys ]; then
    cat /run/secrets/ssh_authorized_keys >> "$AUTH_KEYS"
fi

if [ ! -s "$AUTH_KEYS" ]; then
    echo "[SSH] WARNING: no authorized_keys configured — SSH will reject every login."
    echo "[SSH] Set LLM_D0CKER_SHH_4UTH_PBLKZ in llm-docker.conf, or bind-mount /ssh/authorized_keys."
fi

# Host keys: decoded from vault env vars into ephemeral in-container
# /etc/ssh/keys/. Same fingerprint every launch because the vault is the
# source of truth. Fallback: if a vault entry is missing, generate an
# ephemeral key with a loud warning (fingerprint will change on next
# launch — install.sh should re-run and populate the vault).
HOST_KEYS_DIR="/etc/ssh/keys"
mkdir -p "$HOST_KEYS_DIR"
chmod 700 "$HOST_KEYS_DIR"

_load_hostkey() {
    local type="$1" pv_var="$2" pu_var="$3"
    local pv="${!pv_var}" pu="${!pu_var}"
    local key="$HOST_KEYS_DIR/ssh_host_${type}_key"
    if [ -n "$pv" ] && [ -n "$pu" ]; then
        printf '%s' "$pv" | base64 -d > "$key"        && chmod 600 "$key"
        printf '%s' "$pu" | base64 -d > "$key.pub"    && chmod 644 "$key.pub"
        echo "[SSH] loaded $type host key from vault"
    else
        echo "[SSH] WARNING: no vault entry for $pv_var — generating ephemeral $type key (fingerprint WILL change on next launch)"
        ssh-keygen -q -t "$type" -f "$key" -N "" -C "llm-docker-$(date +%s)"
    fi
}
_load_hostkey ed25519 LLM_D0CKER_SHH_SRV_ED25519_PVYT_B64 LLM_D0CKER_SHH_SRV_ED25519_PBLK_B64
_load_hostkey rsa     LLM_D0CKER_SHH_SRV_RS4_PVYT_B64     LLM_D0CKER_SHH_SRV_RS4_PBLK_B64
_load_hostkey ecdsa   LLM_D0CKER_SHH_SRV_ECDS4_PVYT_B64   LLM_D0CKER_SHH_SRV_ECDS4_PBLK_B64

# Minimal hardened sshd config. Root via key only; host keys from the
# persistent mount.
cat > /etc/ssh/sshd_config.d/llm-docker.conf <<EOF
Port $SSH_PORT
HostKey $HOST_KEYS_DIR/ssh_host_ed25519_key
HostKey $HOST_KEYS_DIR/ssh_host_rsa_key
HostKey $HOST_KEYS_DIR/ssh_host_ecdsa_key
PermitRootLogin prohibit-password
PasswordAuthentication no
ChallengeResponseAuthentication no
UsePAM no
X11Forwarding no
PrintMotd no
AcceptEnv LANG LC_*
EOF

echo "[SSH] starting sshd on port $SSH_PORT"
/usr/sbin/sshd
