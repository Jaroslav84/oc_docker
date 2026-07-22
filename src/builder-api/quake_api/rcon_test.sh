#!/bin/bash
printf '\xff\xff\xff\xffrcon q3idedev666 echo TEST_RCON\n' | nc -u -w2 127.0.0.1 27960 2>&1 | strings | head -c 200
