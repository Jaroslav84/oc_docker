#!/bin/bash

# Run OpenCode
echo "Starting OpenCode..."
opencode

# When OpenCode exits, drop to shell
echo "OpenCode exited. Dropping to shell..."
exec /bin/bash

