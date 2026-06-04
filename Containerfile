# OpenCode + OpenChamber Container — Portable Setup
# Works on any Linux system with Podman or Docker
# macOS supported via Docker Desktop / Podman Desktop
#
# Build:  podman build -t opencode .
# Run CLI:    ./run-opencode.sh [project-dir]
# Run Chamber: ./run-opencode.sh --chamber [project-dir]

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
    supervisor \
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
COPY ${OPENCODE_BIN:-.empty-file} /usr/local/bin/opencode-temp
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

# ── Install OpenChamber ──────────────────────────────────────────
ARG OPENCHAMBER_VERSION=1.12.1
RUN npm install -g "@openchamber/web@${OPENCHAMBER_VERSION}"

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

# Supervisor config for running both OpenCode serve and OpenChamber
COPY supervisord.conf /etc/supervisor/conf.d/supervisord.conf
COPY start-chamber.sh /usr/local/bin/start-chamber.sh
RUN chmod +x /usr/local/bin/start-chamber.sh

# ── Optional: Bake in host data at build time ────────────────────
# Use --export-history flag in run-opencode.sh to populate these
ARG EXPORT_CONFIG=""
ARG EXPORT_DATA=""
ARG EXPORT_STATE=""
ARG EXPORT_CHAMBER=""
COPY ${EXPORT_CONFIG:-.empty-file} /tmp/opencode-config-temp
COPY ${EXPORT_DATA:-.empty-file} /tmp/opencode-data-temp
COPY ${EXPORT_STATE:-.empty-file} /tmp/opencode-state-temp
COPY ${EXPORT_CHAMBER:-.empty-file} /tmp/openchamber-config-temp
RUN if [ -d /tmp/opencode-config-temp ] && [ "$(ls -A /tmp/opencode-config-temp)" ]; then \
        mkdir -p /home/opencode/.config/opencode && \
        cp -a /tmp/opencode-config-temp/* /home/opencode/.config/opencode/; \
    fi && \
    if [ -d /tmp/opencode-data-temp ] && [ "$(ls -A /tmp/opencode-data-temp)" ]; then \
        mkdir -p /home/opencode/.local/share/opencode && \
        cp -a /tmp/opencode-data-temp/* /home/opencode/.local/share/opencode/; \
    fi && \
    if [ -d /tmp/opencode-state-temp ] && [ "$(ls -A /tmp/opencode-state-temp)" ]; then \
        mkdir -p /home/opencode/.local/state/opencode && \
        cp -a /tmp/opencode-state-temp/* /home/opencode/.local/state/opencode/; \
    fi && \
    if [ -d /tmp/openchamber-config-temp ] && [ "$(ls -A /tmp/openchamber-config-temp)" ]; then \
        mkdir -p /home/opencode/.config/openchamber && \
        cp -a /tmp/openchamber-config-temp/* /home/opencode/.config/openchamber/; \
    fi && \
    chown -R opencode:opencode /home/opencode/.config /home/opencode/.local && \
    rm -rf /tmp/*-temp

# Ensure supervisor log directory exists
RUN mkdir -p /var/log/supervisor && chown opencode:opencode /var/log/supervisor

USER opencode
WORKDIR /workspace

# Expose ports for OpenChamber (3000) and OpenCode serve (4096)
EXPOSE 3000 4096

# Healthcheck for orchestrators
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD opencode --version || exit 1

ENTRYPOINT ["opencode"]
