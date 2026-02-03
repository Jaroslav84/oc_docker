#!/bin/bash

# Strip iTerm2-specific environment variables to prevent interference
unset ITERM2_SHELL_INTEGRATION_INSTALLED
unset ITERM2_SHELL_INTEGRATION_ENABLED
unset ITERM2_SHELL_INTEGRATION_PREVIOUS_PROMPT
unset ITERM2_PREV_PS1
unset ITERM2_SHELL_PREV_PS2

# Ensure proper terminal setup for mouse reporting and scrolling
# Set TERMINFO path for ncurses-term package
export TERMINFO=/usr/share/terminfo
export TERMINFO_DIRS=/usr/share/terminfo

# Set TERM if not already set (fallback to xterm-256color)
export TERM=${TERM:-xterm-256color}

# Ensure terminal size is set
if [ -z "$COLUMNS" ] || [ -z "$LINES" ]; then
    # Try to get terminal size from stty if available
    if command -v stty > /dev/null 2>&1; then
        TERM_SIZE=$(stty size 2>/dev/null || echo "24 80")
        LINES=${LINES:-$(echo $TERM_SIZE | cut -d' ' -f1)}
        COLUMNS=${COLUMNS:-$(echo $TERM_SIZE | cut -d' ' -f2)}
        export LINES COLUMNS
    fi
fi

# Determine which tool to run (default to opencode for backward compatibility)
TOOL=${TOOL:-opencode}

if [ "$TOOL" = "opencode" ]; then
    # Apply OpenCode config file if it exists
    if [ -f /tmp/opencode.config.jsonc ]; then
        echo "Applying OpenCode configuration..."
        mkdir -p /root/.config/opencode
        cp /tmp/opencode.config.jsonc /root/.config/opencode/config.json
        echo "Configuration applied to /root/.config/opencode/config.json"
    fi

    # API keys are read from environment variables (OPENAI_API_KEY, ZAI_API_KEY)
    # These are automatically loaded from .env file via docker-compose.yml

    # Run OpenCode
    if [ $# -gt 0 ]; then
        echo "Starting OpenCode with arguments: $@"
    else
        echo "Starting OpenCode..."
    fi
    opencode "$@"
    exit $?

elif [ "$TOOL" = "claude" ]; then
    # Ensure Claude config directory exists
    mkdir -p /root/.config/claude 2>/dev/null || true

    # API keys are read from environment variables (ANTHROPIC_API_KEY)
    # These are automatically loaded from .env file via docker-compose.yml or docker run

    # Run Claude Code
    if [ $# -gt 0 ]; then
        echo "Starting Claude Code with arguments: $@"
    else
        echo "Starting Claude Code..."
    fi
    claude "$@"
    exit $?

else
    echo "Error: Unknown TOOL value: $TOOL. Valid values are 'opencode' or 'claude'."
    exit 1
fi

