# 🐳 llm-docker

![Version](https://img.shields.io/badge/Version-v1.1-blue?style=for-the-badge)
![AI Powered](https://img.shields.io/badge/AI-Powered-FF4B4B?style=for-the-badge&logo=openai&logoColor=white)
![Claude Code](https://img.shields.io/badge/Claude_Code-Supported-D1913C?style=for-the-badge&logo=anthropic&logoColor=white)
![Docker](https://img.shields.io/badge/Docker-Isolated-2496ED?style=for-the-badge&logo=docker&logoColor=white)
![Security](https://img.shields.io/badge/Security-Sandboxed-8A2BE2?style=for-the-badge&logo=lock&logoColor=white)
![Shell](https://img.shields.io/badge/Shell-Automated-4EAA25?style=for-the-badge&logo=gnu-bash&logoColor=white)

![llm-docker Logo](llm_docker_logo.png)

---

## 📘 About

**llm-docker** provides a secure, sandboxed environment for running **OpenCode** and **Claude Code** with complete data isolation and privacy on macOS.

Stop worrying about local dependencies or data leaks. Run your AI agents in a controlled Docker environment that automatically manages keys, configs, and persistence.

![llm-docker Screenshot](screenshot.png)

---

## 🚀 Quick Start

Run these commands instead of the native tools:

*   **OpenCode**: `ocd`
*   **Claude Code**: `cld`

Simple as that. The environment handles the rest.

You can use `ocd ./my-path` too with params `ocd ./my-path -c`

---

## 🛠️ Setup Procedure

### 1. Create `.env` File

Create a `.env` file in the llm_docker directory with your API keys and settings:

```bash
cat > .env << 'EOF'
# ============================================
# OpenCode API Keys
# ============================================
OPENAI_API_KEY=sk-your-openai-key-here
ZAI_API_KEY=your-zai-key-here

# ============================================
# Claude Code API Keys
# ============================================
ANTHROPIC_API_KEY=sk-ant-your-anthropic-key-here
CLAUDE_CODE_MAX_OUTPUT_TOKENS=48000
EOF
```

### 2. Configure OpenCode Settings

Edit `opencode.config.jsonc` to customize your OpenCode model preferences. 

```jsonc
{
  "model": "openai/gpt-5",
  "small_model": "zai/glm-4.5-flash",
  "agent": {
    "build": {
      "model": "openai/gpt-5"
    },
    // ... more agent configurations. I left a 6 agent madness for you ;)
  }
}
```

### 3. Verify Docker Setup

Ensure Docker is installed and accessible:

```bash
docker --version
docker compose version
```

### 4. 🚀 Installation and command setup

```bash
docker compose build
sudo ln -sf $(pwd)/ocd /usr/local/bin/ocd
sudo ln -sf $(pwd)/cld /usr/local/bin/cld
```

## ⚡ Running

### OpenCode

```bash
ocd
```
It will spin up or use existing docker container and drop you into its shell, then launch OpenCode.

### Claude Code

```bash
cld
```
It will spin up or use existing docker container and drop you into its shell, then launch Claude Code.

## 🏗️ Container Architecture

The llm-docker container includes:

* **Base Image**: `node:18` (with Python 3.11+ support)
* **OpenCode CLI**: Globally installed via `npm install -g opencode-ai`
* **Claude Code CLI**: Globally installed via `npm install -g @anthropic-ai/claude-code`
* **Development Tools**: Python, pip, git, curl, wget, vim
* **Security**: Dropped capabilities, no-new-privileges, restricted file access
* **Network**: Host mode for seamless connectivity
* **Volume Mounts**:
  - `~/Projects` → `/root/Projects` (your projects)
  - `~/.llm_docker/opencode` → `/root` (persistent OpenCode data)
  - `~/.llm_docker/claude` → `/root_claude` (persistent Claude Code data)
  - `opencode.config.jsonc` → `/tmp/opencode.config.jsonc` (config file)

## 🔍 Features

### ✨ Core Features

* ✅ **Auto-start OpenCode/Claude Code** - Launches automatically when container starts
* ✅ **Smart directory detection** - Starts in your current directory
* ✅ **Interactive shell access** - Drop to shell after tool exits
* ✅ **Data persistence** - All sessions, API keys, and config saved to `~/.llm_docker/opencode` (OpenCode) or `~/.llm_docker/claude` (Claude Code)
* ✅ **Complete isolation** - Separate from native macOS installations (privacy-focused)
* ✅ **Auto-start Docker** - Automatically starts Docker Desktop on macOS
* ✅ **Dual tool support** - Run both OpenCode and Claude Code from the same Docker image

### 🔒 Security Features

* ✅ **Restricted file access** - Only `~/Projects` is accessible
* ✅ **Dropped capabilities** - Minimal container privileges
* ✅ **No new privileges** - Security hardening enabled
* ✅ **Isolated data** - Tool data completely separate from host

### ⚙️ Configuration Features

* ✅ **Environment variables** - API keys from `.env` file (OPENAI_API_KEY, ZAI_API_KEY, ANTHROPIC_API_KEY)
* ✅ **Config file support** - JSONC format with comments for OpenCode
* ✅ **Model customization** - Configure agents and models per your needs
* ✅ **Custom hostname** - Easy identification (`llm-docker`)


## 🚧 Roadmap

* **ocd/cld --params**: Allow to pass through params from ocd/cld to docker's opencode/claude
* **Server Mode**: Run OpenCode/Claude Code as a server for IDE integration (port 49455)
* **SSH/GIT**: Securely forward your SSH/Git credentials to the container
