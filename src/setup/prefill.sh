# setup/prefill.sh — helper for pre-filling secret prompts during install.sh
# from either the KeePassXC vault (via env-gorilla) or the .env file.
#
# Priority when vault mode is active (LLM_DOCKER_ENV_GORILLA=1, set by the
# re-exec block at the top of install.sh):
#   1. shell env — env-gorilla injected the vault value → freshest wins
#   2. .env file — fallback (may hold stale local edits)
# Priority when NOT in vault mode:
#   1. .env file only (with a very-last-resort shell-env fallback for edge cases)
#
# Usage:
#   _prefill_key MY_KEY_NAME
#   # sets CUR (the value) and CUR_SRC ("vault" / ".env" / "shell env" / "")

_prefill_key() {
    local _key="$1"
    CUR=""
    CUR_SRC=""
    if [ "${LLM_DOCKER_ENV_GORILLA:-}" = "1" ] && [ -n "${!_key:-}" ]; then
        CUR="${!_key}"
        CUR_SRC="env-gorilla vault"
        return 0
    fi
    CUR="$(_read_env_var "$_key" "$SCRIPT_DIR/.env")"
    if [ -n "$CUR" ]; then
        CUR_SRC=".env"
        return 0
    fi
    if [ -n "${!_key:-}" ]; then
        CUR="${!_key}"
        CUR_SRC="shell env"
    fi
}
