#!/usr/bin/env bash
# Run OpenCode in a container with all host settings
# Supports Podman (preferred) and Docker
# Usage: ./run-opencode.sh [project-dir] [extra-args...]
#
# Examples:
#   ./run-opencode.sh                          # Run in current dir
#   ./run-opencode.sh ~/Projects/myapp         # Run in specific project
#   ./run-opencode.sh ~/Projects/myapp --help  # Pass args to opencode

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# ─── Detect container engine ────────────────────────────────────
CONTAINER_ENGINE=""
if command -v podman >/dev/null 2>&1; then
    CONTAINER_ENGINE="podman"
elif command -v docker >/dev/null 2>&1; then
    CONTAINER_ENGINE="docker"
else
    echo "Error: Neither podman nor docker found. Please install one." >&2
    exit 1
fi

# ─── Configuration ───────────────────────────────────────────────
CONTAINER_NAME="opencode"
IMAGE_NAME="localhost/opencode"
HOST_CONFIG_DIR="${HOME}/.config/opencode"
HOST_DATA_DIR="${HOME}/.local/share/opencode"
CONTAINER_HOME="/home/opencode"

# ─── Project directory (first arg, unless it's a flag) ─────────
if [[ "${1:-}" == -* ]]; then
    PROJECT_DIR="$(pwd)"
else
    PROJECT_DIR="${1:-$(pwd)}"
    shift 2>/dev/null || true
fi

# Portable realpath fallback for macOS
if command -v realpath >/dev/null 2>&1; then
    PROJECT_DIR="$(realpath "${PROJECT_DIR}")"
else
    PROJECT_DIR="$(cd "${PROJECT_DIR}" 2>/dev/null && pwd)"
    if [[ -z "${PROJECT_DIR}" ]]; then
        echo "Error: Cannot resolve project directory: ${1:-}" >&2
        exit 1
    fi
fi

# ─── Ensure directories exist ────────────────────────────────────
mkdir -p "${HOST_CONFIG_DIR}"
mkdir -p "${HOST_DATA_DIR}"

# ─── Safe env file loading (no arbitrary code execution) ─────────
ENV_FILE="${HOST_CONFIG_DIR}/.env"
if [[ -f "${ENV_FILE}" ]]; then
    echo "Loading env from ${ENV_FILE}"
    while IFS='=' read -r key value || [[ -n "${key}" ]]; do
        # Skip comments and empty lines
        [[ "${key}" =~ ^[[:space:]]*# ]] && continue
        [[ -z "${key}" ]] && continue
        # Only allow known API key variables
        case "${key}" in
            OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY|CONTEXT7_API_KEY|BRAVE_API_KEY|PLAYWRITER_TOKEN|AGENTMEMORY_URL|PLAYWRITER_HOST)
                export "${key}=${value}"
                ;;
        esac
    done < "${ENV_FILE}"
fi

# ─── Build image if needed ──────────────────────────────────────
if ! "${CONTAINER_ENGINE}" image exists "${IMAGE_NAME}" 2>/dev/null; then
    echo "Building OpenCode container image..."

    # Cleanup trap for temporary binary
    TEMP_BIN=""
    cleanup() {
        [[ -n "${TEMP_BIN}" ]] && rm -f "${TEMP_BIN}"
    }
    trap cleanup EXIT

    BUILD_ARGS=()

    # Try to find opencode binary on host
    OPENCODE_BIN_PATH="$(which opencode 2>/dev/null || true)"
    if [[ -n "${OPENCODE_BIN_PATH}" && -x "${OPENCODE_BIN_PATH}" ]]; then
        echo "  Found host binary: ${OPENCODE_BIN_PATH}"
        TEMP_BIN="${SCRIPT_DIR}/opencode-bin"
        cp "${OPENCODE_BIN_PATH}" "${TEMP_BIN}"
        BUILD_ARGS+=(--build-arg "OPENCODE_BIN=./opencode-bin")
    else
        echo "  No host binary found — container will need opencode installed at runtime"
        echo "  (install via pacman on Arch/CachyOS, or mount the binary)"
    fi

    # Match host UID/GID
    BUILD_ARGS+=(--build-arg "HOST_UID=$(id -u)")
    BUILD_ARGS+=(--build-arg "HOST_GID=$(id -g)")

    "${CONTAINER_ENGINE}" build "${BUILD_ARGS[@]}" -t "${IMAGE_NAME}" "${SCRIPT_DIR}"
fi

# ─── Prepare conditional mounts and env vars ────────────────────
MOUNTS=()
ENV_VARS=()

# Git config (only if exists)
if [[ -f "${HOME}/.gitconfig" ]]; then
    MOUNTS+=(-v "${HOME}/.gitconfig:${CONTAINER_HOME}/.gitconfig:ro")
fi

# SSH: prefer agent forwarding, fall back to directory mount
if [[ -n "${SSH_AUTH_SOCK:-}" && -S "${SSH_AUTH_SOCK}" ]]; then
    MOUNTS+=(-v "${SSH_AUTH_SOCK}:${SSH_AUTH_SOCK}:ro")
    ENV_VARS+=(-e "SSH_AUTH_SOCK=${SSH_AUTH_SOCK}")
elif [[ -d "${HOME}/.ssh" ]]; then
    MOUNTS+=(-v "${HOME}/.ssh:${CONTAINER_HOME}/.ssh:ro")
fi

# ─── Networking: host network on Linux, port forwarding on macOS ─
NETWORK_ARGS=""
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "Note: Using port forwarding for macOS compatibility" >&2
    NETWORK_ARGS="-p 19988:19988 -p 3111:3111"
else
    NETWORK_ARGS="--network host"
fi

# ─── Podman-specific: keep UID mapping for file permissions ──────
USERNS_ARGS=""
if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    USERNS_ARGS="--userns keep-id"
fi

# ─── Podman run ──────────────────────────────────────────────────
echo "Starting OpenCode in container..."
echo "  Engine:  ${CONTAINER_ENGINE}"
echo "  Project: ${PROJECT_DIR}"
echo "  Config:  ${HOST_CONFIG_DIR}"
echo "  Data:    ${HOST_DATA_DIR}"

exec "${CONTAINER_ENGINE}" run --rm -it \
    --name "${CONTAINER_NAME}" \
    \
    `# ── Identity ──` \
    --user "$(id -u):$(id -g)" \
    ${USERNS_ARGS} \
    \
    `# ── Config mounts ──` \
    -v "${HOST_CONFIG_DIR}:${CONTAINER_HOME}/.config/opencode:rw" \
    \
    `# ── Data persistence ──` \
    -v "${HOST_DATA_DIR}:${CONTAINER_HOME}/.local/share/opencode:rw" \
    \
    `# ── Project workspace ──` \
    -v "${PROJECT_DIR}:/workspace:rw" \
    \
    `# ── Conditional mounts (git, ssh) ──` \
    "${MOUNTS[@]}" \
    \
    `# ── Environment variables (SSH agent, etc.) ──` \
    "${ENV_VARS[@]}" \
    \
    `# ── API keys from environment ──` \
    ${OPENAI_API_KEY:+-e "OPENAI_API_KEY=${OPENAI_API_KEY}"} \
    ${ANTHROPIC_API_KEY:+-e "ANTHROPIC_API_KEY=${ANTHROPIC_API_KEY}"} \
    ${GOOGLE_API_KEY:+-e "GOOGLE_API_KEY=${GOOGLE_API_KEY}"} \
    ${CONTEXT7_API_KEY:+-e "CONTEXT7_API_KEY=${CONTEXT7_API_KEY}"} \
    ${BRAVE_API_KEY:+-e "BRAVE_API_KEY=${BRAVE_API_KEY}"} \
    \
    `# ── Networking ──` \
    ${NETWORK_ARGS} \
    \
    `# ── Security hardening ──` \
    --read-only \
    --tmpfs /tmp:rw,noexec,nosuid,size=512m \
    --tmpfs "${CONTAINER_HOME}/.cache:rw,noexec,nosuid,size=256m" \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    \
    `# ── Resource limits ──` \
    --memory 4g \
    --cpus 2 \
    \
    `# ── Workdir ──` \
    -w /workspace \
    "${IMAGE_NAME}" \
    "$@"
