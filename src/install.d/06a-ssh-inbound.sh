# ── 6a. SSH inbound (macOS → container) ─────────────────────────────────────
header_tui "6a/12  SSH inbound (optional)"
info "Public-key auth only. Enabling forces bridge networking (docker -p)."
info "Lets you ${secondary_accent}ssh root@llm-docker${RESET} from your Mac into the container."

# Vault mode. 03-env.sh already set GORILLA_ENABLED in this shell; re-reading
# llm-docker.conf here would be redundant.
_IS_VAULT="${GORILLA_ENABLED:-false}"

CUR_SSH_EN="$(_read_env_var LLM_D0CKER_SHH_EN4BLED "$SCRIPT_DIR/llm-docker.conf")"
SSH_PRESET="n"
[ "$CUR_SSH_EN" = "true" ] && SSH_PRESET="y"
ask_yes_no_tui "Enable inbound SSH?" "$SSH_PRESET" SSH_CHOICE 1 0

if [[ ! "$SSH_CHOICE" =~ ^[Yy] ]]; then
    _update_conf_var LLM_D0CKER_SHH_EN4BLED "false"
    success "SSH disabled"
    return 0 2>/dev/null || :
fi

# ─── 6a. Inbound: sshd inside container (macOS → container) ─────────────────
CUR_HOST_PORT="$(_read_env_var LLM_DOCKER_SSH_HOST_PORT "$SCRIPT_DIR/llm-docker.conf")"
[ -z "$CUR_HOST_PORT" ] && CUR_HOST_PORT="8884"
ask_tui "Host port (LLM_DOCKER_SSH_HOST_PORT)" "$CUR_HOST_PORT" NEW_HOST_PORT "$TREE_MID" 1 0

# ─── 6b. Authorized keys: whose Mac keys can log in as root ─────────────────
PUB_FILES=()
for f in "$HOME"/.ssh/*.pub; do
    [ -f "$f" ] && PUB_FILES+=("$f")
done

NEW_KEY=""
if [ ${#PUB_FILES[@]} -eq 0 ]; then
    warn "No ~/.ssh/*.pub files found."
    ask_tui "Paste public key" "" PASTE_KEY "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
    NEW_KEY="$PASTE_KEY"
else
    opts=""
    descs=""
    default_idx=""
    idx=0
    for f in "${PUB_FILES[@]}"; do
        fname="$(basename "$f")"
        key_line="$(cat "$f")"
        key_type="$(printf '%s' "$key_line" | awk '{print $1}')"
        key_cmt="$(printf '%s' "$key_line" | awk '{print $NF}')"
        [ "$key_cmt" = "$key_type" ] && key_cmt="(no comment)"
        [ -n "$opts" ] && opts+=$'\n'
        opts+="$fname"
        [ -n "$descs" ] && descs+=$'\n'
        descs+="${key_type} — ${key_cmt}"
        if [ "$fname" = "id_ed25519.pub" ] && [ -z "$default_idx" ]; then
            default_idx="$idx"
        fi
        idx=$((idx + 1))
    done
    [ -z "$default_idx" ] && default_idx="0"

    checklist_tui "Select public keys to authorize" "$opts" "$descs" "" "$default_idx" SSH_PUBS true 1 0

    for i in "${!PUB_FILES[@]}"; do
        chosen="$(eval "echo \"\${SSH_PUBS_${i}:-false}\"")"
        if [ "$chosen" = "true" ]; then
            key_content="$(cat "${PUB_FILES[$i]}")"
            [ -n "$NEW_KEY" ] && NEW_KEY="${NEW_KEY}\\n"
            NEW_KEY="${NEW_KEY}${key_content}"
        fi
    done

    ask_tui "Paste an additional public key (optional)" "" PASTE_KEY "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
    if [ -n "$PASTE_KEY" ]; then
        [ -n "$NEW_KEY" ] && NEW_KEY="${NEW_KEY}\\n"
        NEW_KEY="${NEW_KEY}${PASTE_KEY}"
    fi
fi

_update_conf_var LLM_D0CKER_SHH_EN4BLED    "true"
_update_conf_var LLM_DOCKER_SSH_HOST_PORT  "$NEW_HOST_PORT"
_update_conf_var LLM_DOCKER_SSH_PORT       "22"
_update_env_var  LLM_D0CKER_SHH_4UTH_PBLKZ "$NEW_KEY"

# openssh-server is apt-installed at build time only (install_devpack.sh).
# Transitioning false→true on an existing image needs a rebuild.
[ "$CUR_SSH_EN" != "true" ] && _mark_rebuild_needed "SSH enabled (needs openssh-server baked in)"

if [ -z "$NEW_KEY" ]; then
    warn "No public key saved — SSH will reject every login until you add one."
fi
success "SSH inbound enabled — connect with: ${secondary_accent}ssh -p $NEW_HOST_PORT root@localhost${RESET}"

# Offer the hostname alias so the user can `ssh root@llm-docker`.
if ! grep -qE '^[0-9.]+[[:space:]]+llm-docker(\s|$)' /etc/hosts 2>/dev/null; then
    info "Optional: add ${secondary_accent}llm-docker${RESET} as a hostname alias on your Mac so you can ${secondary_accent}ssh -p $NEW_HOST_PORT root@llm-docker${RESET}"
    info "Run this once (requires sudo):"
    printf "    %becho \"127.0.0.1    llm-docker\" | sudo tee -a /etc/hosts%b\n" "$secondary_accent" "$RESET"
else
    success "/etc/hosts already has an ${secondary_accent}llm-docker${RESET} entry — you can use ${secondary_accent}ssh root@llm-docker${RESET}"
fi

# ─── 6c. SSHD host keys (container's own identity) ──────────────────────────
#
# These are the ed25519/rsa/ecdsa keys sshd presents when clients connect.
# Under the vault-first design, they're STORED in the s3c-gorilla vault (either
# as file attachments once env-gorilla supports it, or as base64 env vars in
# the interim) and decoded into ephemeral /etc/ssh/keys/ at container startup.
#
# Fingerprint stays stable across launches because the vault is the source of
# truth. Empty vault → setup-ssh.sh falls back to fresh generation with a
# loud warning. We offer to seed the vault on first install below.

_prefill_key LLM_D0CKER_SHH_SRV_ED25519_PVYT_B64
_HAS_SRV_KEYS="$CUR"
if [ -n "$_HAS_SRV_KEYS" ] && [ "${FORCE_REGEN:-0}" != "1" ]; then
    info "SSHD host keys: already set (loaded from vault or .env) — skipping regen. Set FORCE_REGEN=1 to regenerate."
else
    info "SSHD host keys: none set. Container will auto-generate fresh keys each launch (fingerprint churn)."
    ask_yes_no_tui "Generate persistent SSHD host keys now? (base64 → paste block for vault/.env)" "y" GEN_HOST 0 1
    if [[ "$GEN_HOST" =~ ^[Yy] ]]; then
        _hk_tmp="$(mktemp -d)"
        for t in ed25519 rsa ecdsa; do
            ssh-keygen -q -t "$t" -f "$_hk_tmp/ssh_host_${t}_key" -N "" -C "llm-docker-host" 2>/dev/null
        done

        # Compute base64 (single-line) of each half.
        _b64() { base64 < "$1" 2>/dev/null | tr -d '\n'; }
        _K_ED25519_PV="$(_b64 "$_hk_tmp/ssh_host_ed25519_key")"
        _K_ED25519_PU="$(_b64 "$_hk_tmp/ssh_host_ed25519_key.pub")"
        _K_RSA_PV="$(_b64 "$_hk_tmp/ssh_host_rsa_key")"
        _K_RSA_PU="$(_b64 "$_hk_tmp/ssh_host_rsa_key.pub")"
        _K_ECDSA_PV="$(_b64 "$_hk_tmp/ssh_host_ecdsa_key")"
        _K_ECDSA_PU="$(_b64 "$_hk_tmp/ssh_host_ecdsa_key.pub")"

        # Trash the temp files IMMEDIATELY — key material never sits on disk.
        # `|| true` so a Trash-permission blip on macOS doesn't kill the installer.
        safe_delete "$_hk_tmp" || true
        unset _hk_tmp

        # Write to .env (fallback + vault users still source from .env at first)
        _update_env_var LLM_D0CKER_SHH_SRV_ED25519_PVYT_B64 "$_K_ED25519_PV"
        _update_env_var LLM_D0CKER_SHH_SRV_ED25519_PBLK_B64 "$_K_ED25519_PU"
        _update_env_var LLM_D0CKER_SHH_SRV_RS4_PVYT_B64     "$_K_RSA_PV"
        _update_env_var LLM_D0CKER_SHH_SRV_RS4_PBLK_B64     "$_K_RSA_PU"
        _update_env_var LLM_D0CKER_SHH_SRV_ECDS4_PVYT_B64   "$_K_ECDSA_PV"
        _update_env_var LLM_D0CKER_SHH_SRV_ECDS4_PBLK_B64   "$_K_ECDSA_PU"

        success "Generated ed25519 + rsa + ecdsa host keys — saved to .env (paste block at end of install)."
        unset _K_ED25519_PV _K_ED25519_PU _K_RSA_PV _K_RSA_PU _K_ECDSA_PV _K_ECDSA_PU
    fi
fi

# Outbound SSH (container → your servers) is handled by 06b-ssh-outbound.sh.
unset _HAS_SRV_KEYS _IS_VAULT
