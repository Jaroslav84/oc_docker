# OpenCode Docker Sandbox (oc-docker)

A sandboxed Docker environment for running OpenCode with restricted file access and complete data isolation.

Run with 'ocd' ;)

## Setup

1. Build the Docker image:
   ```bash
   cd ~/Projects/ai/oc_docker
   docker compose build
   ```

2. Install the `ocd` command in your PATH (run manually, requires sudo):
   ```bash
   sudo ln -sf ~/Projects/ai/oc_docker/ocd /usr/local/bin/ocd
   ```

## Usage

Simply type `ocd` in your terminal anywhere:
```bash
ocd
```

This will:
- Auto-start Docker Desktop if it's not running (macOS)
- Launch OpenCode automatically in the sandbox container
- Mount your ~/Projects directory at /root/Projects
- Load environment variables from .env
- Persist all OpenCode data (sessions, API keys, config) to ~/.oc_docker

**Interactive Shell Access:**
- When OpenCode exits (Ctrl+C or exit), you'll get a bash shell prompt
- You can run commands, restart OpenCode, or exit the container
- Type `exit` to leave the container and return to your host shell

## Configuration

Edit `.env` in the oc_docker directory to customize:
- API keys (e.g., OPENAI_API_KEY)
- Environment settings
- Python/Node.js preferences

## Container

- **Image name**: oc-docker:latest
- **Container name**: oc-docker
- **OpenCode version**: 1.0.220

## Features

- ✅ **Auto-start OpenCode** - Launches automatically when container starts
- ✅ **Interactive shell access** - Drop to shell after OpenCode exits, restart it, or run commands
- ✅ **Data persistence** - All sessions, API keys, and config saved to `~/.oc_docker` (survives Docker restarts)
- ✅ **Complete isolation** - Separate from native macOS OpenCode installation (privacy-focused)
- ✅ **Auto-start Docker** - Automatically starts Docker Desktop on macOS if not running
- ✅ OpenCode AI installed and ready to use
- ✅ Python 3.11+ with pip
- ✅ Node.js 18+
- ✅ File access restricted to ~/Projects/
- ✅ Internet access (requires Docker permission)
- ✅ .env file support for custom configs
- ✅ Security hardening (dropped capabilities, no-new-privileges)
- ✅ Custom hostname (oc-docker) for easy identification