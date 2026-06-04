# OpenCode Container — Portable Setup
# Works on any Arch-based system (CachyOS, Endeavour, Manjaro, vanilla Arch)
#
# Build:  podman build -t opencode .
# Run:    ./run-opencode.sh [project-dir]

FROM docker.io/library/node:24-bookworm-slim AS base

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    git \
    curl \
    ca-certificates \
    ripgrep \
    gcc \
    g++ \
    make \
    gnupg \
    && rm -rf /var/lib/apt/lists/*

# Install bun (required for MCP servers via bunx)
RUN curl -fsSL https://bun.sh/install | bash
ENV PATH="/root/.bun/bin:${PATH}"

# ── Install opencode ─────────────────────────────────────────────
# Option 1: Copy from host if provided during build (fastest)
# Option 2: Download from GitHub releases (portable fallback)
# The build-arg OPENCODE_BIN allows mounting the host binary;
# if not provided, falls back to downloading the release.
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
    @agentmemory/mcp \
    2>/dev/null || true

# Create non-root user matching host UID
ARG HOST_UID=1000
ARG HOST_GID=1000
RUN groupadd -g ${HOST_GID} opencode && \
    useradd -m -u ${HOST_UID} -g ${HOST_GID} -s /bin/bash opencode

USER opencode
WORKDIR /workspace

ENTRYPOINT ["opencode"]
