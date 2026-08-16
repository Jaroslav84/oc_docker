# setup/launcher.sh — module of the split setup.sh (sourced by the setup.sh loader).

# ── Shared launcher helpers (used identically by cld + ocd) ────────────────
# Lifted verbatim from the launchers so there's one copy. Tool-specific state
# (e.g. $_TERM_SESSIONS_FILE, $SCRIPT_DIR, colour vars) is read from globals the
# caller sets before invoking.

# Terminal identity for per-pane session tracking: iTerm session → tmux pane → tty.
_terminal_id() {
    if [ -n "${ITERM_SESSION_ID:-}" ]; then
        printf '%s' "$ITERM_SESSION_ID"
    elif [ -n "${TMUX_PANE:-}" ]; then
        printf 'tmux:%s' "$TMUX_PANE"
    else
        tty 2>/dev/null || printf 'unknown'
    fi
}

# Look up the saved session id for (terminal_id, project_key) in the tool's tsv.
_lookup_terminal_session() {
    local tid="$1" proj="$2"
    [ -f "$_TERM_SESSIONS_FILE" ] || return 0
    awk -F'\t' -v t="$tid" -v p="$proj" '$1==t && $2==p {u=$3} END{if(u) print u}' "$_TERM_SESSIONS_FILE"
}

# Register a deferred tmux INSTALL_* conf flip (accumulated, applied once).
_register_tmux_flip() {
    local flag="$1" label="$2"
    local cur
    cur="$(_read_env_var "$flag" "$SCRIPT_DIR/llm-docker.conf" 2>/dev/null)"
    [ "$cur" = "true" ] && return 0
    case " $_tmux_flip_kvs " in *" ${flag}=true "*) return 0 ;; esac
    _tmux_flip_kvs+="${flag}=true "
    [ -n "$_tmux_flip_labels" ] && _tmux_flip_labels+=", "
    _tmux_flip_labels+="$label"
}

# Background the builder-api daemon with a log file (final fallback / -ab path).
_spawn_api_bg() {
    local launcher="$1" project_dir="$2"
    local log="/tmp/builder-api-$$.log"
    nohup bash "$launcher" "$project_dir" >"$log" 2>&1 &
    local pid=$!
    disown "$pid" 2>/dev/null || true
    _log API "builder-api in background — PID $pid  ·  log: ${C2:-}$log${RST:-}"
}

# Dump forwarding-eligible env to a short-lived /tmp file so a spawned terminal
# inherits already-unwrapped secrets without re-prompting env-gorilla. Echoes
# the path, or nothing if there was nothing to forward.
_write_secret_handoff() {
    local dir="/tmp/s3c-gorilla"
    mkdir -p "$dir" 2>/dev/null || return 0
    chmod 700 "$dir" 2>/dev/null
    local f
    f=$(mktemp "$dir/handoff-XXXXXXXX" 2>/dev/null) || return 0
    chmod 600 "$f"
    local _block='^(PATH|HOME|TMPDIR|PWD|OLDPWD|SHELL|USER|LOGNAME|HOSTNAME|SHLVL|LD_.+|DYLD_.+|LLM_DOCKER_ENV_GORILLA)$'
    local n=0 k v
    while IFS='=' read -r k v; do
        [ -z "$k" ] && continue
        [[ "$k" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]] || continue
        [[ "$k" =~ $_block ]] && continue
        printf 'export %s=%q\n' "$k" "$v" >>"$f"
        n=$((n+1))
    done < <(env)
    if [ "$n" -eq 0 ]; then
        /bin/rm -f "$f"
        return 0
    fi
    echo "$f"
}

# Stop this project's builder-api daemon + close its panes on launcher exit.
_teardown_builder_api() {
    [ -n "${_BUILDER_API_PORT:-}" ] || return 0
    # Close the panes first (while the daemon is still alive so the port-based
    # lookup resolves), then make sure the daemon is dead for the bg/no-pane case.
    # macOS only (AppleScript). The script self-guards which terminal app is
    # actually running (iTerm or Terminal.app), so no TERM_PROGRAM lock here.
    if [ "${_BUILDER_API_PANES:-0}" = "1" ] && [[ "$OSTYPE" == darwin* ]]; then
        # Pass our OWN tty so the teardown closes the whole right column
        # (status/api/verbose) in this tab and spares only this pane.
        local _caller_tty; _caller_tty="$(tty 2>/dev/null || true)"
        osascript "$SCRIPT_DIR/builder-api/close_api_panes.applescript" \
            "$_BUILDER_API_PORT" "$CURRENT_DIR" "$_caller_tty" >/dev/null 2>&1 || true
    fi
    lsof -ti :"$_BUILDER_API_PORT" 2>/dev/null | xargs kill 2>/dev/null || true
}

# _maybe_start_api TOOL PROJECT_DIR — spawn the builder-api daemon (+ panels)
# when --api / -a was passed. Shared by cld + ocd; $1 is the log tag (CLD/OCD).
# The osascript spawn invocation is identical for both tools.
# _project_shard_lookup NAME FIELD — walks the two host-shard candidates
# ($HOME/.llm-docker/api_config/{<name>.toml, builder-api.toml}) looking for
# a [project.<NAME>] block (bare OR quoted: [project."NAME"]). If FIELD is
# "--exists", prints "yes" on match. Otherwise prints the first matching
# field value from within the block. Exit 0 on hit, 1 on miss.
_project_shard_lookup() {
    local _name="$1" _field="$2"
    local _cfg_dir="${HOME}/.llm-docker/api_config"
    local _f _out
    for _f in "$_cfg_dir/${_name}.toml" "$_cfg_dir/builder-api.toml"; do
        [ -f "$_f" ] || continue
        _out=$(awk -v n="$_name" -v fld="$_field" '
            BEGIN {
                # Escape regex metacharacters in the project name so a name
                # like "my.project" matches literally, not as "myXproject".
                n_esc = n
                gsub(/[][().*+?{}|^$\\]/, "\\\\&", n_esc)
                # Header matches: [project.NAME] or [project."NAME"] (with optional whitespace).
                hdr_re = "^[[:space:]]*\\[project\\.(\"" n_esc "\"|" n_esc ")\\][[:space:]]*$"
            }
            $0 ~ hdr_re {
                in_block = 1
                if (fld == "--exists") { print "yes"; exit }
                next
            }
            in_block && /^[[:space:]]*\[/ { in_block = 0 }
            in_block && fld != "--exists" {
                re = "^[[:space:]]*" fld "[[:space:]]*="
                if ($0 ~ re) {
                    sub(re "[[:space:]]*", "")
                    gsub(/[[:space:]]*(#.*)?$/, "")
                    # Strip surrounding quotes if present.
                    gsub(/^["'\'']/, ""); gsub(/["'\'']$/, "")
                    # Numeric fields (port): strip trailing non-digits.
                    if (fld == "port") gsub(/[^0-9].*$/, "")
                    print; exit
                }
            }
        ' "$_f")
        if [ -n "$_out" ]; then
            printf '%s' "$_out"
            return 0
        fi
    done
    return 1
}

_maybe_start_api() {
    [ "$START_API" = true ] || return 0

    local _tag="$1" project_dir="$2"
    local project_name
    project_name="$(basename "$project_dir")"
    # Strip leading dot — dot-dirs (~/.llm-docker etc.) are hidden config,
    # not projects; treating them as ".llm-docker" builds a nonsensical
    # [project..llm-docker] block name in the soft-skip probe.
    project_name="${project_name#.}"

    # Soft-skip: a project can legitimately have zero builder-api config (no
    # secrets, no jobs — just wants to run inside llm-docker). In that case
    # the daemon would hard-fail at boot ("no [project.<name>]…"); skip the
    # spawn cleanly instead so the panel doesn't flash a scary error.
    local _cfg_dir="${HOME}/.llm-docker/api_config"
    if [ ! -d "$_cfg_dir" ]; then
        _log "$_tag" WARNING "-a asked for, but $_cfg_dir/ doesn't exist — skipping builder-api. Create the dir and drop a project shard to enable."
        return 0
    fi
    if ! _project_shard_lookup "$project_name" --exists >/dev/null 2>&1; then
        _log "$_tag" WARNING "-a asked for, but no [project.$project_name] block found — skipping builder-api. Add $_cfg_dir/${project_name}.toml (or a block in builder-api.toml) to enable."
        return 0
    fi

    # Port precedence: per-project shard → base → llm-docker.conf → 6666.
    local port
    port="$(_project_shard_lookup "$project_name" port 2>/dev/null)"
    if [ -z "${port:-}" ]; then
        port="$(_read_env_var BUILDER_API_PORT "$SCRIPT_DIR/llm-docker.conf" 2>/dev/null)"
    fi
    port="${port:-6666}"
    # Record for teardown on launcher exit (see _teardown_builder_api).
    _BUILDER_API_PORT="$port"

    # Orphan-daemon cleanup: kill any previous daemon still bound to this
    # project's port so the fresh spawn binds clean — reliably gives new panels
    # every `-a` instead of "no panels" when the old pane is gone but the daemon
    # lingered (the AppleScript reuse path only covers pane-still-alive).
    if command -v lsof >/dev/null 2>&1; then
        local _api_existing_pid
        _api_existing_pid=$(lsof -ti :"$port" 2>/dev/null | head -1)
        if [ -n "$_api_existing_pid" ]; then
            kill "$_api_existing_pid" 2>/dev/null
            sleep 0.4
        fi
        unset _api_existing_pid
    fi

    local launcher="$SCRIPT_DIR/builder-api/run-local.sh"
    if [ ! -f "$launcher" ]; then
        _log "$_tag" WARNING "builder-api launcher not found; skipping --api spawn"
        return 0
    fi

    if [[ "$OSTYPE" == "darwin"* ]]; then
        if [ "$START_API_BG" = true ]; then
            _spawn_api_bg "$launcher" "$project_dir"
            return 0
        fi

        # Hand our already-unwrapped secrets to the new window via a short-lived
        # file so run-local.sh's sentinel skips its own env-gorilla call.
        local handoff
        handoff="$(_write_secret_handoff)"

        # Spawn the cld-status dashboard + verbose console alongside the panel
        # when they exist (3-pane split: status / api / verbose).
        local status_cmd=""
        if [ -x "$SCRIPT_DIR/cld-status" ]; then
            status_cmd="exec $SCRIPT_DIR/cld-status"
        fi
        # cld-verbose needs BUILDER_API_P4SS to auth the /ws stream, but
        # (unlike the api pane) it isn't handed the daemon's secrets. Give it
        # its OWN short-lived handoff: source it for the password, delete it,
        # then exec. Falls back to a bare exec (cld-verbose warns) if none.
        # Force the daemon's ACTUAL host+port onto cld-verbose (as env prefixes
        # on exec, so they win over any stale values sourced from the handoff).
        # It runs on the host, so the daemon is 127.0.0.1 — NOT the container's
        # BUILDER_API_HOST (host.docker.internal), and NOT a leftover PORT.
        local _vb_env="BUILDER_API_HOST=127.0.0.1 BUILDER_API_PORT=$port"
        local verbose_cmd=""
        if [ -x "$SCRIPT_DIR/cld-verbose" ]; then
            local _vhandoff
            _vhandoff="$(_write_secret_handoff)"
            if [ -n "$_vhandoff" ]; then
                verbose_cmd="source '$_vhandoff'; /bin/rm -f '$_vhandoff'; $_vb_env exec '$SCRIPT_DIR/cld-verbose'"
            else
                verbose_cmd="$_vb_env exec '$SCRIPT_DIR/cld-verbose'"
            fi
        fi

        # 1a) Inside iTerm? Split the current window left/right. The AppleScript
        # handles its own reuse + orphan cleanup before spawning.
        if [ "${TERM_PROGRAM:-}" = "iTerm.app" ]; then
            if osascript "$SCRIPT_DIR/builder-api/builder_api.applescript" "$launcher" "$project_dir" split "$port" "$handoff" "$status_cmd" "$verbose_cmd" >/dev/null 2>&1; then
                _BUILDER_API_PANES=1
                _log "$_tag" "builder-api split into right pane (port $port)"
                return 0
            fi
        fi

        # 1b) Not in iTerm, or split denied: positioned new window.
        if osascript "$SCRIPT_DIR/builder-api/builder_api.applescript" "$launcher" "$project_dir" new-window "$port" "$handoff" "$status_cmd" "$verbose_cmd" >/dev/null 2>&1; then
            _BUILDER_API_PANES=1
            _log "$_tag" "builder-api spawned in positioned iTerm window (port $port)"
            return 0
        fi

        # 2) AppleScript denied (macOS TCC). Open a .command via LaunchServices
        # instead — no AppleEvents permission needed, but loses positioning.
        local cmd_file
        cmd_file=$(mktemp -t builder-api.XXXXXX).command
        cat >"$cmd_file" <<EOF
#!/bin/bash
cd "$project_dir"
exec bash "$launcher" "$project_dir" "$handoff"
EOF
        chmod +x "$cmd_file"
        if [ -d "/Applications/iTerm.app" ] && open -a iTerm "$cmd_file" 2>/dev/null; then
            _log "$_tag" WARNING "AppleScript blocked by macOS — opened iTerm without positioning. Enable iTerm in Settings → Privacy → Automation to restore."
            return 0
        fi
        # iTerm-only setup: never fall back to Terminal.app. If iTerm can't be
        # reached, background the daemon silently instead of a native window.

        # 3) No terminal cooperated — background it.
        _log "$_tag" WARNING "No terminal app available. Backgrounding."
        _spawn_api_bg "$launcher" "$project_dir"
    else
        # Linux/other: no universal terminal, so background it.
        _spawn_api_bg "$launcher" "$project_dir"
    fi
}

# spawn_multi_windows TOOL — when WINDOW_COUNT>1 on macOS, fan out N positioned
# terminal windows via multi-llm-docker.applescript and exit. No-op (returns)
# for the single-window case so the launcher proceeds to run_*_container.
spawn_multi_windows() {
    local _tag="$1" _launcher
    case "$_tag" in CLD) _launcher=cld;; OCD) _launcher=ocd;; *) _launcher="$_tag";; esac
    { [ "$WINDOW_COUNT" -gt 1 ] && [[ "$OSTYPE" == "darwin"* ]]; } || return 0
    local SLOT_MODE="new"
    [ "$CONTINUE_SESSION" = true ] && SLOT_MODE="restore"
    _log "$_tag" "Opening $WINDOW_COUNT terminal windows ($SLOT_MODE mode)..."
    local _OSA_ERR _OSA_RC
    _OSA_ERR=$(osascript "$SCRIPT_DIR/multi-llm-docker.applescript" "$SCRIPT_DIR/$_launcher" "$WINDOW_COUNT" "$CURRENT_DIR" "$SLOT_MODE" 2>&1)
    _OSA_RC=$?
    if [ "$_OSA_RC" -ne 0 ]; then
        if printf '%s' "$_OSA_ERR" | grep -qE -- '-1743|Not authori[sz]ed'; then
            _log "$_tag" ERROR "macOS blocked AppleScript from controlling iTerm."
            _log "$_tag" "Resetting the permission now so macOS will re-prompt..."
            tccutil reset AppleEvents com.googlecode.iterm2 2>/dev/null || true
            _log "$_tag" "Now rerun: ${C2:-}$_launcher $WINDOW_COUNT${RST:-}"
            _log "$_tag" "macOS will prompt 'iTerm wants to control iTerm' — click Allow."
            _log "$_tag" "Permanent fix: System Settings → Privacy & Security → Automation → iTerm → check iTerm."
        else
            _log "$_tag" ERROR "multi-window layout failed:"
            printf '%s\n' "$_OSA_ERR" | sed 's/^/    /'
        fi
        exit 1
    fi
    exit 0
}

# _set_tab_color TOKEN — tint the current iTerm tab with the project's hue (the
# SAME color cld-status assigns), so the main Claude/OpenCode pane is always
# color-coded by project. iTerm-only; no-op elsewhere. Delegates the hash +
# 256→RGB to cld-status so the color matches exactly.
_set_tab_color() {
    [ "${TERM_PROGRAM:-}" = "iTerm.app" ] || return 0
    [ -x "$SCRIPT_DIR/cld-status" ] || return 0
    "$SCRIPT_DIR/cld-status" --tab-color "$1" 2>/dev/null || true
}
