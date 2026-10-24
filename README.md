# Backhaul Multi-Tunnel Installer v5

Ubuntu/Debian interactive installer for up to 100 independent Backhaul WSSMUX tunnel IDs (default maximum: 10).

## Iran-side behavior
For every tunnel ID, the installer asks for:
- A domain that resolves to this Iran server
- A distinct WSSMUX listening port
- A comma-separated list of Backhaul forwarding rules/ports
- A token shared with the matching foreign/client tunnel

It runs Certbot for that domain and writes the certificate paths directly into that tunnel's TOML:
- `/etc/letsencrypt/live/DOMAIN/fullchain.pem`
- `/etc/letsencrypt/live/DOMAIN/privkey.pem`

Each tunnel has its own config and systemd service: `server-N.toml` and `backhaul-N.service` on Iran; `client-N.toml` and the same service naming on the foreign server.

Forwarding-rule examples from Backhaul's config format: `443`, `4000=5000`, `443=1.1.1.1:5201`, `443-600`, `443-600:5201`.

## Requirements
- DNS for each Iran-side domain must point to the Iran server.
- TCP port 80 must be reachable during Let's Encrypt standalone HTTP validation.
- Each concurrent tunnel must use an available listening port; allow it through host/provider firewalls.
- The foreign/client tunnel must use the same token and tunnel port as its matching Iran-side service.

## Install command after replacing `install.sh` in GitHub
```bash
bash <(curl -fsSL https://raw.githubusercontent.com/mehrdadghadam/back/main/install.sh)
```

This URL runs the version committed to GitHub `main`, not the local ZIP automatically. Replace the repository's `install.sh` and commit it first.

## Validation status
`bash -n` passes. This package has not been end-to-end tested on a live server. Default Backhaul release is v0.7.2. Let's Encrypt certificates are intentionally retained when removing tunnels.
