#!/usr/bin/env python3
"""
Q3IDE Remote API — Debug Bridge (Docker <-> macOS)
Run on macOS: python3 scripts/remote_api.py
Claude calls:  http://host.docker.internal:6666/...
               ws://host.docker.internal:6666/ws
"""

import base64
import hashlib
import json
import os
import platform
import signal
import socket
import struct
import subprocess
import sys
import threading
import time
import uuid
from collections import deque
from http.server import BaseHTTPRequestHandler
from http.server import ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, urlparse

ROOT = Path(__file__).resolve().parent.parent
LOG_DIR = ROOT / "logs"
BUILD_SCRIPT = ROOT / "scripts" / "build.sh"
PID_FILE = Path("/tmp/q3ide_game.pid")
LOG_MAX_LINES = 2000

def _trim_log(path, max_lines=LOG_MAX_LINES):
    """Keep only the last max_lines lines of a log file."""
    try:
        p = Path(path)
        if not p.exists():
            return
        lines = p.read_text(errors='replace').splitlines(keepends=True)
        if len(lines) > max_lines:
            p.write_text(''.join(lines[-max_lines:]))
    except OSError:
        pass

def _q3_binary():
    """Return (binary_path, build_dir) or (None, None).
    Uses _last_engine_path (set from --path in last build) to find the right build dir.
    Tries native arch first, then x86_64 fallback (build.sh may run under Rosetta)."""
    import sys as _sys
    arch = platform.machine()
    q3e_arch = 'arm64' if arch == 'arm64' else 'x86_64'
    os_name = 'darwin' if _sys.platform == 'darwin' else 'linux'
    engine_dir = Path(_last_engine_path) if Path(_last_engine_path).is_absolute() else ROOT / _last_engine_path
    for try_arch in [q3e_arch, 'x86_64', 'arm64', 'aarch64']:
        build_dir = engine_dir / 'build' / f'release-{os_name}-{try_arch}'
        binary = build_dir / f'quake3e.{try_arch}'
        if binary.exists():
            # Prefer launching from inside the .app bundle so macOS shows "Quake 3 IDE" in Dock/Cmd+Tab
            bundle_bin = build_dir / 'Quake 3 IDE.app' / 'Contents' / 'MacOS' / f'quake3e.{try_arch}'
            if bundle_bin.exists():
                return bundle_bin, build_dir
            return binary, build_dir
    return None, None


def _overlay_binary():
    """Return path to the metal-overlay binary inside q3ide-metal/.build, or None."""
    root = Path(__file__).resolve().parent.parent
    for arch_dir in (root / 'q3ide-metal' / '.build').glob('*/release/metal-overlay.app'):
        candidate = arch_dir / 'Contents' / 'MacOS' / 'metal-overlay'
        if candidate.exists():
            return candidate
    return None


def _hot_reload_overlay():
    """Kill running metal-overlay and spawn the freshly-built one. Quake keeps running."""
    subprocess.run(['pkill', '-x', 'metal-overlay'], capture_output=True)
    time.sleep(0.3)  # let the process exit cleanly before spawning
    bin_path = _overlay_binary()
    if bin_path is None:
        print('[hot-reload] metal-overlay binary not found — skip spawn', flush=True)
        return False
    subprocess.Popen([str(bin_path)], start_new_session=True,
                     stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    print(f'[hot-reload] metal-overlay spawned: {bin_path}', flush=True)
    return True


def _hot_reload_game():
    """Send 'map restart' via rcon so Quake reloads qagame.so without restarting."""
    resp = _send_rcon('map restart')
    print(f'[hot-reload] map restart → {resp!r}', flush=True)
    return resp is not None

_Q3_MUSIC_TRACKS = [
    'music/fla22k_01_intro.wav music/fla22k_01_loop.wav',
    'music/fla22k_02.wav',
    'music/fla22k_03.wav',
    'music/fla22k_04_intro.wav music/fla22k_04_loop.wav',
    'music/fla22k_05.wav',
    'music/fla22k_06.wav',
    'music/sonic1.wav',
    'music/sonic2.wav',
    'music/sonic3.wav',
    'music/sonic4.wav',
    'music/sonic5.wav',
    'music/sonic6.wav',
]

def _random_map():
    """Scan all pk3 files in baseq3 and return a random map name (without .bsp extension)."""
    import zipfile
    import random
    baseq3 = ROOT / 'baseq3'
    maps = set()
    if baseq3.is_dir():
        for pk3 in baseq3.glob('*.pk3'):
            try:
                with zipfile.ZipFile(pk3, 'r') as z:
                    for name in z.namelist():
                        if name.startswith('maps/') and name.endswith('.bsp'):
                            mapname = name[len('maps/'):-len('.bsp')]
                            if mapname:
                                maps.add(mapname)
            except Exception:
                pass
    if not maps:
        return 'q3dm1'
    chosen = random.choice(sorted(maps))
    print(f'[game] Random map pool: {len(maps)} maps → {chosen}', flush=True)
    return chosen


def _build_engine_args(args):
    """Convert API args list (['--level','0','--music','--execute','q3ide attach all; give grappling hook; weapon 10']) to engine args."""
    import random
    engine_args = []
    level = None
    execute = None
    music_on = False
    bots = None
    i = 0
    while i < len(args):
        a = str(args[i])
        if a == '--level' and i + 1 < len(args):
            level = str(args[i + 1])
            if level == 'r':
                level = _random_map()
            elif level.isdigit() or (len(level) <= 2 and level.lstrip('-').isdigit()):
                level = f'q3dm{level}'
            engine_args += ['+devmap', level]
            i += 2
        elif a == '--bots' and i + 1 < len(args):
            bots = int(args[i + 1])
            i += 2
        elif a == '--execute' and i + 1 < len(args):
            execute = str(args[i + 1])
            i += 2
        elif a == '--music':
            music_on = True
            i += 1
        else:
            engine_args.append(a)
            i += 1
    # Random music on q3dm0 only (opt-in via --music flag)
    if music_on and level == 'q3dm0':
        track = random.choice(_Q3_MUSIC_TRACKS)
        music_cmd = f's_musicvolume 0.5; music {track}'
        print(f'[game] Music: {track}', flush=True)
        execute = f'{execute}; {music_cmd}' if execute else music_cmd
    # Always set bot_minplayers explicitly to override any stale q3config.cfg value.
    if bots is not None:
        engine_args += ['+set', 'bot_minplayers', str(bots + 1)]
    else:
        engine_args += ['+set', 'bot_minplayers', '0']
    if execute is not None:
        engine_args += ['+set', 'nextdemo', execute]
    return engine_args

PORT = int(os.environ.get("Q3IDE_API_PORT", 6666))
RCON_PASSWORD = os.environ.get("Q3IDE_RCON_PASSWORD", "q3idedev666")
CLIENT_HOST = os.environ.get("Q3IDE_API_HOST", "host.docker.internal")
RCON_HOST = "127.0.0.1"
RCON_PORT = int(os.environ.get("Q3IDE_RCON_PORT", "27962"))

MASTER_LOG          = LOG_DIR / "q3ide_master.log"
MASTER_LOG_MAX_BYTES = 200 * 1024 * 1024   # 200 MB hard cap

LOG_ALIASES = {
    "master":   MASTER_LOG,                 # ← everything in one place
    "engine":   LOG_DIR / "engine.log",
    "multimon": LOG_DIR / "q3ide_multimon.log",
    "capture":  LOG_DIR / "q3ide_capture.log",
    "build":    LOG_DIR / "build.log",
    "q3ide":    LOG_DIR / "q3ide.log",
    "crash":    LOG_DIR / "crash.log",      # written on every game crash
    "events":   LOG_DIR / "q3ide_events.jsonl",
    # Q3 in-game console log (set logfile 2 in autoexec.cfg)
    "console":  Path.home() / "Library" / "Application Support" / "Quake3" / "baseq3" / "qconsole.log",
}
EVENTS_LOG = LOG_DIR / "q3ide_events.jsonl"

# ── master log ────────────────────────────────────────────────────────────────
# All source logs fed into one aggregated file.  Each line is prefixed [tag].
# Hard cap at 200 MB: when exceeded the oldest ~10 MB is dropped.

_MASTER_SOURCES = [
    ("engine",     LOG_DIR / "engine.log"),
    ("q3ide",      LOG_DIR / "q3ide.log"),
    ("build",      LOG_DIR / "build.log"),
    ("capture",    LOG_DIR / "q3ide_capture.log"),
    ("multimon",   LOG_DIR / "q3ide_multimon.log"),
    ("crash",      LOG_DIR / "crash.log"),
    ("events",     LOG_DIR / "q3ide_events.jsonl"),
]

_master_lock = threading.Lock()


def _master_append(tag: str, line: str) -> None:
    """Append one tagged line to the master log; enforce 200 MB cap."""
    entry = f"[{tag}] {line}\n"
    with _master_lock:
        try:
            with open(MASTER_LOG, 'a') as f:
                f.write(entry)
        except OSError:
            return
        # Size cap: when the file exceeds 200 MB, drop the oldest ~10 MB.
        try:
            size = MASTER_LOG.stat().st_size
            if size > MASTER_LOG_MAX_BYTES:
                keep = MASTER_LOG_MAX_BYTES - 10 * 1024 * 1024  # target ~190 MB
                with open(MASTER_LOG, 'rb') as f:
                    f.seek(size - keep)
                    f.readline()   # align to next newline — don't split a line
                    tail = f.read()
                MASTER_LOG.write_bytes(tail)
        except OSError:
            pass


def _master_watch_source(tag: str, path: Path) -> None:
    """Background thread: tail one source log and feed new lines to master."""
    pos = path.stat().st_size if path.exists() else 0
    while True:
        time.sleep(0.25)
        try:
            if not path.exists():
                continue
            size = path.stat().st_size
            if size < pos:   # log rotated / truncated by a new run
                pos = 0
            if size == pos:
                continue
            with open(path, errors='replace') as f:
                f.seek(pos)
                chunk = f.read()
                pos = f.tell()
            for line in chunk.splitlines():
                if line.strip():
                    _master_append(tag, line)
        except OSError:
            pass


def _start_master_log() -> None:
    """Spawn one watcher thread per source log. Called once at server start."""
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    for tag, path in _MASTER_SOURCES:
        threading.Thread(
            target=_master_watch_source,
            args=(tag, path),
            daemon=True,
            name=f'master-{tag}',
        ).start()

_game_proc = None
_game_start = None
_last_crash = None   # last game_crashed event dict, or None
_DEBUG_MODE = False  # set by --debug flag; prints full crash report to terminal on crash
_build_proc = None
_run_lock = threading.Lock()
_build_start = None
_build_timeout = 120  # seconds; set per-build based on --clean
_last_engine_path = 'quake3e'  # updated from --path in build args; used by _q3_binary()

_SIGNAL_NAMES = {2: 'SIGINT', 3: 'SIGQUIT', 4: 'SIGILL', 6: 'SIGABRT',
                 8: 'SIGFPE', 9: 'SIGKILL', 11: 'SIGSEGV', 13: 'SIGPIPE', 15: 'SIGTERM'}


def _signal_name(sig_num):
    if sig_num is None:
        return None
    return _SIGNAL_NAMES.get(sig_num, f'SIG{sig_num}')

# ── websocket broadcast registry ──────────────────────────────────────────────
_ws_clients = []          # list of send(obj) callables, one per active WS session
_ws_clients_lock = threading.Lock()


def _ws_broadcast(obj):
    """Send obj to all connected WebSocket clients."""
    with _ws_clients_lock:
        targets = list(_ws_clients)
    for send_fn in targets:
        try:
            send_fn(obj)
        except Exception:
            pass

# ── build queue ───────────────────────────────────────────────────────────────
# Each entry: {id, agent_id, args, run_args, auto_run, queued_at,
#              started_at, finished_at, status, returncode}
# status: 'queued' | 'building' | 'done' | 'failed' | 'cancelled'
_queue = deque()          # pending items (not yet started)
_queue_history = []       # completed / cancelled items (last 20)
_queue_lock = threading.Lock()
_queue_event = threading.Event()  # wakes worker when something is enqueued
_queue_current = None     # item currently being built

WS_GUID = b"258EAFA5-E914-47DA-95CA-C5AB0DC85B11"


# ── game helpers ──────────────────────────────────────────────────────────────

def _game_pid():
    global _game_proc
    if _game_proc is not None:
        if _game_proc.poll() is None:
            return _game_proc.pid
        _game_proc = None
    if PID_FILE.exists():
        try:
            pid = int(PID_FILE.read_text().strip())
            os.kill(pid, 0)
            return pid
        except (ValueError, OSError):
            PID_FILE.unlink(missing_ok=True)
    return None


def _game_running():
    if _game_pid() is not None:
        return True
    # Fallback: check if quake3e process exists
    try:
        r = subprocess.run(['pgrep', '-f', 'quake3e'], capture_output=True)
        return r.returncode == 0
    except Exception:
        return False


def _kill_game():
    global _game_proc, _game_start
    killed = False
    # Kill by tracked PID
    pid = _game_pid()
    if pid is not None:
        try:
            os.kill(pid, signal.SIGTERM)
            time.sleep(0.5)
            try:
                os.kill(pid, 0)
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
            killed = True
        except OSError:
            pass
    # Also kill any quake3e / Quake 3 IDE process by name (catches detached child + Finder-launched .app)
    for _pat in ['quake3e', 'Quake 3 IDE']:
        try:
            subprocess.run(['pkill', '-f', _pat], capture_output=True)
            killed = True
        except Exception:
            pass
    # Kill metal-overlay companion (spawned by engine on init; orphaned on crash)
    try:
        subprocess.run(['pkill', '-x', 'metal-overlay'], capture_output=True)
    except Exception:
        pass
    if _game_proc is not None:
        try:
            _game_proc.wait(timeout=3)
        except subprocess.TimeoutExpired:
            pass
        _game_proc = None
    _game_start = None
    PID_FILE.unlink(missing_ok=True)
    return killed


def _kill_build():
    """Kill the running build process and mark the queue entry as cancelled."""
    global _build_proc, _build_start, _queue_current
    killed = False
    with _queue_lock:
        current = _queue_current
    if _build_proc is not None and _build_proc.poll() is None:
        try:
            _build_proc.kill()
            _build_proc.wait(timeout=3)
        except Exception:
            pass
        killed = True
    _build_proc = None
    _build_start = None
    if current is not None:
        with _queue_lock:
            current['status'] = 'cancelled'
            current['finished_at'] = time.time()
            current['returncode'] = -1
            _queue_current = None
            _queue_history.append(current)
            if len(_queue_history) > 20:
                _queue_history.pop(0)
    return killed


def _clear_queue():
    """Drain pending queue entries, cancel the running build, return counts."""
    with _queue_lock:
        n_pending = len(_queue)
        _queue.clear()
    killed_build = _kill_build()
    return {'cleared_pending': n_pending, 'killed_build': killed_build}


def _send_rcon(cmd):
    msg = b'\xff\xff\xff\xff' + f'rcon {RCON_PASSWORD} {cmd}\n'.encode()
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.sendto(msg, (RCON_HOST, RCON_PORT))
        parts = []
        # First packet: wait up to 2s for game to respond
        sock.settimeout(2.0)
        try:
            while True:
                data = sock.recv(65535)
                text = data[4:].decode(errors='replace')
                if text.startswith('print\n'):
                    text = text[6:]
                parts.append(text.rstrip('\n'))
                # Subsequent packets: short gap between UDP datagrams
                sock.settimeout(0.15)
        except socket.timeout:
            pass
        return '\n'.join(parts).strip() if parts else None
    except OSError:
        return None
    finally:
        sock.close()


def _do_run(args=None, agent_id=''):
    """Launch the game binary. Returns dict with ok/pid/error."""
    global _game_proc, _game_start
    if args is None:
        args = ['--level', 'r']
    with _run_lock:
        # Always kill any existing quake3e before launching — prevents double instances
        # when game was started outside the API (e.g. build.sh --run).
        _kill_game()
        subprocess.run(['pkill', '-xf', 'quake3e.*'], capture_output=True)
        subprocess.run(['pkill', '-f', 'Quake 3 IDE'], capture_output=True)
        subprocess.run(['pkill', '-x', 'metal-overlay'], capture_output=True)
        time.sleep(1)
        return _do_run_locked(args, agent_id, _q3_binary())


def _do_run_locked(args, agent_id, binary_info):
    """Inner launch — called only while _run_lock is held."""
    global _game_proc, _game_start
    binary, build_dir = binary_info
    if binary is None:
        return {'ok': False, 'error': 'quake3e binary not found — build first'}
    engine_args = _build_engine_args(args)
    # Disable tty console to prevent backspace/cursor noise in logs
    if '+set' not in ' '.join(engine_args) or 'ttycon' not in ' '.join(engine_args):
        engine_args = ['+set', 'ttycon', '0'] + engine_args
    engine_args = ['+set', 'vm_game', '0', '+set', 'sv_cheats', '1'] + engine_args
    # q3ide defaults: spanning window + Vulkan on discrete GPU (auto-detected by GPU vendor string)
    import subprocess as _sp
    try:
        _gpu = _sp.check_output(['system_profiler', 'SPDisplaysDataType'], text=True, timeout=5)
        _renderer = 'vulkan' if any(v in _gpu for v in ('AMD', 'Radeon', 'NVIDIA', 'GeForce')) else 'opengl1'
    except Exception:
        _renderer = 'opengl1'
    engine_args = ['+set', 'r_multiMonitor', '1', '+set', 'cl_renderer', _renderer] + engine_args
    cmd = [str(binary)] + engine_args
    LOG_DIR.mkdir(parents=True, exist_ok=True)

    # Trim logs to last LOG_MAX_LINES lines — keeps history across sessions
    logs_to_trim = [
        LOG_DIR / 'engine.log',
        LOG_DIR / 'q3ide.log',
        LOG_DIR / 'q3ide_events.jsonl',
        LOG_DIR / 'q3ide_multimon.log',
        LOG_DIR / 'q3ide_capture.log',
        Path.home() / 'Library' / 'Application Support' / 'Quake3' / 'baseq3' / 'qconsole.log',
    ]
    for p in logs_to_trim:
        _trim_log(p)

    engine_log = LOG_DIR / 'engine.log'
    log_fh = open(engine_log, 'a')
    separator = '═' * 60
    log_fh.write(f'\n{separator}\n'
                 f'# session  {time.strftime("%Y-%m-%dT%H:%M:%S")}'
                 f'  agent={agent_id or "unknown"}  args={args}\n'
                 f'{separator}\n')
    log_fh.flush()
    print(f'[game] Launching: {" ".join(cmd)}', flush=True)
    try:
        _game_proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                                      cwd=str(build_dir))
        _game_start = time.time()
        PID_FILE.write_text(str(_game_proc.pid))
        threading.Thread(target=_tee_output,
                         args=(_game_proc, log_fh, '[game] '),
                         kwargs={'on_exit': lambda rc: _on_game_exit(agent_id, rc)},
                         daemon=True).start()
        return {'ok': True, 'pid': _game_proc.pid, 'log': str(engine_log)}
    except Exception as e:
        return {'ok': False, 'error': str(e)}


_CTRL_RE = None

def _strip_ctrl(text):
    """Strip ANSI escape sequences and tty cursor-control chars from Q3 output."""
    import re
    global _CTRL_RE
    if _CTRL_RE is None:
        # Remove: ESC sequences, backspace+space+backspace cursor tricks, lone \r
        _CTRL_RE = re.compile(r'\x1b\[[0-9;]*[A-Za-z]|\x08[^\x08]*|\r')
    return _CTRL_RE.sub('', text)


def _extract_crash_block(q3ide_log_path):
    """Pull the last '=== Q3IDE CRASH REPORT BEGIN ===' block from q3ide.log."""
    try:
        text = Path(q3ide_log_path).read_text(errors='replace')
        begin_marker = '=== Q3IDE CRASH REPORT BEGIN'
        end_marker   = '=== Q3IDE CRASH REPORT END'
        b = text.rfind(begin_marker)
        if b == -1:
            return None
        e = text.find(end_marker, b)
        if e == -1:
            return text[b:].rstrip()
        end_of_line = text.find('\n', e)
        return text[b:end_of_line + 1 if end_of_line != -1 else len(text)].rstrip()
    except OSError:
        return None


def _capture_crash_log(crash):
    """Write a well-structured crash.log that humans and agents can read quickly."""
    try:
        crash_path = LOG_DIR / 'crash.log'
        ts      = crash.get('ts', '?')
        sig     = crash.get('signal_name') or crash.get('signal') or '?'
        rc      = crash.get('returncode', '?')
        uptime  = crash.get('uptime_s', '?')

        W   = 72
        sep = '=' * W
        thin = '-' * W

        lines = [
            f'{sep}\n',
            f'  Q3IDE  CRASH  DUMP\n',
            f'{sep}\n',
            f'\n',
            f'  time     : {ts}\n',
            f'  signal   : {sig}\n',
            f'  exit rc  : {rc}\n',
            f'  uptime   : {uptime}s\n',
            f'\n',
            f'  HOW TO READ THIS FILE:\n',
            f'    1. Look at the CRASH REPORT block — signal + fault address tell you\n',
            f'       what broke (SIGSEGV + NULL = null-pointer dereference).\n',
            f'    2. STACK TRACE shows the call path that led to the crash (#00 = crash site).\n',
            f'    3. Run the SYMBOLICATE command from the build dir to get file:line info.\n',
            f'    4. q3ide.log tail has recent log messages leading up to the crash.\n',
            f'\n',
            f'{sep}\n',
            f'\n',
        ]

        # Best part: the structured crash report written by the C signal handler.
        crash_block = _extract_crash_block(LOG_DIR / 'q3ide.log')
        crash_block_src = 'q3ide.log'
        if not crash_block:
            # crash_block.log is always written by the signal handler regardless of
            # q3ide logging state (e.g. --debug 1 builds with logging enabled anyway,
            # but this is the safety net).
            crash_block = _extract_crash_block(LOG_DIR / 'crash_block.log')
            crash_block_src = 'crash_block.log'
        if crash_block:
            lines.append(f'{thin}\n')
            lines.append(f'CRASH REPORT (from {crash_block_src}):\n')
            lines.append(f'{thin}\n')
            lines.append('\n')
            lines.append(crash_block)
            lines.append('\n\n')
        else:
            lines.append(f'  [!] No structured crash block found in q3ide.log or crash_block.log.\n')
            lines.append(f'      Build may be missing -DQ3IDE_CRASH_REPORT or\n')
            lines.append(f'      the crash happened before Q3IDE_Log_Init().\n\n')

        # Last N lines of q3ide.log for context leading up to the crash.
        lines.append(f'{thin}\n')
        lines.append(f'q3ide.log  (last 80 lines — events leading to crash):\n')
        lines.append(f'{thin}\n')
        lines.append('\n')
        try:
            text = (LOG_DIR / 'q3ide.log').read_text(errors='replace').splitlines(keepends=True)
            lines.extend(text[-80:])
        except OSError as e:
            lines.append(f'(unreadable: {e})\n')
        lines.append('\n')

        # Last N lines of engine.log for VM / renderer errors.
        lines.append(f'{thin}\n')
        lines.append(f'engine.log  (last 40 lines):\n')
        lines.append(f'{thin}\n')
        lines.append('\n')
        try:
            text = (LOG_DIR / 'engine.log').read_text(errors='replace').splitlines(keepends=True)
            lines.extend(text[-40:])
        except OSError as e:
            lines.append(f'(unreadable: {e})\n')
        lines.append('\n')

        lines.append(f'{sep}\n')
        crash_path.write_text(''.join(lines))
        return str(crash_path)
    except Exception as e:
        print(f'[crash] failed to write crash.log: {e}', flush=True)
        return None


def _on_game_exit(agent_id, returncode=0):
    """Called when game process ends. Clears state and notifies all WS clients."""
    global _game_proc, _game_start, _last_crash
    uptime = int(time.time() - _game_start) if _game_start else None
    _game_proc = None
    _game_start = None
    PID_FILE.unlink(missing_ok=True)
    print(f'[game] stopped  agent={agent_id or "unknown"}  uptime={uptime}s  rc={returncode}', flush=True)
    ts = time.strftime('%Y-%m-%dT%H:%M:%S')
    event = {
        'type': 'game_stopped',
        'agent_id': agent_id or 'unknown',
        'uptime_s': uptime,
        'returncode': returncode,
        'ts': ts,
    }
    # Detect crash: non-zero exit or killed by signal (negative returncode on Unix)
    is_crash = returncode is not None and returncode != 0
    if is_crash:
        sig_num = (-returncode) if returncode < 0 else None
        sig_name = _signal_name(sig_num)
        crash = {
            **event,
            'type': 'game_crashed',
            'signal': sig_num,
            'signal_name': sig_name,
        }
        crash_log = _capture_crash_log(crash)
        crash['crash_log'] = crash_log
        _last_crash = crash
        print(f'[game] CRASH  signal={sig_num}({sig_name})  rc={returncode}  uptime={uptime}s', flush=True)
        print(f'[game] crash log: {crash_log}', flush=True)
        # Auto-kill: ensure no zombie quake3e processes linger after a crash
        subprocess.run(['pkill', '-f', 'quake3e'], capture_output=True)
        if _DEBUG_MODE and crash_log:
            time.sleep(0.4)  # let signal handler finish flushing q3ide.log
            try:
                print('\n' + '━' * 72, flush=True)
                print(Path(crash_log).read_text(errors='replace'), flush=True)
                print('━' * 72 + '\n', flush=True)
            except OSError as e:
                print(f'[crash] could not read crash log: {e}', flush=True)
        _ws_broadcast(crash)
    _ws_broadcast(event)


def _tee_output(proc, log_fh, prefix='', on_exit=None):
    """Read proc stdout/stderr, strip tty noise, write to log_fh and sys.stdout."""
    try:
        for line in proc.stdout:
            text = _strip_ctrl(line.decode(errors='replace'))
            if not text.strip():
                continue
            log_fh.write(text if text.endswith('\n') else text + '\n')
            log_fh.flush()
            sys.stdout.write(prefix + text)
            sys.stdout.flush()
    except Exception:
        pass
    finally:
        log_fh.close()
        if on_exit:
            on_exit(proc.returncode if proc.returncode is not None else proc.wait())


def _enqueue_build(args, run_args, auto_run, agent_id=''):
    """Add a build request to the queue. Returns the queue entry dict."""
    entry = {
        'id': str(uuid.uuid4())[:8],
        'agent_id': agent_id or '',
        'args': [str(a) for a in args],
        'run_args': [str(a) for a in run_args],
        'auto_run': auto_run,
        'queued_at': time.time(),
        'started_at': None,
        'finished_at': None,
        'status': 'queued',
        'returncode': None,
    }
    with _queue_lock:
        _queue.append(entry)
    _queue_event.set()
    return entry


def _queue_worker():
    """Background thread: process build queue one item at a time."""
    global _build_proc, _build_start, _build_timeout, _queue_current, _last_engine_path
    while True:
        _queue_event.wait()
        _queue_event.clear()
        while True:
            with _queue_lock:
                if not _queue:
                    break
                entry = _queue.popleft()

            # Kill any running build first
            if _build_proc is not None and _build_proc.poll() is None:
                try:
                    print(f'[queue] Killing running build for new item {entry["id"]}', flush=True)
                except BlockingIOError:
                    pass
                _build_proc.terminate()
                try:
                    _build_proc.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    _build_proc.kill()
                _build_proc = None

            # Mark started
            with _queue_lock:
                entry['status'] = 'building'
                entry['started_at'] = time.time()
                _queue_current = entry

            # Track --path so _q3_binary() finds the right build dir
            if '--path' in entry['args']:
                idx = entry['args'].index('--path')
                if idx + 1 < len(entry['args']):
                    _last_engine_path = entry['args'][idx + 1]

            is_clean = '--clean' in entry['args']
            args_set = set(entry['args'])
            if is_clean:
                timeout = 600
            elif '--game-only' in args_set:
                timeout = 60   # qagame only: ~5s compile
            elif '--editor-only' in args_set:
                timeout = 180  # Rust incremental: ~10s (cold: ~60s)
            elif '--overlay-only' in args_set:
                timeout = 180  # Swift build: ~30s (cold) / ~10s (incremental)
            elif '--engine-only' in args_set:
                timeout = 300
            else:
                timeout = 900  # full build includes Rust+Swift dylib: can take 10-15 min
            _build_timeout = timeout

            cmd = ['bash', str(BUILD_SCRIPT)] + entry['args'] + ['--queue-id', entry['id']]
            LOG_DIR.mkdir(parents=True, exist_ok=True)
            build_log = LOG_DIR / 'build.log'
            _trim_log(build_log)
            log_fh = open(build_log, 'a')
            separator = '═' * 60
            log_fh.write(f'\n{separator}\n'
                         f'# session  {time.strftime("%Y-%m-%dT%H:%M:%S")}'
                         f'  agent={entry["agent_id"] or "unknown"}'
                         f'  queue_id={entry["id"]}  args={entry["args"]}\n'
                         f'{separator}\n')
            log_fh.flush()
            map_label = ' '.join(entry['run_args']) if entry['auto_run'] else 'no-run'
            try:
                print(f'[queue] Starting build {entry["id"]} (agent={entry["agent_id"]}) → {map_label}: {" ".join(cmd)}', flush=True)
            except BlockingIOError:
                pass  # stdout pipe full — non-fatal, build still proceeds

            _build_proc = subprocess.Popen(
                cmd, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, cwd=str(ROOT),
                start_new_session=True)  # new session → own pgid → kill kills all children
            _build_start = time.time()
            threading.Thread(target=_tee_output, args=(_build_proc, log_fh, '[build] '),
                             daemon=True).start()

            # Wait for completion (with timeout).
            # Snapshot proc — _build_proc may be set to None by _kill_build() on another thread.
            proc = _build_proc
            deadline = time.time() + timeout
            while time.time() < deadline:
                if proc is None or proc.poll() is not None:
                    break
                time.sleep(0.5)

            if proc is not None and proc.poll() is None:
                try:
                    print(f'[queue] Build {entry["id"]} TIMEOUT ({timeout}s), killing.', flush=True)
                except BlockingIOError:
                    pass
                try:
                    os.killpg(os.getpgid(proc.pid), signal.SIGKILL)
                except OSError:
                    proc.kill()
                try:
                    proc.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    pass

            rc = proc.returncode if proc is not None else -1
            with _queue_lock:
                entry['returncode'] = rc
                entry['finished_at'] = time.time()
                entry['status'] = 'done' if rc == 0 else 'failed'
                _queue_current = None
                _queue_history.append(entry)
                if len(_queue_history) > 20:
                    _queue_history.pop(0)

            if rc == 0:
                args_set = set(entry['args'])
                if '--overlay-only' in args_set:
                    # Hot-reload: kill + relaunch overlay, Quake keeps running
                    threading.Thread(target=_hot_reload_overlay, daemon=True).start()
                elif '--game-only' in args_set:
                    # Hot-reload: map restart reloads qagame.so, Quake keeps running
                    threading.Thread(target=_hot_reload_game, daemon=True).start()
                elif '--editor-only' in args_set:
                    # Editor is a separate process — build only, no Quake interaction
                    print(f'[queue] Build {entry["id"]} OK — editor built, Quake untouched', flush=True)
                elif '--engine-only' in args_set or '--fast' in args_set:
                    # Compile-only check — Quake is never killed or relaunched.
                    # User must call /run explicitly to test the new binary.
                    try:
                        print(f'[queue] Build {entry["id"]} OK — engine-only, Quake untouched', flush=True)
                    except BlockingIOError:
                        pass
                elif entry['auto_run']:
                    if _game_running():
                        # Game already running — build was just a compile check; don't kill it
                        try:
                            print(f'[queue] Build {entry["id"]} OK — game already running, skipping relaunch', flush=True)
                        except BlockingIOError:
                            pass
                    else:
                        try:
                            print(f'[queue] Build {entry["id"]} OK — launching game ({" ".join(entry["run_args"])})…', flush=True)
                        except BlockingIOError:
                            pass
                        _do_run(entry['run_args'], agent_id=entry['agent_id'])
            if rc != 0:
                try:
                    print(f'[queue] Build {entry["id"]} FAILED (rc={rc})', flush=True)
                except BlockingIOError:
                    pass


def _tail_log(path, n=100):
    path = Path(path)
    if not path.exists():
        return None
    lines = path.read_text(errors='replace').splitlines()
    return '\n'.join(lines[-n:])


def _find_macos_crash_reports(n=5):
    """Return up to n most-recent macOS crash reports for Quake3e.

    macOS writes .crash (text) and .ips (JSON, macOS 12+) files to:
      ~/Library/Logs/DiagnosticReports/   — user crashes
      /Library/Logs/DiagnosticReports/    — system crashes
    File names match: quake3e* or Quake3e* (case-insensitive).
    Returns list of dicts: {path, name, mtime, content}.
    """
    base_dirs = [
        Path.home() / 'Library' / 'Logs' / 'DiagnosticReports',
        Path('/Library/Logs/DiagnosticReports'),
    ]
    search_dirs = []
    for d in base_dirs:
        search_dirs.append(d)
        search_dirs.append(d / 'Retired')  # macOS moves older reports here
    found = []
    for d in search_dirs:
        if not d.exists():
            continue
        for ext in ('*.crash', '*.ips', '*.diag'):
            for f in d.glob(ext):
                name_lower = f.name.lower()
                if 'quake3e' in name_lower or 'quake 3' in name_lower:
                    found.append(f)
    # sort newest first
    found.sort(key=lambda f: f.stat().st_mtime, reverse=True)
    results = []
    for f in found[:n]:
        try:
            content = f.read_text(errors='replace')
        except OSError as e:
            content = f'(unreadable: {e})'
        results.append({
            'path': str(f),
            'name': f.name,
            'mtime': f.stat().st_mtime,
            'content': content,
        })
    return results


# ── websocket helpers ─────────────────────────────────────────────────────────

def _ws_accept_key(key_b64):
    digest = hashlib.sha1(key_b64.encode() + WS_GUID).digest()
    return base64.b64encode(digest).decode()


def _ws_send(sock, data):
    """Send a text frame (server→client, no masking)."""
    if isinstance(data, str):
        data = data.encode()
    n = len(data)
    if n < 126:
        header = bytes([0x81, n])
    elif n < 65536:
        header = bytes([0x81, 126]) + struct.pack('>H', n)
    else:
        header = bytes([0x81, 127]) + struct.pack('>Q', n)
    sock.sendall(header + data)


def _ws_recv(sock):
    """Read one frame from client (always masked). Returns bytes or None on close/error."""
    def _read(n):
        buf = b''
        while len(buf) < n:
            chunk = sock.recv(n - len(buf))
            if not chunk:
                raise ConnectionError
            buf += chunk
        return buf

    try:
        h = _read(2)
        opcode = h[0] & 0x0F
        if opcode == 8:  # close
            return None
        masked = bool(h[1] & 0x80)
        length = h[1] & 0x7F
        if length == 126:
            length = struct.unpack('>H', _read(2))[0]
        elif length == 127:
            length = struct.unpack('>Q', _read(8))[0]
        mask = _read(4) if masked else b'\x00\x00\x00\x00'
        payload = _read(length)
        return bytes(b ^ mask[i % 4] for i, b in enumerate(payload))
    except (ConnectionError, OSError):
        return None


# ── websocket session ─────────────────────────────────────────────────────────

def _run_ws_session(sock, log_names):
    """
    Runs in its own thread (one per WS client).
    - Streams new lines from requested logs as JSON.
    - Accepts {cmd} messages → RCON → sends response.
    - Sends {type:status} every 5s.
    """
    alive = [True]
    send_lock = threading.Lock()

    def send(obj):
        try:
            with send_lock:
                _ws_send(sock, json.dumps(obj))
        except OSError:
            alive[0] = False

    # ── log tail threads ──────────────────────────────────────────────────────
    def tail_log(name, path):
        path = Path(path)
        # catchup: send last 30 lines
        content = _tail_log(path, 30)
        if content:
            for line in content.splitlines():
                send({'type': 'log', 'file': name, 'line': line})
        # watch for new lines
        pos = path.stat().st_size if path.exists() else 0
        while alive[0]:
            time.sleep(0.15)
            if not path.exists():
                continue
            size = path.stat().st_size
            if size <= pos:
                if size < pos:  # log was truncated (new run)
                    pos = 0
                continue
            try:
                with open(path, errors='replace') as f:
                    f.seek(pos)
                    chunk = f.read()
                    pos = f.tell()
                for line in chunk.splitlines():
                    if line:
                        send({'type': 'log', 'file': name, 'line': line})
            except OSError:
                pass

    for name in log_names:
        if name in LOG_ALIASES:
            t = threading.Thread(target=tail_log, args=(name, LOG_ALIASES[name]), daemon=True)
            t.start()

    # ── status heartbeat ──────────────────────────────────────────────────────
    def status_loop():
        while alive[0]:
            time.sleep(5)
            pid = _game_pid()
            send({
                'type': 'status',
                'running': pid is not None,
                'pid': pid,
                'uptime_s': int(time.time() - _game_start) if pid and _game_start else None,
            })

    threading.Thread(target=status_loop, daemon=True).start()

    # ── recv loop (RCON commands) ─────────────────────────────────────────────
    with _ws_clients_lock:
        _ws_clients.append(send)
    send({'type': 'hello', 'logs': log_names, 'rcon_port': RCON_PORT})
    try:
        while alive[0]:
            data = _ws_recv(sock)
            if data is None:
                break
            try:
                msg = json.loads(data)
            except json.JSONDecodeError:
                continue
            cmd = msg.get('cmd', '').strip()
            if cmd:
                if not _game_running():
                    send({'type': 'rcon', 'cmd': cmd, 'error': 'game not running'})
                else:
                    resp = _send_rcon(cmd)
                    send({'type': 'rcon', 'cmd': cmd,
                          'response': resp, 'ok': resp is not None})

    finally:
        alive[0] = False
        with _ws_clients_lock:
            try:
                _ws_clients.remove(send)
            except ValueError:
                pass
        try:
            sock.close()
        except OSError:
            pass


# ── HTTP request handler ──────────────────────────────────────────────────────

class Handler(BaseHTTPRequestHandler):
    @staticmethod
    def _caller_proc(port):
        """Best-effort: find process name+pid connected to our port on localhost."""
        try:
            r = subprocess.run(
                ['lsof', '-i', f'TCP:{port}', '-n', '-P', '-F', 'pcn'],
                capture_output=True, text=True, timeout=1
            )
            # lsof -F output: p<pid>\nc<cmd>\nn<addr>
            pid, cmd = None, None
            for line in r.stdout.splitlines():
                if line.startswith('p'):
                    pid = line[1:]
                    cmd = None
                elif line.startswith('c'):
                    cmd = line[1:]
                elif line.startswith('n') and '->' in line and str(PORT) in line:
                    if cmd and cmd not in ('Python', 'remote_ap') and pid:
                        return f'{cmd}({pid})'
        except Exception:
            pass
        return None

    def log_message(self, fmt, *args):
        try:
            ip = self.client_address[0]
            cmd = getattr(self, 'command', '???')
            path = getattr(self, 'path', '???')
            # self.headers may not exist if parse_request() failed (bad HTTP version etc.)
            hdrs = getattr(self, 'headers', None)
            if hdrs is None:
                print(f'[api] {cmd} {path}  agent=unknown (bad request)', flush=True)
                return
            agent = hdrs.get('X-Agent-ID', '')
            if not agent:
                # Fall back to process name for localhost callers without X-Agent-ID
                if ip in ('127.0.0.1', '::1'):
                    agent = self._caller_proc(PORT) or hdrs.get('User-Agent', '') or 'unknown'
                else:
                    agent = hdrs.get('User-Agent', '') or 'unknown'
            print(f'[api] {cmd} {path}  agent={agent}', flush=True)
        except BlockingIOError:
            pass
        except Exception:
            pass

    def _send(self, code, body):
        data = json.dumps(body, indent=2).encode()
        self.send_response(code)
        self.send_header('Content-Type', 'application/json')
        self.send_header('Content-Length', str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _read_body(self):
        length = int(self.headers.get('Content-Length', 0))
        if length == 0:
            return {}
        try:
            return json.loads(self.rfile.read(length))
        except json.JSONDecodeError:
            return {}

    def do_GET(self):
        parsed = urlparse(self.path)
        path = parsed.path
        qs = parse_qs(parsed.query)

        # ── WebSocket upgrade ─────────────────────────────────────────────────
        if path == '/ws' and self.headers.get('Upgrade', '').lower() == 'websocket':
            key = self.headers.get('Sec-WebSocket-Key', '')
            self.send_response(101)
            self.send_header('Upgrade', 'websocket')
            self.send_header('Connection', 'Upgrade')
            self.send_header('Sec-WebSocket-Accept', _ws_accept_key(key))
            self.end_headers()
            self.wfile.flush()
            logs = qs.get('logs', ['engine,multimon'])[0].split(',')
            _run_ws_session(self.connection, logs)  # blocks until client disconnects
            return

        if path == '/lint':
            self._handle_lint(fix=False, extra_args=[])
        elif path in ('/build/status', '/build_status'):
            qid = (qs.get('queue_id') or qs.get('id', [None]))[0]
            wait_s = int((qs.get('wait') or ['0'])[0])
            self._handle_build_status(queue_id=qid, wait_s=wait_s)
        elif path == '/queue':
            self._handle_queue_list()
        elif path in ('/', '/status'):
            pid = _game_pid()
            with _queue_lock:
                cur = _queue_current
                pending = len(_queue)
            self._send(200, {
                'ok': True,
                'running': pid is not None,
                'pid': pid,
                'uptime_s': int(time.time() - _game_start) if pid and _game_start else None,
                'last_crash': _last_crash,
                'build': {
                    'active': cur is not None,
                    'queue_id': cur['id'] if cur else None,
                    'status': cur['status'] if cur else None,
                    'pending': pending,
                },
            })
        elif path == '/settings':
            result = subprocess.run(
                ['bash', str(ROOT / 'scripts' / 'settings.sh')],
                capture_output=True, text=True, cwd=str(ROOT))
            self._send(200, {'ok': True, 'output': result.stdout + result.stderr})
        elif path == '/crash':
            crash = _last_crash
            result = {'ok': True, 'crash': crash}
            if crash:
                block = _extract_crash_block(LOG_DIR / 'q3ide.log') or \
                        _extract_crash_block(LOG_DIR / 'crash_block.log')
                if block:
                    result['crash_block'] = block
                result['q3ide_tail'] = _tail_log(LOG_DIR / 'q3ide.log', 30) or ''
            self._send(200, result)
        elif path == '/macoscrash':
            # macOS DiagnosticReports — .crash/.ips files written by the OS crash reporter.
            # Falls back to our own crash block from q3ide.log when no OS report exists.
            # ?n=N  — return N most recent reports (default 1, max 10)
            n_req = min(int((qs.get('n') or ['1'])[0]), 10)
            reports = _find_macos_crash_reports(n_req)
            # Fallback: inject our own crash block as a synthetic report
            if not reports:
                block = _extract_crash_block(LOG_DIR / 'q3ide.log') or \
                        _extract_crash_block(LOG_DIR / 'crash_block.log')
                if block:
                    reports = [{
                        'path': str(LOG_DIR / 'q3ide.log'),
                        'name': 'q3ide_crash_block (no macOS report — throttled)',
                        'mtime': (LOG_DIR / 'q3ide.log').stat().st_mtime,
                        'content': block,
                    }]
            self._send(200, {
                'ok': True,
                'count': len(reports),
                'reports': reports,
            })
        elif path == '/events':
            self._handle_events(qs)
        elif path == '/logs':
            alias = (qs.get('file') or qs.get('log') or ['engine'])[0]
            n = max(400, int((qs.get('n') or qs.get('tail') or ['400'])[0]))
            grep = (qs.get('grep') or qs.get('q') or [None])[0]
            log_path = LOG_ALIASES.get(alias)
            if log_path is None:
                self._send(404, {'error': f'unknown: {alias}', 'available': list(LOG_ALIASES)})
                return
            if log_path != MASTER_LOG:
                _trim_log(log_path)
            content = _tail_log(log_path, n)
            if content is None:
                self._send(404, {'error': f'log not found: {log_path}'})
                return
            if grep:
                lines = [l for l in content.splitlines() if grep.lower() in l.lower()]
                content = '\n'.join(lines)
            self._send(200, {'file': alias, 'lines': n, 'grep': grep, 'content': content})
        else:
            self._send(404, {'error': 'not found'})

    def do_DELETE(self):
        path = urlparse(self.path).path
        # DELETE /queue/<id>  — cancel a queued (not yet started) item
        if path.startswith('/queue/'):
            qid = path[len('/queue/'):]
            with _queue_lock:
                for i, entry in enumerate(_queue):
                    if entry['id'] == qid:
                        entry['status'] = 'cancelled'
                        entry['finished_at'] = time.time()
                        del _queue[i]
                        _queue_history.append(entry)
                        if len(_queue_history) > 20:
                            _queue_history.pop(0)
                        self._send(200, {'ok': True, 'cancelled': qid})
                        return
                # Check if it's the running build
                if _queue_current and _queue_current['id'] == qid:
                    self._send(409, {'error': 'build already started — use POST /stop to kill game'})
                    return
            self._send(410, {'error': f'queue_id {qid!r} not found — api restarted or already done', 'gone': True})
        else:
            self._send(404, {'error': 'not found'})

    def do_POST(self):
        path = urlparse(self.path).path
        body = self._read_body()
        if path == '/lint':
            self._handle_lint(fix=body.get('fix', False), extra_args=body.get('args', []))
        elif path == '/build':
            self._handle_build(body)
        elif path == '/run':
            self._handle_run(body)
        elif path == '/stop':
            self._handle_stop()
        elif path in ('/queue/clear', '/build/cancel'):
            result = _clear_queue()
            print(f'[api] queue/clear: {result}', flush=True)
            self._send(200, {'ok': True, **result})
        elif path == '/kill':
            # Kill everything: game + build + clear queue
            game_killed = _kill_game()
            queue_result = _clear_queue()
            print(f'[api] kill: game={game_killed} {queue_result}', flush=True)
            self._send(200, {'ok': True, 'game_killed': game_killed, **queue_result})
        elif path == '/console':
            self._handle_console(body)
        elif path == '/symbolicate':
            self._handle_symbolicate(body)
        elif path == '/send2trash':
            self._handle_send2trash(body)
        else:
            self._send(404, {'error': 'not found'})

    def _handle_build(self, body):
        args = body.get('args', [])
        run_args = body.get('run_args', ['--level', 'r'])
        auto_run = body.get('auto_run', True)
        agent_id = body.get('agent_id', '')
        entry = _enqueue_build(args, run_args, auto_run, agent_id)
        with _queue_lock:
            position = list(_queue).index(entry) + 1 if entry in _queue else 0
        self._send(200, {
            'ok': True,
            'queue_id': entry['id'],
            'agent_id': entry['agent_id'],
            'position': position,
            'queued_at': entry['queued_at'],
            'queued_at_iso': time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(entry['queued_at'])),
            'log': 'build',
        })

    def _handle_build_status(self, queue_id=None, wait_s=0):
        def _find_entry(qid):
            with _queue_lock:
                cur = _queue_current
                pending = list(_queue)
                history = list(_queue_history)
            if cur and cur['id'] == qid:
                return cur
            for e in pending + history:
                if e['id'] == qid:
                    return e
            return None

        # Long-poll: block until build completes or wait_s expires.
        # Agents use ?wait=30 to avoid sleep loops — no Docker timeout risk.
        if queue_id and wait_s > 0:
            deadline = time.time() + wait_s
            while time.time() < deadline:
                entry = _find_entry(queue_id)
                if entry is None:
                    self._send(200, {'ok': True, 'done': True, 'gone': True,
                                     'status': 'gone', 'returncode': None, 'timed_out': False,
                                     'error': f'queue_id {queue_id!r} not found — stale (api restarted)'})
                    return
                if entry['status'] in ('done', 'failed', 'cancelled'):
                    result = self._fmt_entry(entry)
                    result['timed_out'] = False
                    result['log_tail'] = _tail_log(LOG_DIR / 'build.log', 40) or ''
                    self._send(200, result)
                    return
                time.sleep(0.5)
            # Timed out — return current status; agent should retry immediately
            entry = _find_entry(queue_id)
            if entry:
                result = self._fmt_entry(entry)
                result['timed_out'] = True
            else:
                result = {'status': 'unknown', 'timed_out': True}
            self._send(200, result)
            return

        with _queue_lock:
            current = _queue_current
            pending = list(_queue)
            history = list(_queue_history)
        # Look up specific id
        if queue_id:
            entry = _find_entry(queue_id)
            if entry is None:
                # Return 200 with done+gone so polling loops exit normally.
                # 410 works correctly but agents that catch HTTPError keep retrying.
                self._send(200, {'ok': True, 'done': True, 'gone': True,
                                 'status': 'gone', 'returncode': None,
                                 'error': f'queue_id {queue_id!r} not found — stale (api restarted)'})
                return
            self._send(200, self._fmt_entry(entry))
            return
        self._send(200, {
            'current': self._fmt_entry(current) if current else None,
            'queue_depth': len(pending),
        })

    @staticmethod
    def _fmt_entry(e):
        now = time.time()
        out = {k: e[k] for k in ('id', 'agent_id', 'args', 'status', 'returncode')}
        out['queued_at_iso'] = time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(e['queued_at']))
        if e['started_at']:
            out['started_at_iso'] = time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(e['started_at']))
            out['elapsed_s'] = int((e['finished_at'] or now) - e['started_at'])
        if e['finished_at']:
            out['finished_at_iso'] = time.strftime('%Y-%m-%dT%H:%M:%S', time.localtime(e['finished_at']))
        return out

    def _handle_run(self, body):
        args = body.get('args', ['--level', 'r'])
        agent_id = body.get('agent_id', '')
        result = _do_run(args, agent_id=agent_id)
        if result.get('ok'):
            self._send(200, result)
        else:
            self._send(500, result)

    def _handle_stop(self):
        if not _game_running():
            self._send(200, {'ok': True, 'msg': 'not running'})
            return
        self._send(200, {'ok': _kill_game(), 'msg': 'stopped'})

    def _handle_symbolicate(self, body):
        """POST /symbolicate {"addrs": ["0x10bf87bef", ...], "binary": optional, "arch": optional, "load_addr": optional}
        Runs xcrun atos on macOS host. Returns {addr: "symbol (file:line)"} map.
        load_addr: the actual load address printed in the crash report as 'binary @'.
                   Required for ASLR — without it atos returns addresses unchanged."""
        addrs = body.get('addrs', [])
        if not addrs:
            self._send(400, {'error': 'missing addrs'}); return
        binary = body.get('binary')
        arch   = body.get('arch')
        load_addr = body.get('load_addr')  # ASLR slide — from 'binary @' in crash report
        if not binary:
            bin_path, build_dir = _q3_binary()
            if bin_path is None:
                self._send(404, {'error': 'no binary found — build first'}); return
            binary = str(bin_path)
            arch = arch or ('arm64' if platform.machine() == 'arm64' else 'x86_64')
        else:
            arch = arch or ('arm64' if platform.machine() == 'arm64' else 'x86_64')
        cmd = ['xcrun', 'atos', '-o', binary, '-arch', arch]
        if load_addr:
            cmd += ['-l', str(load_addr)]
        cmd += list(addrs)
        try:
            r = subprocess.run(cmd, capture_output=True, text=True, timeout=30)
            out_lines = r.stdout.strip().splitlines()
            if len(out_lines) == len(addrs):
                symbols = dict(zip(addrs, out_lines))
            else:
                symbols = {'raw': r.stdout.strip()}
            self._send(200, {'ok': r.returncode == 0, 'symbols': symbols,
                             'binary': binary, 'arch': arch, 'stderr': r.stderr.strip() or None})
        except FileNotFoundError:
            self._send(503, {'error': 'xcrun not found — not macOS or Xcode not installed'})
        except subprocess.TimeoutExpired:
            self._send(504, {'error': 'symbolicate timeout (30s)'})
        except Exception as e:
            self._send(500, {'error': str(e)})

    def _handle_send2trash(self, body):
        """POST /send2trash {"path": "/abs/or/~/rel/path"} — safely move file to macOS Trash."""
        raw = body.get('path', '').strip()
        if not raw:
            self._send(400, {'error': 'missing path'}); return
        p = Path(raw).expanduser()
        if not p.exists():
            self._send(404, {'error': f'not found: {p}'}); return
        try:
            r = subprocess.run(['trash', str(p)], capture_output=True, text=True, timeout=10)
            if r.returncode == 0:
                self._send(200, {'ok': True, 'trashed': str(p), 'method': 'trash'}); return
            self._send(500, {'error': r.stderr.strip() or 'trash failed'})
        except FileNotFoundError:
            self._send(503, {'error': 'trash CLI not found — run: brew install trash'})
        except Exception as e:
            self._send(500, {'error': str(e)})

    def _handle_lint(self, fix=False, extra_args=None):
        lint_script = ROOT / 'scripts' / 'lint.sh'
        extra_args = [a for a in (extra_args or []) if isinstance(a, str)]
        try:
            if fix:
                import glob as _glob
                q3ide_dir = ROOT / 'quake3e' / 'code' / 'q3ide'
                files = _glob.glob(str(q3ide_dir / '*.c')) + _glob.glob(str(q3ide_dir / '*.h'))
                fix_result = subprocess.run(
                    ['clang-format', '-i'] + files,
                    capture_output=True, text=True, timeout=60, cwd=str(ROOT)
                )
                if fix_result.returncode != 0:
                    self._send(500, {'error': 'clang-format -i failed', 'stderr': fix_result.stderr})
                    return
            result = subprocess.run(
                ['sh', str(lint_script)] + extra_args,
                capture_output=True, text=True, timeout=300, cwd=str(ROOT)
            )
            output = result.stdout + result.stderr
            ok = result.returncode == 0
            try:
                print(output, flush=True)
            except BlockingIOError:
                pass
            self._send(200, {'ok': ok, 'fixed': fix, 'returncode': result.returncode, 'output': output})
        except FileNotFoundError:
            self._send(503, {'error': 'lint.sh not found'})
        except subprocess.TimeoutExpired:
            self._send(504, {'error': 'lint timeout'})
        except Exception as e:
            self._send(500, {'error': str(e)})

    def _handle_queue_list(self):
        with _queue_lock:
            current = _queue_current
            pending = list(_queue)
            history = list(_queue_history)
        self._send(200, {
            'current': self._fmt_entry(current) if current else None,
            'pending': [self._fmt_entry(e) for e in pending],
            'history': [self._fmt_entry(e) for e in reversed(history)],
        })

    def _handle_events(self, qs):
        """GET /events?type=attach_done&since=1709938642&n=200&pid=<pid>"""
        type_filter = (qs.get('type') or [None])[0]
        since = float((qs.get('since') or ['0'])[0])
        n = int((qs.get('n') or ['200'])[0])
        pid_filter = (qs.get('pid') or [None])[0]
        if pid_filter:
            try:
                pid_filter = int(pid_filter)
            except ValueError:
                pid_filter = None
        if not EVENTS_LOG.exists():
            self._send(200, {'events': [], 'count': 0})
            return
        events = []
        try:
            with open(EVENTS_LOG, errors='replace') as f:
                for line in f:
                    line = line.strip()
                    if not line:
                        continue
                    try:
                        evt = json.loads(line)
                        if type_filter and evt.get('type') != type_filter:
                            continue
                        if since and evt.get('ts', 0) < since:
                            continue
                        if pid_filter and evt.get('pid') != pid_filter:
                            continue
                        events.append(evt)
                    except json.JSONDecodeError:
                        pass
        except OSError as e:
            self._send(500, {'error': str(e)})
            return
        tail = events[-n:]
        self._send(200, {'events': tail, 'count': len(tail), 'total': len(events)})

    def _handle_console(self, body):
        cmd = body.get('cmd', '').strip()
        if not cmd:
            self._send(400, {'error': 'missing cmd'})
            return
        if not _game_running():
            self._send(503, {'error': 'game not running'})
            return
        resp = _send_rcon(cmd)
        if resp is None:
            self._send(504, {'ok': False, 'cmd': cmd, 'error': 'RCON timeout — game not responding'})
            return
        self._send(200, {'ok': True, 'cmd': cmd, 'response': resp or '(empty)'})


# ── main ──────────────────────────────────────────────────────────────────────

def main():
    global _DEBUG_MODE
    LOG_DIR.mkdir(parents=True, exist_ok=True)
    _start_master_log()
    # Parse CLI flags
    build_args = []
    if '--engine-only' in sys.argv[1:]:
        build_args.append('--engine-only')
    if '--clean' in sys.argv[1:]:
        build_args.append('--clean')
    if '--debug' in sys.argv[1:]:
        _DEBUG_MODE = True
    # Start build queue worker
    threading.Thread(target=_queue_worker, daemon=True, name='build-queue').start()
    server = ThreadingHTTPServer(('0.0.0.0', PORT), Handler)
    print(f'Q3IDE Remote API  http://0.0.0.0:{PORT}', flush=True)
    print(f'  WebSocket:  ws://{CLIENT_HOST}:{PORT}/ws?logs=engine,multimon,capture', flush=True)
    print(f'  From Docker: http://{CLIENT_HOST}:{PORT}/', flush=True)
    print(f'  RCON: {RCON_HOST}:{RCON_PORT}  password={RCON_PASSWORD!r}', flush=True)
    if _DEBUG_MODE:
        print(f'  [debug] crash auto-print ON — full stack trace will print on crash', flush=True)
    if build_args:
        print(f'  Auto-build: {build_args} → run --level r', flush=True)
        _enqueue_build(build_args, run_args=['--level', 'r'], auto_run=True, agent_id='cli')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print('\nShutting down.', flush=True)
        server.server_close()
        sys.exit(0)


if __name__ == '__main__':
    main()
