#!/usr/bin/env bash

# Parameter defaults (using template placeholders or environment variables if set)
BASE_URL="!<<ENV_BASE_URL>>"
TARGET="!<<ENV_TARGET>>"
TARGET_PORT="!<<ENV_SSH_PORT>>"
REMOTE_COMMAND="${4:-}"

# Fail immediately on unset variable usage
set -u

# Cleanup function to ensure temporary SSH key removal
TEMP_KEY_PATH=""
cleanup() {
    if [ -n "$TEMP_KEY_PATH" ] && [ -f "$TEMP_KEY_PATH" ]; then
        rm -f "$TEMP_KEY_PATH"
    fi
}
# Trap exit, interrupt, and terminate signals to ensure cleanup runs
trap cleanup EXIT INT TERM

# 1. Prompt for Password (hidden input)
read -rs -p "Jelszo: " PASSWORD </dev/tty
echo ""

if [ -z "$PASSWORD" ]; then
    echo "Hiba: A jelszo nem lehet ures." >&2
    exit 1
fi

# 2. Prompt for 2FA OTP
read -r -p "2FA kod (6 szamjegy): " OTP </dev/tty

if [[ ! "$OTP" =~ ^[0-9]{6}$ ]]; then
    echo "Hiba: A 2FA kodnak pontosan 6 szamjegynek kell lennie." >&2
    exit 1
fi

# 3. Construct endpoint and auth header
NORMALIZED_BASE="${BASE_URL%/}"
KEY_ENDPOINT="${NORMALIZED_BASE}/key"
AUTH_HEADER="Authorization: Bearer ${PASSWORD}:${OTP}"

# Create secure temporary file for the SSH private key
TEMP_KEY_PATH=$(mktemp /tmp/ssh-key-XXXXXX.pem)
# Set strict permissions (600 = read/write only for owner, required by SSH)
chmod 600 "$TEMP_KEY_PATH"

echo "SSH kulcs letoltese..."

# 4. Fetch the private key using curl with HTTP status code checking
HTTP_RESPONSE=$(curl -s -w "\n%{http_code}" -X GET "$KEY_ENDPOINT" -H "$AUTH_HEADER")

# Separate body and status code
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

# Write the private key to the temporary file
printf "%s\n" "$HTTP_BODY" > "$TEMP_KEY_PATH"

# 5. Prepare SSH options
SSH_ARGS=(
    "-i" "$TEMP_KEY_PATH"
    "-p" "$TARGET_PORT"
    "-o" "IdentityAgent=none"
    "-o" "StrictHostKeyChecking=accept-new"
    "$TARGET"
)

if [ -n "$REMOTE_COMMAND" ]; then
    SSH_ARGS+=("$REMOTE_COMMAND")
fi

echo "SSH kapcsolat inditasa: $TARGET"

# Execute SSH session
ssh "${SSH_ARGS[@]}"