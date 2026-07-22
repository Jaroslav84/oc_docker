#!/bin/bash
# Check if Quake is listening on the expected port
lsof -i :27960 -i :27961 2>/dev/null | head -20
echo "---"
# Also check what the rcon password is in autoexec
grep -i rcon /Users/yaro/Projects/q3ide/baseq3/autoexec.cfg 2>/dev/null
echo "---"
# Check .quake3home config
grep -i rcon /Users/yaro/Projects/q3ide/.quake3home/baseq3/q3config.cfg 2>/dev/null | head -5
