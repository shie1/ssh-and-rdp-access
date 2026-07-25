#!/usr/bin/env bash

# Parameter defaults
BASE_URL="!<<ENV_BASE_URL>>"
TARGET="!<<ENV_TARGET>>"
TARGET_PORT="!<<ENV_SSH_PORT>>"
RDP_PORT="!<<ENV_RDP_PORT>>"
REMOTE_COMMAND="${5:-}"

set -u

# 1. Locate an available RDP client on Linux
RDP_CLIENT=""
RDP_TYPE=""

if command -v xfreerdp &>/dev/null; then
    RDP_CLIENT="xfreerdp"
    RDP_TYPE="xfreerdp"
elif command -v wlfreerdp &>/dev/null; then
    RDP_CLIENT="wlfreerdp"
    RDP_TYPE="xfreerdp"
elif command -v remmina &>/dev/null; then
    RDP_CLIENT="remmina"
    RDP_TYPE="remmina"
elif command -v rdesktop &>/dev/null; then
    RDP_CLIENT="rdesktop"
    RDP_TYPE="rdesktop"
else
    echo "Hiba: Nem talalhato RDP kliens (xfreerdp, remmina, vagy rdesktop) a rendszeren." >&2
    exit 1
fi

if [ -n "$REMOTE_COMMAND" ]; then
    echo "Hiba: Az RDP inditashoz nem tamogatott a RemoteCommand parameter." >&2
    exit 1
fi

# Track background processes and temp files
TEMP_KEY_PATH=""
SSH_PID=""
RDP_PID=""

# Cleanup function (PowerShell's finally block equivalent)
cleanup() {
    if [ -n "$RDP_PID" ] && kill -0 "$RDP_PID" 2>/dev/null; then
        kill -9 "$RDP_PID" 2>/dev/null
    fi

    if [ -n "$SSH_PID" ] && kill -0 "$SSH_PID" 2>/dev/null; then
        kill -9 "$SSH_PID" 2>/dev/null
    fi

    if [ -n "$TEMP_KEY_PATH" ] && [ -f "$TEMP_KEY_PATH" ]; then
        rm -f "$TEMP_KEY_PATH"
    fi
}
trap cleanup EXIT INT TERM

# Helper: Find a free local TCP port dynamically
get_free_local_port() {
    python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()' 2>/dev/null || \
    nc -z -v 127.0.0.1 1024-65535 2>&1 | awk '/succeeded/ {print $3}' | head -n 1
}

# Helper: Wait for local port to open
wait_for_local_port() {
    local port="$1"
    local timeout=15
    local elapsed=0

    while [ $elapsed -lt $timeout ]; do
        # Check if SSH process died early
        if [ -n "$SSH_PID" ] && ! kill -0 "$SSH_PID" 2>/dev/null; then
            echo "Hiba: Az SSH alagut megszakadt mielott az RDP port elerhetove valt." >&2
            return 1
        fi

        # Attempt TCP connection to local forward port
        if nc -z 127.0.0.1 "$port" 2>/dev/null || (echo > "/dev/tcp/127.0.0.1/$port") 2>/dev/null; then
            return 0
        fi

        sleep 0.25
        elapsed=$((elapsed + 1))
    done

    echo "Hiba: Az SSH alagut nem valt elerhetove idoben." >&2
    return 1
}

# 2. Prompts (reading directly from /dev/tty to support pipe execution)
read -rs -p "Jelszo: " PASSWORD </dev/tty
echo ""

if [ -z "$PASSWORD" ]; then
    echo "Hiba: A jelszo nem lehet ures.">&2
    exit 1
fi

read -r -p "2FA kod (6 szamjegy): " OTP </dev/tty

if [[ ! "$OTP" =~ ^[0-9]{6}$ ]]; then
    echo "Hiba: A 2FA kodnak pontosan 6 szamjegynek kell lennie.">&2
    exit 1
fi

# 3. HTTP Request for Key
NORMALIZED_BASE="${BASE_URL%/}"
KEY_ENDPOINT="${NORMALIZED_BASE}/key"
AUTH_HEADER="Authorization: Bearer ${PASSWORD}:${OTP}"

LOCAL_FORWARD_PORT=$(get_free_local_port)
TEMP_KEY_PATH=$(mktemp /tmp/ssh-key-XXXXXX.pem)
chmod 600 "$TEMP_KEY_PATH"

echo "SSH kulcs letoltese..."

HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$KEY_ENDPOINT" -H "$AUTH_HEADER")
HTTP_BODY=$(echo "$HTTP_RESPONSE" | sed '$d')
HTTP_STATUS=$(echo "$HTTP_RESPONSE" | tail -n1)

if [ "$HTTP_STATUS" -eq 401 ]; then
    echo "Hiba: Hibas jelszo vagy 2FA kod (401 Unauthorized)." >&2
    exit 1
elif [ "$HTTP_STATUS" -ne 200 ]; then
    echo "Hiba: Sikertelen kulcs letoltes. HTTP status: $HTTP_STATUS" >&2
    exit 1
fi

if [ -z "$HTTP_BODY" ]; then
    echo "Hiba: Ures SSH kulcs erkezett a szervertol." >&2
    exit 1
fi

printf "%s\n" "$HTTP_BODY" > "$TEMP_KEY_PATH"

# 4. Start SSH Tunnel in Background
echo "SSH alagut inditasa: $TARGET on local port $LOCAL_FORWARD_PORT to 127.0.0.1:$RDP_PORT"

ssh -i "$TEMP_KEY_PATH" \
    -p "$TARGET_PORT" \
    -o "IdentityAgent=none" \
    -o "ExitOnForwardFailure=yes" \
    -L "$LOCAL_FORWARD_PORT:127.0.0.1:$RDP_PORT" \
    -o "StrictHostKeyChecking=accept-new" \
    -N "$TARGET" &

SSH_PID=$!

# Wait until local tunnel is accepting connections
if ! wait_for_local_port "$LOCAL_FORWARD_PORT"; then
    exit 1
fi

# 5. Launch RDP Client based on detected binary
echo "RDP kapcsolat inditasa ($RDP_CLIENT)..."

case "$RDP_TYPE" in
    xfreerdp)
        # /cert:ignore ignores self-signed RDP certificate prompts
        "$RDP_CLIENT" /v:127.0.0.1:"$LOCAL_FORWARD_PORT" /cert:ignore &
        ;;
    remmina)
        "$RDP_CLIENT" -c "rdp://127.0.0.1:$LOCAL_FORWARD_PORT" &
        ;;
    rdesktop)
        "$RDP_CLIENT" "127.0.0.1:$LOCAL_FORWARD_PORT" &
        ;;
esac

RDP_PID=$!

# Wait for RDP client process to end before finishing script
wait "$RDP_PID"