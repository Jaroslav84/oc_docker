# OpenCode Docker Sandbox (oc-docker)

A sandboxed Docker environment for running OpenCode with restricted file and internet access.

Starts Docker an macOS if it's not running.

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
- Check if Docker is running and start it if needed
- Launch OpenCode in the sandbox container (named 'oc-docker')
- Mount your ~/Projects directory at /workspace
- Load environment variables from .env

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

- ✅ OpenCode AI installed and ready to use
- ✅ Python 3.11+ with pip
- ✅ Node.js 18+
- ✅ File access restricted to ~/Projects/
- ✅ Internet access (requires Docker permission)
- ✅ .env file support for custom configs
- ✅ Auto-start Docker if not running
- ✅ Security hardening (dropped capabilities, no-new-privileges)