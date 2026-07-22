# ── 6b. SSH outbound (container → your servers) ─────────────────────────────
header_tui "6b/12  SSH outbound (optional)"
info "Lets ${secondary_accent}ssh <hostname>${RESET} from inside the container reach your remote servers."
info "Uses an in-container ssh-agent — private keys live in memory, never on disk."

# Vault-mode awareness (llm-docker.conf: IS_S3C_GORILLA_ENABLED). In vault
# mode the config file lives as an ATTACHMENT (SSH/llm-docker-ssh-config/config)
# and env-gorilla drops it at $S3C_ATTACHMENT_DIR/config. In .env mode it's
# base64 in LLM_D0CKER_SHH_CFG_B64.
# 03-env.sh already set GORILLA_ENABLED in this shell — no need to re-read the file.
_OUT_IS_VAULT="${GORILLA_ENABLED:-false}"

ask_yes_no_tui "Enable outbound SSH?" "n" OUT_CHOICE 1 0

if [[ ! "$OUT_CHOICE" =~ ^[Yy] ]]; then
    success "Outbound SSH skipped — you can re-run install.sh later to add it"
    unset _OUT_IS_VAULT
    return 0 2>/dev/null || :
fi

# Vault mode short-circuit — env-gorilla has no `get` subcommand, so we can't
# probe the vault at install time. Assume the vault has the outbound key and
# skip regen. Override with FORCE_REGEN=1.
if [ "$_OUT_IS_VAULT" = "true" ] && [ "${FORCE_REGEN:-0}" != "1" ]; then
    info "Vault mode — assuming your vault has ${secondary_accent}LLMD0CKER_SHH_3D25519_PVYT_B64${RESET}. Skipping regen (set FORCE_REGEN=1 to regen anyway)."
    success "Outbound SSH: using vault-stored key."
    unset _OUT_IS_VAULT
    return 0 2>/dev/null || :
fi

# ─── 6b.1. Generate the llmdocker outbound key ─────────────────────────────
_HAS_OUT_KEY="$(_read_env_var LLMD0CKER_SHH_3D25519_PVYT_B64 "$SCRIPT_DIR/.env")"
NEW_LLMD_PUB=""

if [ -n "$_HAS_OUT_KEY" ]; then
    info "An llmdocker outbound key is already saved in .env. Skipping generation."
    # Re-derive pub for the provisioner step if the user wants to run it.
    _tmp_pub="$(mktemp)"
    printf '%s' "$_HAS_OUT_KEY" | base64 -d > "${_tmp_pub}.priv" 2>/dev/null
    ssh-keygen -y -f "${_tmp_pub}.priv" > "$_tmp_pub" 2>/dev/null && NEW_LLMD_PUB="$(cat "$_tmp_pub")"
    safe_delete "${_tmp_pub}.priv" "$_tmp_pub" 2>/dev/null || :
else
    ask_yes_no_tui "Generate a fresh llmdocker outbound key now?" "y" GEN_OUT 0 1
    if [[ "$GEN_OUT" =~ ^[Yy] ]]; then
        _out_tmp="$(mktemp -d)"
        ssh-keygen -q -t ed25519 -N '' -C "llmdocker@$(hostname -s 2>/dev/null || echo llm-docker)" \
                   -f "$_out_tmp/llmdocker_ed25519" 2>/dev/null
        NEW_LLMD_PUB="$(cat "$_out_tmp/llmdocker_ed25519.pub")"
        _LLMD_PRIV_B64="$(base64 < "$_out_tmp/llmdocker_ed25519" 2>/dev/null | tr -d '\n')"
        _LLMD_PUB_B64="$(base64 < "$_out_tmp/llmdocker_ed25519.pub" 2>/dev/null | tr -d '\n')"
        # Trash key material immediately — only the base64 in .env survives.
        safe_delete "$_out_tmp" || true
        unset _out_tmp

        _update_env_var LLMD0CKER_SHH_3D25519_PVYT_B64 "$_LLMD_PRIV_B64"
        _update_env_var LLMD0CKER_SHH_3D25519_PBLK_B64 "$_LLMD_PUB_B64"
        unset _LLMD_PRIV_B64 _LLMD_PUB_B64

        success "Generated llmdocker_ed25519 — saved to .env as base64."
        info "Public key (add to your servers' ~/.ssh/authorized_keys for user ${secondary_accent}llmdocker${RESET}):"
        printf "  ${C2}%s${RESET}\n" "$NEW_LLMD_PUB"
    fi
fi

# ─── 6b.2. Starter ssh_config template ─────────────────────────────────────
_HAS_CFG="$(_read_env_var LLM_D0CKER_SHH_CFG_B64 "$SCRIPT_DIR/.env")"

if [ -n "$_HAS_CFG" ]; then
    info "An ssh_config is already saved in .env. Skipping template."
else
    ask_yes_no_tui "Seed a starter ~/.ssh/config template?" "y" GEN_CFG 0 1
    if [[ "$GEN_CFG" =~ ^[Yy] ]]; then
        _cfg_tmp="$(mktemp)"
        cat > "$_cfg_tmp" <<'EOC'
# ~/.ssh/config for the LLM Docker container — outbound to your servers.
#
# Edit the Host blocks below to match your real servers. Keys are loaded
# into the in-container ssh-agent at startup from the .env file (or the
# KeePassXC vault); this config only tells ssh which host uses which user.
#
# All Host entries share these defaults:
Host *
    ControlMaster auto
    ControlPath /tmp/ssh-cm-%r@%h:%p
    ControlPersist 10m
    ServerAliveInterval 30
    ServerAliveCountMax 3

# Example — replace with your own servers.
#
# Host myserver myserver.example.com
#     HostName myserver.example.com
#     Port 22
#     User llmdocker
#     StrictHostKeyChecking accept-new
EOC
        _CFG_B64="$(base64 < "$_cfg_tmp" 2>/dev/null | tr -d '\n')"
        safe_delete "$_cfg_tmp" || true
        _update_env_var LLM_D0CKER_SHH_CFG_B64 "$_CFG_B64"
        unset _CFG_B64
        success "Seeded starter ~/.ssh/config — edit .env (or the vault attachment) to add real hosts."
    fi
fi

# ─── 6b.3. Remote provisioner (optional-within-optional) ────────────────────
if [ -n "$NEW_LLMD_PUB" ]; then
    printf "\n"
    info "You can provision the ${secondary_accent}llmdocker${RESET} user on a remote server now."
    info "This creates the user with an sudo allowlist (install packages, restart services,"
    info "view logs) and installs the pubkey generated above. Fully OPTIONAL."
    ask_yes_no_tui "Provision llmdocker on a remote server now?" "n" PROV_CHOICE 1 0

    _PROVISIONER="$SCRIPT_DIR/tools/provision-llmdocker.sh"
    while [[ "$PROV_CHOICE" =~ ^[Yy] ]]; do
        ask_tui "Target server hostname or IP" "" PROV_HOST "$TREE_MID" 1 0 "" 0 "(e.g. myserver.example.com)"
        [ -z "$PROV_HOST" ] && { warn "No host — skipping."; break; }
        ask_tui "Admin user to log in as" "root" PROV_USER "$TREE_MID" 1 0
        ask_tui "SSH port" "22" PROV_PORT "$TREE_MID" 1 0

        # Verify local ssh can reach the box with the current keys.
        info "Testing SSH to ${PROV_USER}@${PROV_HOST}:${PROV_PORT}…"
        if ! ssh -o BatchMode=no -o ConnectTimeout=8 -o StrictHostKeyChecking=accept-new \
                 -p "$PROV_PORT" "$PROV_USER@$PROV_HOST" 'echo ok' >/dev/null 2>&1; then
            warn "Can't reach ${PROV_USER}@${PROV_HOST}:${PROV_PORT} without a password — install a key first (ssh-copy-id) or start ssh-agent."
        else
            if [ ! -f "$_PROVISIONER" ]; then
                warn "Provisioner script missing at $_PROVISIONER — skipping."
                break
            fi
            info "Uploading + running provisioner on ${PROV_HOST}…"
            if printf '%s\n' "$NEW_LLMD_PUB" | ssh -p "$PROV_PORT" "$PROV_USER@$PROV_HOST" \
                 "bash -s -- --pubkey-stdin" < "$_PROVISIONER"; then
                success "Provisioned llmdocker on ${PROV_HOST}."
            else
                warn "Provisioner reported a failure on ${PROV_HOST} — review its output above."
            fi
        fi

        ask_yes_no_tui "Provision another server?" "n" PROV_CHOICE 1 0
    done
elif [[ "$OUT_CHOICE" =~ ^[Yy] ]]; then
    info "No outbound key generated → skipping remote provisioner. Re-run install.sh to generate a key first."
fi

# ─── 6b.4. Vault-mode reminder ─────────────────────────────────────────────
if [ "$_OUT_IS_VAULT" = "true" ]; then
    printf "\n"
    info "Vault mode: after install, attach your ${secondary_accent}~/.ssh/config${RESET} to the KeePassXC entry ${C5}SSH/llm-docker-ssh-config${RESET}."
    info "env-gorilla will drop it at ${secondary_accent}\$S3C_ATTACHMENT_DIR/config${RESET} on unlock; the container reads it from there."
fi

success "Outbound SSH configured."
unset _OUT_IS_VAULT _HAS_OUT_KEY _HAS_CFG NEW_LLMD_PUB _PROVISIONER PROV_CHOICE PROV_HOST PROV_USER PROV_PORT
