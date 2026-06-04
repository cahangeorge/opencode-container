#!/usr/bin/env bash
# Run OpenCode (CLI) or OpenCode + OpenChamber (Web UI) in a container
# Supports Podman (preferred) and Docker
#
# Usage:
#   ./run-opencode.sh [project-dir] [extra-args...]              # OpenCode CLI
#   ./run-opencode.sh --chamber [project-dir]                    # OpenCode + OpenChamber Web UI
#   ./run-opencode.sh --export-history [--chamber] [project-dir] # Build portable image with history
#
# Examples:
#   ./run-opencode.sh                          # CLI in current dir
#   ./run-opencode.sh ~/Projects/myapp         # CLI in specific project
#   ./run-opencode.sh --chamber ~/Projects/myapp  # Web UI for project
#   ./run-opencode.sh --export-history --chamber   # Build portable image with all history

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

# ─── Parse flags ───────────────────────────────────────────────
CHAMBER_MODE=false
EXPORT_HISTORY=false

while [[ "${1:-}" == --* ]]; do
    case "${1}" in
        --chamber)
            CHAMBER_MODE=true
            shift
            ;;
        --export-history)
            EXPORT_HISTORY=true
            shift
            ;;
        *)
            break
            ;;
    esac
done

# ─── Configuration ───────────────────────────────────────────────
CONTAINER_NAME="opencode"
IMAGE_NAME="localhost/opencode"
HOST_CONFIG_DIR="${HOME}/.config/opencode"
HOST_DATA_DIR="${HOME}/.local/share/opencode"
HOST_STATE_DIR="${HOME}/.local/state/opencode"
HOST_CHAMBER_CONFIG_DIR="${HOME}/.config/openchamber"
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
mkdir -p "${HOST_STATE_DIR}"
mkdir -p "${HOST_CHAMBER_CONFIG_DIR}"

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
            OPENAI_API_KEY|ANTHROPIC_API_KEY|GOOGLE_API_KEY|CONTEXT7_API_KEY|BRAVE_API_KEY|PLAYWRITER_TOKEN|AGENTMEMORY_URL|PLAYWRITER_HOST|UI_PASSWORD|GITHUB_PERSONAL_ACCESS_TOKEN|AGENTMEMORY_SECRET|MANIFEST_AUTH_SECRET|OH_MY_OPENCODE|OH_MY_OPENCODE_DCP|PLAYWRITER_AUTO_ENABLE|OPENCHAMBER_TUNNEL_PROVIDER|OPENCHAMBER_TUNNEL_MODE|OPENCHAMBER_TUNNEL_HOSTNAME|OPENCHAMBER_TUNNEL_TOKEN|OPENCHAMBER_TUNNEL_CONFIG)
                export "${key}=${value}"
                ;;
        esac
    done < "${ENV_FILE}"
fi

# ─── Build image if needed ──────────────────────────────────────
if ! "${CONTAINER_ENGINE}" image exists "${IMAGE_NAME}" 2>/dev/null || [[ "${EXPORT_HISTORY}" == true ]]; then
    echo "Building OpenCode container image..."

    # Cleanup trap for temporary files
    TEMP_BIN=""
    TEMP_EXPORT_DIRS=()
    cleanup() {
        [[ -n "${TEMP_BIN}" ]] && rm -f "${TEMP_BIN}"
        for dir in "${TEMP_EXPORT_DIRS[@]}"; do
            [[ -n "${dir}" ]] && rm -rf "${dir}"
        done
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

    # Export history: copy host data into build context
    if [[ "${EXPORT_HISTORY}" == true ]]; then
        echo "  Exporting conversation history and settings into image..."

        if [[ -d "${HOST_CONFIG_DIR}" && "$(ls -A "${HOST_CONFIG_DIR}")" ]]; then
            EXPORT_CONFIG_DIR="${SCRIPT_DIR}/opencode-config-export"
            mkdir -p "${EXPORT_CONFIG_DIR}"
            # Exclude node_modules and large dependency dirs
            rsync -a --exclude='node_modules' --exclude='.git' --exclude='*.log' \
                "${HOST_CONFIG_DIR}/" "${EXPORT_CONFIG_DIR}/" 2>/dev/null || \
                cp -a "${HOST_CONFIG_DIR}"/* "${EXPORT_CONFIG_DIR}/" 2>/dev/null || true
            TEMP_EXPORT_DIRS+=("${EXPORT_CONFIG_DIR}")
            BUILD_ARGS+=(--build-arg "EXPORT_CONFIG=./opencode-config-export")
            echo "    Config: ${HOST_CONFIG_DIR}"
        fi

        if [[ -d "${HOST_DATA_DIR}" && "$(ls -A "${HOST_DATA_DIR}")" ]]; then
            EXPORT_DATA_DIR="${SCRIPT_DIR}/opencode-data-export"
            mkdir -p "${EXPORT_DATA_DIR}"
            cp -a "${HOST_DATA_DIR}"/* "${EXPORT_DATA_DIR}/" 2>/dev/null || true
            TEMP_EXPORT_DIRS+=("${EXPORT_DATA_DIR}")
            BUILD_ARGS+=(--build-arg "EXPORT_DATA=./opencode-data-export")
            echo "    Data:   ${HOST_DATA_DIR}"
        fi

        if [[ -d "${HOST_STATE_DIR}" && "$(ls -A "${HOST_STATE_DIR}")" ]]; then
            EXPORT_STATE_DIR="${SCRIPT_DIR}/opencode-state-export"
            mkdir -p "${EXPORT_STATE_DIR}"
            cp -a "${HOST_STATE_DIR}"/* "${EXPORT_STATE_DIR}/" 2>/dev/null || true
            TEMP_EXPORT_DIRS+=("${EXPORT_STATE_DIR}")
            BUILD_ARGS+=(--build-arg "EXPORT_STATE=./opencode-state-export")
            echo "    State:  ${HOST_STATE_DIR}"
        fi

        if [[ -d "${HOST_CHAMBER_CONFIG_DIR}" && "$(ls -A "${HOST_CHAMBER_CONFIG_DIR}")" ]]; then
            EXPORT_CHAMBER_DIR="${SCRIPT_DIR}/openchamber-config-export"
            mkdir -p "${EXPORT_CHAMBER_DIR}"
            cp -a "${HOST_CHAMBER_CONFIG_DIR}"/* "${EXPORT_CHAMBER_DIR}/" 2>/dev/null || true
            TEMP_EXPORT_DIRS+=("${EXPORT_CHAMBER_DIR}")
            BUILD_ARGS+=(--build-arg "EXPORT_CHAMBER=./openchamber-config-export")
            echo "    Chamber: ${HOST_CHAMBER_CONFIG_DIR}"
        fi
    fi

    # Match host UID/GID
    BUILD_ARGS+=(--build-arg "HOST_UID=$(id -u)")
    BUILD_ARGS+=(--build-arg "HOST_GID=$(id -g)")

    "${CONTAINER_ENGINE}" build "${BUILD_ARGS[@]}" -t "${IMAGE_NAME}" "${SCRIPT_DIR}"

    if [[ "${EXPORT_HISTORY}" == true ]]; then
        echo ""
        echo "Portable image built with history baked in."
        echo "To move to another host:"
        echo "  ${CONTAINER_ENGINE} save ${IMAGE_NAME} | gzip > opencode-portable.tar.gz"
        echo "Then on the new host:"
        echo "  gunzip -c opencode-portable.tar.gz | ${CONTAINER_ENGINE} load"
        echo ""
        exit 0
    fi
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

# ─── Chamber mode: additional mounts and config ─────────────────
ENTRYPOINT_OVERRIDE=""
PORTS=""
CHAMBER_ENVS=()

if [[ "${CHAMBER_MODE}" == true ]]; then
    echo "Mode: OpenCode + OpenChamber (Web UI)"
    CONTAINER_NAME="openchamber"

    # Mount OpenChamber config
    MOUNTS+=(-v "${HOST_CHAMBER_CONFIG_DIR}:${CONTAINER_HOME}/.config/openchamber:rw")

    # Override entrypoint to start both services
    ENTRYPOINT_OVERRIDE="--entrypoint /usr/local/bin/start-chamber.sh"

    # Expose ports for OpenChamber (3000) and OpenCode serve (4096)
    PORTS="-p 3000:3000 -p 4096:4096"

    # OpenChamber environment variables
    [[ -n "${UI_PASSWORD:-}" ]] && CHAMBER_ENVS+=(-e "UI_PASSWORD=${UI_PASSWORD}")
    [[ -n "${OH_MY_OPENCODE:-}" ]] && CHAMBER_ENVS+=(-e "OH_MY_OPENCODE=${OH_MY_OPENCODE}")
    [[ -n "${OH_MY_OPENCODE_DCP:-}" ]] && CHAMBER_ENVS+=(-e "OH_MY_OPENCODE_DCP=${OH_MY_OPENCODE_DCP}")
    [[ -n "${GITHUB_PERSONAL_ACCESS_TOKEN:-}" ]] && CHAMBER_ENVS+=(-e "GITHUB_PERSONAL_ACCESS_TOKEN=${GITHUB_PERSONAL_ACCESS_TOKEN}")
    [[ -n "${AGENTMEMORY_SECRET:-}" ]] && CHAMBER_ENVS+=(-e "AGENTMEMORY_SECRET=${AGENTMEMORY_SECRET}")
    [[ -n "${PLAYWRITER_AUTO_ENABLE:-}" ]] && CHAMBER_ENVS+=(-e "PLAYWRITER_AUTO_ENABLE=${PLAYWRITER_AUTO_ENABLE}")
    [[ -n "${MANIFEST_AUTH_SECRET:-}" ]] && CHAMBER_ENVS+=(-e "MANIFEST_AUTH_SECRET=${MANIFEST_AUTH_SECRET}")
    [[ -n "${OPENCHAMBER_TUNNEL_PROVIDER:-}" ]] && CHAMBER_ENVS+=(-e "OPENCHAMBER_TUNNEL_PROVIDER=${OPENCHAMBER_TUNNEL_PROVIDER}")
    [[ -n "${OPENCHAMBER_TUNNEL_MODE:-}" ]] && CHAMBER_ENVS+=(-e "OPENCHAMBER_TUNNEL_MODE=${OPENCHAMBER_TUNNEL_MODE}")
    [[ -n "${OPENCHAMBER_TUNNEL_HOSTNAME:-}" ]] && CHAMBER_ENVS+=(-e "OPENCHAMBER_TUNNEL_HOSTNAME=${OPENCHAMBER_TUNNEL_HOSTNAME}")
    [[ -n "${OPENCHAMBER_TUNNEL_TOKEN:-}" ]] && CHAMBER_ENVS+=(-e "OPENCHAMBER_TUNNEL_TOKEN=${OPENCHAMBER_TUNNEL_TOKEN}")
    [[ -n "${OPENCHAMBER_TUNNEL_CONFIG:-}" ]] && CHAMBER_ENVS+=(-e "OPENCHAMBER_TUNNEL_CONFIG=${OPENCHAMBER_TUNNEL_CONFIG}")

    # Fixed OpenChamber settings
    CHAMBER_ENVS+=(-e "NODE_ENV=production")
    CHAMBER_ENVS+=(-e "OPENCHAMBER_HOST=0.0.0.0")
    CHAMBER_ENVS+=(-e "OPENCODE_SKIP_START=true")
    CHAMBER_ENVS+=(-e "OPENCODE_HOST=http://localhost:4096")
else
    echo "Mode: OpenCode CLI"
fi

# ─── Networking: host network on Linux, port forwarding on macOS ─
NETWORK_ARGS=""
if [[ "$(uname -s)" == "Darwin" ]]; then
    echo "Note: Using port forwarding for macOS compatibility" >&2
    if [[ "${CHAMBER_MODE}" == true ]]; then
        # Ports already defined above for chamber mode
        NETWORK_ARGS="${PORTS}"
    else
        NETWORK_ARGS="-p 19988:19988 -p 3111:3111"
    fi
else
    if [[ "${CHAMBER_MODE}" == true ]]; then
        NETWORK_ARGS="${PORTS}"
    else
        NETWORK_ARGS="--network host"
    fi
fi

# ─── Podman-specific: keep UID mapping for file permissions ──────
USERNS_ARGS=""
if [[ "${CONTAINER_ENGINE}" == "podman" ]]; then
    USERNS_ARGS="--userns keep-id"
fi

# ─── Container run ──────────────────────────────────────────────
echo "Starting container..."
echo "  Engine:  ${CONTAINER_ENGINE}"
echo "  Project: ${PROJECT_DIR}"
echo "  Config:  ${HOST_CONFIG_DIR}"
echo "  Data:    ${HOST_DATA_DIR}"
if [[ "${CHAMBER_MODE}" == true ]]; then
    echo "  Chamber: ${HOST_CHAMBER_CONFIG_DIR}"
    echo "  URLs:    http://localhost:3000 (OpenChamber)"
    echo "           http://localhost:4096 (OpenCode API)"
fi

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
    -v "${HOST_STATE_DIR}:${CONTAINER_HOME}/.local/state/opencode:rw" \
    \
    `# ── Project workspace ──` \
    -v "${PROJECT_DIR}:/workspace:rw" \
    \
    `# ── Conditional mounts (git, ssh, chamber) ──` \
    "${MOUNTS[@]}" \
    \
    `# ── Environment variables (SSH agent, etc.) ──` \
    "${ENV_VARS[@]}" \
    \
    `# ── Chamber mode env vars ──` \
    "${CHAMBER_ENVS[@]}" \
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
    `# ── Entrypoint override for chamber mode ──` \
    ${ENTRYPOINT_OVERRIDE} \
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
