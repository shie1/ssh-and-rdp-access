# SSH and RDP Access

A small Node.js service that generates short-lived SSH keys and serves PowerShell launch scripts for SSH access and RDP-over-SSH access.

The workflow is simple:

1. Start the server.
2. Request a launch script from the service.
3. Run the script on a Windows machine.
4. Authenticate with your password and 2FA code.
5. Receive a temporary SSH key and connect to the target.

## Features

- Temporary SSH key generation via `/key`
- SSH launcher script via `/`
- RDP launcher script via `/rdp`
- OTP code generation via `/otp`
- Automatic cleanup of generated keys

## Requirements

- Node.js 18+ recommended
- Yarn or npm
- SSH client available on the Windows machine that runs the PowerShell scripts
- `mstsc.exe` for the RDP launcher
- A target machine that accepts SSH connections and, for the RDP flow, exposes RDP on port 3389 or the port configured in `RDP_PORT`

## Configuration

Create a `.env` file in the project root.

```env
SSH_DIR=~/.ssh/ [optional, default=~/.ssh/]

PASSWORD= [mandatory]

OTP_LABEL=Uncofigured [optional, default=Unconfigured]
OTP_ISSUER=SSH&RDP [optional, default=SSH&RDP]
OTP_SECRET=RQWW3RBDFWLhg5KPDO7JZDIH5DVZMJBL2P [mandatory]
OTP_CODE_ENABLED=true|false [optional, default=false]
# for 2FA setup on first startup, set to true to view the QR code and generate the OTP secret, then set to false for normal operation

TARGET=user@IP_ADDRESS [mandatory]

SSH_PORT=22 [optional, default=22]
RDP_PORT=3389 [optional, default=3389]

PORT=3000 [optional, default=3000]
BASE_URL=http://localhost:3000 [mandatory]
# the base URL of the server, including the port number
```

### Environment variables

- `SSH_KEY_PATH`: Path to the local SSH directory that contains `authorized_keys`
- `PASSWORD`: Shared password used to authorize key generation
- `OTP_CODE_ENABLED`: Enables or disables the `/otp` endpoint
- `OTP_SECRET`: TOTP secret used to validate requests
- `OTP_ISSUER`: TOTP issuer name
- `OTP_LABEL`: TOTP label
- `TARGET`: SSH destination, for example `user@host.example.com`
- `TARGET_PORT`: SSH port on the target host
- `RDP_PORT`: RDP port on the target host
- `BASE_URL`: Public base URL used when the scripts call back to the server

## Development

Install dependencies and start the server:

```bash
yarn install
yarn dev
```

Build the TypeScript project:

```bash
yarn build
```

Run the compiled server:

```bash
yarn start
```

## Endpoints

### `GET /`

Returns the PowerShell script for standard SSH access.

### `GET /rdp`

Returns the PowerShell script for RDP access over an SSH tunnel.

### `GET /key`

Returns a temporary SSH private key when the request includes the correct `Authorization` header.

### `GET /otp`

Returns the current TOTP value or a QR/SVG representation, depending on query parameters and configuration.

## PowerShell launch scripts

The generated scripts prompt for:

- Password
- 2FA code

They then download a temporary SSH key from the server and launch the appropriate client flow.

### SSH script

The SSH script connects directly to the target host.

### RDP script

The RDP script:

1. Downloads a temporary SSH key.
2. Opens an SSH tunnel from a local random port to the target host's RDP port.
3. Launches Remote Desktop Connection against the local forwarded port.
4. Keeps the tunnel alive for the duration of the RDP session.

## Notes

- The project clears managed SSH keys from `authorized_keys` on startup.
- Temporary SSH keys are deleted automatically after use.
- The RDP script expects the target machine's RDP service to be reachable on the host specified by `TARGET`.

