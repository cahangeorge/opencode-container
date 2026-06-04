# OpenCode Container

Portable, containerized OpenCode setup with all your agents, skills, MCPs, and conversation history.

## Quick Start

```bash
# Clone
git clone git@github.com:cahangeorge/opencode-container.git
cd opencode-container

# Build (auto-detects host opencode binary)
./run-opencode.sh

# Or run in a specific project
./run-opencode.sh ~/Projects/myapp
```

## What Gets Mounted

| Source (Host) | Target (Container) | Mode |
|---|---|---|
| `~/.config/opencode/` | `/home/opencode/.config/opencode` | rw |
| `~/.local/share/opencode/` | `/home/opencode/.local/share/opencode` | rw |
| `~/Projects/myapp/` | `/workspace` | rw |
| `~/.gitconfig` | `/home/opencode/.gitconfig` | ro |
| `~/.ssh` | `/home/opencode/.ssh` | ro |

**Everything persists on the host.** The container image is stateless — rebuilding it won't lose history, sessions, or settings.

## Prerequisites

- Podman (or Docker with `alias docker=podman`)
- `opencode` installed on the host (for auto-detection during build)
- Node.js and bun available inside container (installed automatically)

## API Keys

Create `~/.config/opencode/.env`:

```bash
OPENAI_API_KEY=sk-...
ANTHROPIC_API_KEY=sk-ant-...
GOOGLE_API_KEY=...
CONTEXT7_API_KEY=...
BRAVE_API_KEY=...
```

Or export them before running:

```bash
export OPENAI_API_KEY="sk-..."
./run-opencode.sh
```

## Security

- Read-only root filesystem
- All Linux capabilities dropped
- No new privileges
- 4GB memory limit, 2 CPU limit
- Non-root user inside container
- Host network for MCP server communication

## Customization

### Resource limits

Edit `run-opencode.sh`:

```bash
--memory 8g    # Increase memory
--cpus 4       # Increase CPU
```

### Network isolation

Remove `--network host` and add explicit port mappings if you don't need host network access:

```bash
# Instead of --network host:
-p 19988:19988  # Playwriter
-p 3111:3111    # AgentMemory
```

### Adding MCP servers

Edit `~/.config/opencode/opencode.json` on the host — changes are mounted live into the container.

## Troubleshooting

**Binary not found after build:**
```bash
# The build couldn't find opencode on the host. Install it first:
# On CachyOS/Arch:
sudo pacman -S opencode
# Then rebuild:
podman rmi localhost/opencode
./run-opencode.sh
```

**Permission denied on config files:**
```bash
# Ensure your UID matches the container user
id -u  # Should match HOST_UID in the build
```

**MCP servers can't connect:**
```bash
# Ensure host services are running
# Playwriter: http://localhost:19988
# AgentMemory: http://localhost:3111
# The container uses --network host to reach them
```
