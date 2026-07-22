#!/bin/bash
# Usage: rcon_send.sh <command>
CMD="${1:-echo TEST}"
printf '\xff\xff\xff\xffrcon q3idedev666 '"$CMD"'\n' | nc -u -w2 127.0.0.1 27961 2>&1 | strings
