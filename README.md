# Backhaul Installer

Interactive installer for the supplied Backhaul server/client configurations.

## Install

The installer automatically downloads the official Backhaul Linux release from the
Musixal/Backhaul GitHub releases. The pinned version is `v0.7.2`.

```bash
bash <(curl -Ls https://raw.githubusercontent.com/USERNAME/REPO/main/install.sh)
```

You can override the release if needed:

```bash
BACKHAUL_VERSION=v0.7.2 bash install.sh
```

The installer detects `amd64`, `arm64`, and `armv7` automatically.

## Menu

1. Iran Server
2. Foreign Server
3. Restart
4. Status
5. Uninstall

### Iran Server

Prompts for:

- Domain
- Tunnel port
- Config ports
- Token

Then obtains a Let's Encrypt certificate using Certbot standalone mode and creates:

- `/etc/backhaul/server.toml`
- `/etc/backhaul/cert.crt`
- `/etc/backhaul/private.key`
- `/etc/systemd/system/backhaul.service`

### Foreign Server

Prompts for:

- Iran server domain
- Tunnel port
- Token

Then creates:

- `/etc/backhaul/client.toml`
- `/etc/systemd/system/backhaul.service`

## Important

For the Iran certificate step, the domain must resolve to the Iran server and TCP port 80 must be reachable during certificate issuance.

The installer preserves the tuning values from the supplied configurations. The binary URL is intentionally left as a variable because the uploaded files do not identify a specific Backhaul release/download URL.

## Release source

Backhaul `v0.7.2` is the latest release at the time this installer was prepared.
The installer uses the official Musixal/Backhaul GitHub release assets.
