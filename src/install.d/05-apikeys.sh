# ── 5. API keys & behavior ──────────────────────────────────────────────────
header_tui "5/12  API keys & behavior"

info "Press Enter on any token to keep its current value. Masked preview shown for existing tokens."
info "Loading existing values from: ${secondary_accent}$SCRIPT_DIR/.env${RESET} and the shell env (env-gorilla vault when active)."

# Anthropic
_prefill_key _4NTHR0P1C_H4NDLE; CUR_ANT="$CUR"; CUR_ANT_SRC="$CUR_SRC"
if [ -n "$CUR_ANT" ]; then
    ask_tui "Anthropic API Key (from $CUR_ANT_SRC — Enter to keep)" "$CUR_ANT" NEW_ANTHROPIC "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_ANT")"
else
    ask_tui "Anthropic API Key - don't set this and use /login if you have subscription" "" NEW_ANTHROPIC "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
fi
[ -z "$NEW_ANTHROPIC" ] && NEW_ANTHROPIC="$CUR_ANT"

# OpenAI
_prefill_key _0P3N4I_H4NDLE; CUR_OAI="$CUR"; CUR_OAI_SRC="$CUR_SRC"
if [ -n "$CUR_OAI" ]; then
    ask_tui "OpenAI Key (from $CUR_OAI_SRC — Enter to keep)" "$CUR_OAI" NEW_OPENAI "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_OAI")"
else
    ask_tui "OpenAI Key" "" NEW_OPENAI "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
fi
[ -z "$NEW_OPENAI" ] && NEW_OPENAI="$CUR_OAI"

# Z.AI
_prefill_key Z41_H4NDLE; CUR_ZAI="$CUR"; CUR_ZAI_SRC="$CUR_SRC"
if [ -n "$CUR_ZAI" ]; then
    ask_tui "Z.AI API Key (from $CUR_ZAI_SRC — Enter to keep)" "$CUR_ZAI" NEW_ZAI "$TREE_MID" 1 0 "" 0 "" "$(_mask_secret "$CUR_ZAI")"
else
    ask_tui "Z.AI API Key" "" NEW_ZAI "$TREE_MID" 1 0 "" 0 "(leave empty to skip)"
fi
[ -z "$NEW_ZAI" ] && NEW_ZAI="$CUR_ZAI"

unset CUR CUR_SRC CUR_ANT_SRC CUR_OAI_SRC CUR_ZAI_SRC

_update_env_var _4NTHR0P1C_H4NDLE "$NEW_ANTHROPIC"
_update_env_var _0P3N4I_H4NDLE    "$NEW_OPENAI"
_update_env_var Z41_H4NDLE       "$NEW_ZAI"

CUR_EXIT="$(_read_env_var EXIT_TO_DOCKER "$SCRIPT_DIR/llm-docker.conf")"
[ -z "$CUR_EXIT" ] && CUR_EXIT="false"
EXIT_PRESET="n"
[ "$CUR_EXIT" = "true" ] && EXIT_PRESET="y"
ask_yes_no_tui "Drop to container shell on Claude/OpenCode exit (EXIT_TO_DOCKER)?" "$EXIT_PRESET" EXIT_CHOICE 1 0
if [[ "$EXIT_CHOICE" =~ ^[Yy] ]]; then NEW_EXIT="true"; else NEW_EXIT="false"; fi
_update_conf_var EXIT_TO_DOCKER "$NEW_EXIT"
success "API keys + behavior saved"

