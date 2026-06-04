# OpenCode Container — Portable Setup
# Works on any Linux system with Podman or Docker
# macOS supported via Docker Desktop / Podman Desktop
#
# Build:  podman build -t opencode .
# Run:    ./run-opencode.sh [project-dir]

# Pinned digest for node:24-bookworm-slim (immutable)
# To update: podman pull docker.io/library/node:24-bookworm-slim && podman inspect --format='{{.Digest}}' docker.io/library/node:24-bookworm-slim
FROM docker.io/library/node:24-bookworm-slim@sha256:cbd8bcbdfd0d148205c9449dff3ca3c9c94d73f393a0e03ef1c8d3846c5038bf AS base

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    ripgrep \
    unzip \
    gcc \
    g++ \
    make \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install bun with version pinning
ARG BUN_VERSION=1.3.14
ENV BUN_INSTALL_VERSION="${BUN_VERSION}"
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# ── Install opencode ─────────────────────────────────────────────
# Option 1: Copy from host if provided during build (fastest)
# Option 2: The container will need opencode installed at runtime
ARG OPENCODE_BIN=""
COPY ${OPENCODE_BIN:-/dev/null} /usr/local/bin/opencode-temp
RUN if [ -f /usr/local/bin/opencode-temp ] && [ -s /usr/local/bin/opencode-temp ]; then \
        mv /usr/local/bin/opencode-temp /usr/local/bin/opencode; \
        chmod +x /usr/local/bin/opencode; \
    else \
        rm -f /usr/local/bin/opencode-temp; \
        echo "No binary provided, opencode must be mounted or installed at runtime"; \
    fi

# Pre-install common MCP server packages for faster startup
RUN bun install -g \
    @upstash/context7-mcp \
    @modelcontextprotocol/server-sequential-thinking \
    @brave/brave-search-mcp-server \
    octocode-mcp \
    @agentmemory/mcp

# Create non-root user matching host UID (handle collisions with base image)
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN if getent group ${HOST_GID} >/dev/null 2>&1; then \
        OLD_GROUP=$(getent group ${HOST_GID} | cut -d: -f1) && \
        groupmod -n opencode "${OLD_GROUP}"; \
    else \
        groupadd -g ${HOST_GID} opencode; \
    fi && \
    if getent passwd ${HOST_UID} >/dev/null 2>&1; then \
        OLD_USER=$(getent passwd ${HOST_UID} | cut -d: -f1) && \
        usermod -l opencode "${OLD_USER}" && \
        usermod -d /home/opencode -m opencode; \
    else \
        useradd -m -u ${HOST_UID} -g ${HOST_GID} -s /bin/bash opencode; \
    fi

USER opencode
WORKDIR /workspace

# Healthcheck for orchestrators
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD opencode --version || exit 1

ENTRYPOINT ["opencode"]
