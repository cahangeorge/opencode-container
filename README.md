# OpenCode + OpenChamber Container

Portable container setup for [OpenCode](https://github.com/opencode-ai/opencode) AI coding agent with optional [OpenChamber](https://github.com/openchamber-ai/openchamber) web UI. Preserves all settings, agents, skills, MCPs, and conversation history across runs.

## Features

- **OpenCode CLI** — Full terminal-based AI coding assistant
- **OpenChamber Web UI** — Browser-based interface (optional, `--chamber` flag)
- **Settings preserved** — Configs, conversation history, and custom agents/skills
- **Cross-platform** — Linux (Podman/Docker), macOS (Docker Desktop / Podman Desktop)
- **Security-hardened** — No root, dropped capabilities, read-only rootfs, pinned base image

## Quick Start

```bash
# Clone
git clone https://github.com/cahangeorge/opencode-container.git
cd opencode-container

# Build
podman build -t opencode .

# Run OpenCode CLI
./run-opencode.sh

# Run OpenCode + OpenChamber Web UI
./run-opencode.sh --chamber
# Then open http://localhost:3000
```

## Setup

### 1. Environment Variables

Copy the template and add your API keys:

```bash
mkdir -p ~/.config/opencode
cp .env.template ~/.config/opencode/.env
chmod 600 ~/.config/opencode/.env
# Edit ~/.config/opencode/.env with your keys
```

### 2. First Run

The script auto-builds the image on first run. It will:
- Detect your container engine (Podman preferred, Docker fallback)
- Copy your host `opencode` binary into the image (if found)
- Match your host UID/GID for file permission compatibility

## Usage

### OpenCode CLI (default)

```bash
# Current directory
./run-opencode.sh

# Specific project
./run-opencode.sh ~/Projects/myapp

# Pass arguments to opencode
./run-opencode.sh ~/Projects/myapp --help
```

### OpenCode + OpenChamber Web UI

```bash
# Start both services
./run-opencode.sh --chamber

# With specific project
./run-opencode.sh --chamber ~/Projects/myapp

# Access:
#   OpenChamber UI: http://localhost:3000
#   OpenCode API:   http://localhost:4096
```

## What Gets Preserved

| Host Path | Container Path | Contents |
|-----------|---------------|----------|
| `~/.config/opencode` | `/home/opencode/.config/opencode` | Settings, agents, skills, MCP configs |
| `~/.local/share/opencode` | `/home/opencode/.local/share/opencode` | Conversation history (opencode.db) |
| `~/.config/openchamber` | `/home/opencode/.config/openchamber` | OpenChamber settings, auth, sessions |
| `~/.gitconfig` | `/home/opencode/.gitconfig` | Git configuration |
| `~/.ssh` or `$SSH_AUTH_SOCK` | forwarded | SSH keys or agent |

## Requirements

- **Podman** (recommended) or Docker
- Linux kernel 5.0+ or macOS 12+
- 4GB RAM, 2 CPU cores (configurable in script)

## Architecture

- **Base image:** `node:24-bookworm-slim` (pinned digest)
- **Runtime:** Bun + Node.js
- **Process manager:** supervisord (chamber mode only)
- **User:** Non-root, matching host UID/GID
- **Security:** `--read-only`, `--cap-drop ALL`, `--security-opt no-new-privileges`

## Portable Image with History

To move your complete setup (including all conversation history and settings) to another machine:

```bash
# Build a portable image with history baked in
./run-opencode.sh --export-history --chamber

# Save the image
podman save localhost/opencode | gzip > opencode-portable.tar.gz

# Move to new host, then load
 gunzip -c opencode-portable.tar.gz | podman load

# Run on new host — history is already inside
./run-opencode.sh --chamber
```

The `--export-history` flag copies these directories into the image:
- `~/.config/opencode` — settings, agents, skills, MCPs
- `~/.local/share/opencode` — conversation history
- `~/.local/state/opencode` — runtime state
- `~/.config/openchamber` — OpenChamber settings

**Note:** API keys in `.env` are NOT exported into the image. Set them on the new host via `~/.config/opencode/.env`.

## Updating

```bash
# Pull latest code
git pull

# Rebuild image
podman build -t opencode .
# or let the run script auto-rebuild
```

## Troubleshooting

**Image build fails:** Ensure you have `opencode` installed on the host, or install it after container start.

**Permission errors:** The script matches your host UID/GID. If you see permission issues, delete the image and let it rebuild.

**macOS port conflicts:** The script auto-detects macOS and uses port forwarding instead of `--network host`.

**OpenChamber not connecting:** Ensure port 4096 is accessible. On Linux with `--network host`, it binds to all interfaces.
