# ── 2. Data directories ─────────────────────────────────────────────────────
header_tui "2/12  Creating data directories"
if [ -d "$HOME/.llm-docker" ] && [ -n "$(ls -A "$HOME/.llm-docker" 2>/dev/null)" ]; then
    info "~/.llm-docker already exists (sessions, auth, SSH keys may live there)."
    ask_yes_no_tui "Wipe and recreate? (No = merge — keep existing files)" "n" WIPE_DIRS 1 0
    if [[ "$WIPE_DIRS" =~ ^[Yy] ]]; then
        if safe_delete "$HOME/.llm-docker"; then
            setup_dirs >/dev/null
            success "~/.llm-docker moved to trash and recreated"
        else
            warn "Could not move ~/.llm-docker to trash — leaving it in place. Install trash-cli or use --wipe-dirs=false."
        fi
    else
        setup_dirs >/dev/null
        success "~/.llm-docker merged (existing files kept)"
    fi
else
    setup_dirs >/dev/null
    success "~/.llm-docker/  structure ready"
fi

