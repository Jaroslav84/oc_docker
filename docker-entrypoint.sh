#!/bin/bash

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
echo "Starting OpenCode..."
opencode

# When OpenCode exits, drop to shell
echo "OpenCode exited. Dropping to shell..."
exec /bin/bash

