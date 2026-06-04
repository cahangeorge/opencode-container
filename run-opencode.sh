#!/usr/bin/env bash
# Run OpenCode in a Podman container with all host settings
# Usage: ./run-opencode.sh [project-dir] [extra-args...]
#
# Examples:
#   ./run-opencode.sh                          # Run in current dir
#   ./run-opencode.sh ~/Projects/myapp         # Run in specific project
#   ./run-opencode.sh ~/Projects/myapp --help  # Pass args to opencode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Configuration ───────────────────────────────────────────────
CONTAINER_NAME="opencode"
IMAGE_NAME="localhost/opencode"
HOST_CONFIG_DIR="${HOME}/.config/opencode"
HOST_DATA_DIR="${HOME}/.local/share/opencode"
CONTAINER_HOME="/home/opencode"

# Project directory (first arg or current dir)
PROJECT_DIR="${1:-$(pwd)}"
PROJECT_DIR="$(realpath "${PROJECT_DIR}")"
shift 2>/dev/null || true

# ─── API Keys (pass from env or .env file) ──────────────────────
# Loads from ~/.config/opencode/.env if it exists
ENV_FILE="${HOST_CONFIG_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    echo "Loading env from ${ENV_FILE}"
    set -a
    source "${ENV_FILE}"
    set +a
fi

# ─── Ensure data directory exists ────────────────────────────────
mkdir -p "${HOST_DATA_DIR}"

# ─── Build image if needed ──────────────────────────────────────
if ! podman image exists "${IMAGE_NAME}" 2>/dev/null; then
    echo "Building OpenCode container image..."

    BUILD_ARGS=()
    COPY_BIN=""

    # Try to find opencode binary on host
    OPENCODE_BIN_PATH="$(which opencode 2>/dev/null || true)"
    if [[ -n "${OPENCODE_BIN_PATH}" && -x "${OPENCODE_BIN_PATH}" ]]; then
        echo "  Found host binary: ${OPENCODE_BIN_PATH}"
        cp "${OPENCODE_BIN_PATH}" "${SCRIPT_DIR}/opencode-bin"
        BUILD_ARGS+=(--build-arg "OPENCODE_BIN=./opencode-bin")
        COPY_BIN="true"
    else
        echo "  No host binary found — container will need opencode installed at runtime"
        echo "  (mount it or install via pacman inside the container)"
    fi

    # Match host UID/GID
    BUILD_ARGS+=(--build-arg "HOST_UID=$(id -u)")
    BUILD_ARGS+=(--build-arg "HOST_GID=$(id -g)")

    podman build "${BUILD_ARGS[@]}" -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

    # Clean up copied binary
    [[ "${COPY_BIN:-}" == "true" ]] && rm -f "${SCRIPT_DIR}/opencode-bin"
fi

# ─── Podman run ──────────────────────────────────────────────────
echo "Starting OpenCode in container..."
echo "  Project: ${PROJECT_DIR}"
echo "  Config:  ${HOST_CONFIG_DIR}"
echo "  Data:    ${HOST_DATA_DIR}"

exec podman run --rm -it \
    --name "${CONTAINER_NAME}" \
    \
    `# ── Identity: match host UID/GID for file permissions ──` \
    --user "$(id -u):$(id -g)" \
    \
    `# ── Config mounts (read-write so opencode can update) ──` \
    -v "${HOST_CONFIG_DIR}:${CONTAINER_HOME}/.config/opencode:rw" \
    \
    `# ── Data persistence (sessions, DB, snapshots) ──` \
    -v "${HOST_DATA_DIR}:${CONTAINER_HOME}/.local/share/opencode:rw" \
    \
    `# ── Project workspace (current project) ──` \
    -v "${PROJECT_DIR}:/workspace:rw" \
    \
    `# ── Git config for commits ──` \
    ${HOME}/.gitconfig:+-v "${HOME}/.gitconfig:${CONTAINER_HOME}/.gitconfig:ro"} \
    ${HOME}/.ssh:+-v "${HOME}/.ssh:${CONTAINER_HOME}/.ssh:ro"} \
    \
    `# ── API keys from environment ──` \
    ${OPENAI_API_KEY:+-e "OPENAI_API_KEY=${OPENAI_API_KEY}"} \
    ${ANTHROPIC_API_KEY:+-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"} \
    ${GOOGLE_API_KEY:+-e "GOOGLE_API_KEY=${GOOGLE_API_KEY}"} \
    ${CONTEXT7_API_KEY:+-e "CONTEXT7_API_KEY=${CONTEXT7_API_KEY}"} \
    ${BRAVE_API_KEY:+-e "BRAVE_API_KEY=${BRAVE_API_KEY}"} \
    \
    `# ── Networking: host network for MCP servers (playwriter, agentmemory) ──` \
    --network host \
    \
    `# ── Security hardening ──` \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=512m \
    --tmpfs "${CONTAINER_HOME}/.cache:rw,noexec,nosuid,size=256m" \
    --cap-drop ALL \
    --cap-add SYS_CHROOT \
    --security-opt no-new-privileges:true \
    \
    `# ── Resource limits ──` \
    --memory 4g \
    --cpus 2 \
    \
    `# ── Workdir and entrypoint ──` \
    -w /workspace \
    "${IMAGE_NAME}" \
    "$@"
