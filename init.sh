#!/bin/bash
set -e
export PATH="/usr/local/bin:$PATH"

# ---------------------------------------------------------------------------
# Usage:
#   bash <(curl -s https://raw.githubusercontent.com/konradoai/proxy-downloader/main/init.sh) \
#       --api-key=<konrado_api_key> \
#       --callback-url=<https://app.konrado.ai/api/integrations/servers/install>
#
# Or via custom domain:
#   bash <(curl -s https://repo.konrado.ai/proxy-downloader/init.sh) \
#       --api-key=<konrado_api_key> \
#       --callback-url=<https://app.konrado.ai/api/integrations/servers/install>
#
# Optional:
#   --server-url=<http://your-public-ip:8001>   override auto-detected URL
#   --port=<8001>                                override default proxy port
# ---------------------------------------------------------------------------

# Function to check python version (>= 3.10)
check_python_version() {
    local exe="$1"
    ver="$("$exe" -c 'import sys; v=sys.version_info; print(f"{v.major}.{v.minor}")')" 2>/dev/null
    if [[ -n "$ver" ]]; then
        if [[ "$(printf '%s\n' "$ver" "3.10" | sort -V | head -n1)" == "3.10" ]]; then
            echo "$exe"
            return 0
        fi
    fi
    return 1
}

# Find and return the best python executable (3.10+)
get_python() {
    local candidates=()
    local minor exe py_path found

    for minor in 14 13 12 11 10; do
        candidates+=(
            "python3.$minor"
            "python3$minor"
            "/opt/alt/python3$minor/bin/python3"
        )
    done
    candidates+=(python3 python)

    for exe in "${candidates[@]}"; do
        if [[ "$exe" == /* ]]; then
            [[ -x "$exe" ]] || continue
            py_path="$exe"
        else
            py_path=$(command -v "$exe" 2>/dev/null || true)
            [[ -n "$py_path" ]] || continue
        fi

        found=$(check_python_version "$py_path" 2>/dev/null || true)
        if [[ -n "$found" ]]; then
            echo "$found"
            return 0
        fi
    done

    echo "Error: Python 3.10 or newer is required." >&2
    return 1
}

# ---------------------------------------------------------------------------
# Dependency checks
# ---------------------------------------------------------------------------
if ! command -v curl &> /dev/null; then
    echo "curl is not installed. Please install curl and try again."
    exit 1
fi

if ! command -v unzip &> /dev/null; then
    echo "unzip is not installed. Please install unzip and try again."
    exit 1
fi

if ! command -v systemctl &> /dev/null; then
    echo "systemd is not installed. Please install systemd and try again."
    exit 1
fi

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
API_KEY=""
CALLBACK_URL=""
SERVER_URL=""
PORT=""

for arg in "$@"; do
    case $arg in
        --api-key=*)        API_KEY="${arg#*=}" ;;
        --callback-url=*)   CALLBACK_URL="${arg#*=}" ;;
        --server-url=*)     SERVER_URL="${arg#*=}" ;;
        --port=*)           PORT="${arg#*=}" ;;
    esac
done

if [[ -z "$API_KEY" || -z "$CALLBACK_URL" ]]; then
    echo "Error: --api-key and --callback-url are required."
    echo ""
    echo "Usage:"
    echo "  bash <(curl -s https://repo.konrado.ai/proxy-downloader/init.sh) \\"
    echo "      --api-key=<konrado_api_key> \\"
    echo "      --callback-url=<https://app.konrado.ai/api/integrations/servers/install>"
    exit 1
fi

# ---------------------------------------------------------------------------
# System user / group
# ---------------------------------------------------------------------------
if ! getent group konrado-mcp-remote-agent >/dev/null 2>&1; then
    echo "Creating group 'konrado-mcp-remote-agent'..."
    groupadd --system konrado-mcp-remote-agent
else
    echo "Group 'konrado-mcp-remote-agent' already exists."
fi

if ! getent passwd konrado-mcp-remote-agent >/dev/null 2>&1; then
    echo "Creating user 'konrado-mcp-remote-agent'..."
    useradd --system -g konrado-mcp-remote-agent --home-dir /opt/KonradoAiRemoteAgent --shell /bin/bash --create-home konrado-mcp-remote-agent
else
    echo "User 'konrado-mcp-remote-agent' already exists."
fi

if ! groups konrado-mcp-remote-agent | grep -q konrado-mcp-remote-agent; then
    usermod -a -G konrado-mcp-remote-agent konrado-mcp-remote-agent
fi

# ---------------------------------------------------------------------------
# Python virtualenv
# ---------------------------------------------------------------------------
PYTHON_EXE=$(get_python)
if [[ -z "$PYTHON_EXE" ]]; then
    exit 1
fi
echo "Using Python: $PYTHON_EXE"

"$PYTHON_EXE" -m venv /opt/KonradoAiRemoteAgent/.venv

chmod -R 750 /opt/KonradoAiRemoteAgent/
chown -R konrado-mcp-remote-agent:konrado-mcp-remote-agent /opt/KonradoAiRemoteAgent/

cd /opt/KonradoAiRemoteAgent/
source /opt/KonradoAiRemoteAgent/.venv/bin/activate

# ---------------------------------------------------------------------------
# Install package
# ---------------------------------------------------------------------------
pip install -U pip

pip install --no-cache-dir --force-reinstall \
    --extra-index-url http://repo.konrado.ai:3141/konrado/dev/ \
    --trusted-host repo.konrado.ai \
    KonradoAiRemoteAgent

# ---------------------------------------------------------------------------
# Unpack scripts / data
# ---------------------------------------------------------------------------
konrado-mcp-remote-agent-unpack-data

# ---------------------------------------------------------------------------
# Auto-configure .env (generates API_KEY, sets defaults - non-interactive)
# ---------------------------------------------------------------------------
konrado-mcp-remote-agent-configure-env --auto

# Override port in .env if --port was provided on command line
if [[ -n "$PORT" ]]; then
    if grep -q "^SERVER_PORT=" .env 2>/dev/null; then
        sed -i "s|^SERVER_PORT=.*|SERVER_PORT=$PORT|" .env
    else
        echo "SERVER_PORT=$PORT" >> .env
    fi
fi

# ---------------------------------------------------------------------------
# Install and start systemd service
# ---------------------------------------------------------------------------
bash /opt/KonradoAiRemoteAgent/scripts/install.sh

# ---------------------------------------------------------------------------
# Register integration with Konrado.AI backend
# ---------------------------------------------------------------------------
CONNECT_ARGS=(
    "--api-key=$API_KEY"
    "--callback-url=$CALLBACK_URL"
)

if [[ -n "$SERVER_URL" ]]; then
    CONNECT_ARGS+=("--server-url=$SERVER_URL")
fi

if [[ -n "$PORT" ]]; then
    CONNECT_ARGS+=("--port=$PORT")
fi

konrado-mcp-remote-agent-connect "${CONNECT_ARGS[@]}"

# ---------------------------------------------------------------------------
echo ""
echo "============================================"
echo " Konrado AI Remote Agent installed successfully"
echo " Service  : konrado-mcp-remote-agent.service"
echo " Status   : $(systemctl is-active konrado-mcp-remote-agent.service 2>/dev/null || echo 'unknown')"
echo "============================================"
