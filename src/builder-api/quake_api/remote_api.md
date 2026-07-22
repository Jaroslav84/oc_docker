# Q3IDE Remote API — Cheatsheet

Server runs on macOS. Claude (Docker) calls `http://host.docker.internal:6666/...`

## Start

```sh
# Manually
python3 scripts/remote_api.py

# Via build.sh (recommended) — starts in background, logs to logs/remote_api.log
sh ./scripts/build.sh --api

# env overrides: Q3IDE_API_PORT=6666  Q3IDE_RCON_PASSWORD=q3idedev666
```

## Endpoints

| Method | Path | Description |
|--------|------|-------------|
| GET | `/` | Health check + game running? |
| GET | `/status` | PID, uptime, running bool, build state |
| POST | `/build` | **Enqueue** a build — returns `queue_id` immediately |
| GET | `/build_status?id=<id>&wait=<s>` | Status of a build — **long-poll** with `wait` param |
| GET | `/queue` | Full queue: `current`, `pending[]`, `history[]` |
| DELETE | `/queue/<id>` | Cancel a pending (not yet started) build |
| POST | `/run` | Launch game in background |
| POST | `/stop` | Kill game process |
| GET | `/crash` | Last crash: signal + crash block + q3ide tail |
| GET | `/macoscrash?n=N` | **macOS DiagnosticReports** for Quake — pre-symbolicated, all threads. `n`=1..10 (default 1). Use FIRST after any crash. |
| GET | `/logs?file=<alias>&n=<lines>` | Tail a log file |
| GET | `/events?type=<t>&since=<ts>&n=<n>&pid=<pid>` | Query structured JSON events |
| POST | `/console` | Send RCON command, return response |
| POST | `/symbolicate {"addrs":[...]}` | xcrun atos → file:line |
| POST | `/send2trash {"path":"..."}` | Safely delete file on macOS host |
| POST | `/applescript {"script":"..."}` | Run osascript on macOS host |
| GET | `/ws` | **WebSocket** — live log stream + RCON |

## Build Queue

`POST /build` enqueues rather than blocking. Multiple agents can submit simultaneously — they run one at a time, FIFO.

```python
# Enqueue a build
r = api('POST', '/build', {
    'args': ['--clean', '--engine-only'],
    'agent_id': 'my-agent',   # optional label for tracking
    'auto_run': True,         # launch game after build — ONLY if game is not already running
                              # if game IS running, build succeeds but Quake is left untouched
})
qid = r['queue_id']
```

### Choosing the right build mode

**Rule: never kill Quake unless the changed code forces a restart.**

| Situation | `args` | `auto_run` | Quake effect |
|-----------|--------|------------|--------------|
| Compile check only | `['--engine-only']` or `['--game-only']` | omit | Nothing — just verifies it builds |
| Swift overlay changed | `['--overlay-only']` | omit | Hot-reloads overlay (~30s), Quake untouched |
| Game logic changed (`code/game/`) | `['--game-only']` | omit | Hot-reloads qagame.so via map restart (~5s), Quake untouched |
| **q3ide-editor Rust crate** | `['--editor-only']` | omit | Quake untouched — builds `q3ide-editor/` only |
| Engine C changed (`code/q3ide/`) | `['--engine-only']` | `True` | Launches Quake **only if not already running** |
| Full build, first launch | `[]` | `True` (default) | Launches Quake **only if not already running** |

`auto_run: True` (or omitted) **will NOT kill a running Quake.** It only launches if the game is not running. Use `POST /kill` + `POST /run` explicitly if you need a forced restart.

```python
# Just verify code compiles — Quake never touched
qid = api('POST', '/build', {'args': ['--engine-only']})['queue_id']

# Build q3ide-editor (Rust) — Quake never touched
qid = api('POST', '/build', {'args': ['--editor-only']})['queue_id']

# Hot-reload Swift overlay — Quake never touched
qid = api('POST', '/build', {'args': ['--overlay-only']})['queue_id']

# Hot-reload game logic — Quake never touched
qid = api('POST', '/build', {'args': ['--game-only']})['queue_id']

# Full build — only launches Quake if it isn't already running
qid = api('POST', '/build', {'args': []})['queue_id']

# Force restart (explicit — use only when engine C changed and Quake must reload)
api('POST', '/kill')
api('POST', '/build', {'args': ['--engine-only']})
# ... wait for build done ...
api('POST', '/run', {'args': ['--level', 'r']})
```

## Robust Build Wait (preferred — no sleep loop)

Use `?wait=30` to long-poll. The server blocks until the build completes OR 30s elapses, then returns. If `timed_out: true`, retry immediately. **No sleep loop needed. No Docker timeout risk.**

```python
# Robust build wait — blocks up to 30s per call, retries if needed
qid = api('POST', '/build', {'args': ['--clean', '--engine-only'],
                              'agent_id': AGENT_NAME})['queue_id']
while True:
    s = api('GET', f'/build_status?id={qid}&wait=30')  # blocks up to 30s
    if s.get('timed_out'):
        continue  # timed out — server retries immediately, no sleep needed
    if s['status'] in ('done', 'failed', 'cancelled', 'gone'):
        break

if s['status'] != 'done':
    print('BUILD FAILED:')
    print(s.get('log_tail', ''))  # last 40 lines of build.log — included automatically
    raise RuntimeError(f"Build {s['status']}: rc={s.get('returncode')}")
```

`log_tail` is included in the response when the build is finished (done/failed/cancelled). It contains the last 40 lines of `build.log` — no separate log call needed to see errors.

Build entry fields: `id`, `agent_id`, `args`, `status`, `returncode`, `queued_at_iso`, `started_at_iso`, `finished_at_iso`, `elapsed_s`, `log_tail` (on completion), `timed_out`

Statuses: `queued` → `building` → `done` | `failed` | `cancelled` | `gone` (stale — api restarted)

```python
# Inspect full queue
q = api('GET', '/queue')
print('current:', q['current'])
print('pending:', q['pending'])   # list of queued items with timestamps
print('history:', q['history'])   # last 20 completed/cancelled

# Cancel a pending build
api('DELETE', f'/queue/{qid}')

# Kill everything (game + build + clear queue)
api('POST', '/kill')
```

## Structured Events (`/events`) — preferred for log checking

The engine writes structured JSON events to `logs/q3ide_events.jsonl`. Query them here instead of grepping raw logs.

```python
# All recent events (last 200)
events = api('GET', '/events?n=200')['events']

# Filter by type
attached = api('GET', '/events?type=attach_done')['events']

# Events since a Unix timestamp (e.g. since session start)
recent = api('GET', f'/events?since={session_ts}')['events']

# Events for specific PID (current game session)
pid = api('GET', '/')['pid']
evts = api('GET', f'/events?pid={pid}&since={session_ts}')['events']
```

Response: `{"events": [...], "count": N, "total": M}` (total = unfiltered count in file)

**Known event types:**

| Type | Emitter | Key fields |
|------|---------|------------|
| `session_start` | Q3IDE_Init | — |
| `session_end` | Q3IDE_Shutdown | — |
| `dylib_loaded` | q3ide_wm | — |
| `dylib_failed` | q3ide_wm | `reason` |
| `window_found` | q3ide_cmd | `wid`, `w`, `h` |
| `display_found` | q3ide_cmd | `id`, `w`, `h` |
| `window_attached` | q3ide_cmd | `wid`, `wall`, `x` |
| `display_attached` | q3ide_cmd | `id`, `wall`, `x` |
| `attach_done` | q3ide_cmd | `attached`, `total` |

**Confirm successful attach:**
```python
evts = api('GET', f'/events?type=attach_done&pid={pid}')['events']
if not evts:
    raise RuntimeError("No attach_done event — attach may have failed")
e = evts[-1]
print(f"Attached {e['attached']}/{e['total']} windows")
```

## Quake Home Directory

Quake writes all persistent files into `.quake3home/` (`fs_homepath=$ROOT/.quake3home`):

| File | Path (Docker) | Notes |
|------|--------------|-------|
| Player config | `.quake3home/baseq3/q3config.cfg` | Persisted cvars + binds. Edit directly. |
| Engine log | `.quake3home/baseq3/qconsole.log` | Raw Quake stdout |
| Q3IDE debug log | `.quake3home/baseq3/q3ide_debug.txt` | Q3IDE structured log |
| Crash log | `.quake3home/baseq3/crashlog.txt` | macOS crash reports |
| Online identity | `.quake3home/qkey` | Binary. Required for online play. |

Gitignored. Never wiped by `--clean`. No more guessing what's in `~/Library/Application Support/Quake3/`.

## Log Files (`/logs`)

```python
# Tail last N lines of a log
api('GET', '/logs?file=q3ide&n=400')   # q3ide structured log (levelled, timestamped)
api('GET', '/logs?file=engine&n=400') # raw engine log
api('GET', '/logs?file=build&n=400')  # build output
api('GET', '/logs?file=capture&n=400') # Rust capture dylib log
```

Log file aliases: `engine`, `multimon`, `capture`, `build`, `q3ide`

**`q3ide` log** (`logs/q3ide.log`) — Q3IDE-only output, no Quake3e engine noise. Format:
```
=== SESSION pid=12345 2026-03-08T12:00:00 ===
[I]    1.234 dylib loaded ok
[W]    2.345 capture start failed id=42
[E]   12.678 out of window slots
=== END pid=12345 2026-03-08T12:01:30 ===
```

Levels: `[I]` info | `[W]` warning | `[E]` error. Timestamp is seconds since process start.

## WebSocket (`/ws`) — preferred debug interface

Connect from Docker:
```python
import sys
sys.path.insert(0, '/root/Projects/q3ide/scripts')
from ws_debug import Q3Debug

with Q3Debug() as dbg:
    dbg.watch(seconds=20)                      # stream all logs live
    print(dbg.cmd('q3ide status'))             # RCON, blocks for response
    print(dbg.cmd('status'))
    dbg.watch(seconds=10,
        filter_fn=lambda f, l: f == 'multimon')  # watch multimon only
```

Query params: `?logs=engine,multimon,q3ide,capture` (default: `engine,multimon`)

Messages received (JSON):
- `{"type":"log", "file":"engine"|"multimon"|"capture"|"q3ide", "line":"..."}`
- `{"type":"rcon", "cmd":"...", "response":"...", "ok":true}`
- `{"type":"status", "running":bool, "pid":int, "uptime_s":int}`
- `{"type":"hello", "logs":[...], "rcon_port":27960}`

Send to server: `{"cmd": "q3ide status"}` → RCON response

## HTTP curl examples

```sh
HOST=host.docker.internal  # or localhost if running curl on macOS directly

# Health
curl http://$HOST:6666/

# Build (enqueue) + wait for completion
curl -s -X POST http://$HOST:6666/build \
  -H 'Content-Type: application/json' \
  -d '{"args":["--clean"]}'
# → {"queue_id": "a1b2c3d4", ...}
curl -s "http://$HOST:6666/build_status?id=a1b2c3d4&wait=30"

# Launch (level 0)
curl -s -X POST http://$HOST:6666/run \
  -H 'Content-Type: application/json' \
  -d '{"args":["--level","0"]}'

# Stop
curl -s -X POST http://$HOST:6666/stop

# RCON via HTTP
curl -s -X POST http://$HOST:6666/console \
  -H 'Content-Type: application/json' \
  -d '{"cmd":"q3ide status"}'

# Tail log (last 50 lines)
curl -s 'http://$HOST:6666/logs?file=q3ide&n=400'
curl -s 'http://$HOST:6666/logs?file=engine&n=400'

# Recent events
curl -s 'http://$HOST:6666/events?n=400'
curl -s 'http://$HOST:6666/events?type=attach_done'
```

## Python HTTP helper (from Docker)

```python
import os, urllib.request, json

BASE = f"http://{os.environ.get('Q3IDE_API_HOST','host.docker.internal')}:{os.environ.get('Q3IDE_API_PORT','6666')}"

def api(method, path, body=None, _retries=5):
    data = json.dumps(body).encode() if body else None
    headers = {'Content-Type': 'application/json'} if data else {}
    req = urllib.request.Request(f'{BASE}{path}', data=data, method=method, headers=headers)
    for attempt in range(_retries):
        try:
            with urllib.request.urlopen(req, timeout=300) as r:
                return json.loads(r.read())
        except Exception as e:
            if attempt == _retries - 1: raise
            time.sleep(2)
```

## RCON

Password: `q3idedev666` — set in `baseq3/autoexec.cfg` as `set rconPassword "q3idedev666"`.

Manual test from macOS terminal:
```sh
echo -ne '\xff\xff\xff\xffrcon q3idedev666 status\n' | nc -u 127.0.0.1 27960
```
