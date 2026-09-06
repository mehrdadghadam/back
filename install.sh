#!/usr/bin/env bash
set -euo pipefail

# Backhaul interactive installer
# Supports:
#   1) Iran Server  - TLS/WSSMUX server
#   2) Foreign      - WSSMUX client
#
# The installer intentionally keeps the tuning values from the supplied configs.

APP_DIR="/etc/backhaul"
BIN="/usr/local/bin/backhaul"
SERVICE="/etc/systemd/system/backhaul.service"

BACKHAUL_VERSION="${BACKHAUL_VERSION:-v0.7.2}"
DEFAULT_TOKEN="somi"
SERVER_CERT="${APP_DIR}/cert.crt"
SERVER_KEY="${APP_DIR}/private.key"
SERVER_CONFIG="${APP_DIR}/server.toml"
CLIENT_CONFIG="${APP_DIR}/client.toml"

need_root() {
  if [[ "${EUID}" -ne 0 ]]; then
    echo "Please run as root."
    exit 1
  fi
}

pause() {
  read -r -p "Press Enter to continue..." _
}

install_deps() {
  export DEBIAN_FRONTEND=noninteractive
  apt-get update -y
  apt-get install -y curl wget ca-certificates openssl certbot
}

install_backhaul_binary() {
  local version="${BACKHAUL_VERSION:-v0.7.2}"
  local arch
  local asset

  case "$(uname -m)" in
    x86_64|amd64)
      arch="amd64"
      ;;
    aarch64|arm64)
      arch="arm64"
      ;;
    armv7l|armv7)
      arch="armv7"
      ;;
    *)
      echo "[-] Unsupported CPU architecture: $(uname -m)"
      return 1
      ;;
  esac

  asset="backhaul_linux_${arch}.tar.gz"
  local url="https://github.com/Musixal/Backhaul/releases/download/${version}/${asset}"
  local tmp
  tmp="$(mktemp -d)"

  echo "[+] Downloading Backhaul ${version} (${arch})..."
  curl -fL --retry 3 "${url}" -o "${tmp}/${asset}"

  echo "[+] Extracting Backhaul..."
  tar -xzf "${tmp}/${asset}" -C "${tmp}"

  local found
  found="$(find "${tmp}" -type f -name backhaul -perm -u+x | head -n 1 || true)"

  if [[ -z "${found}" ]]; then
    echo "[-] Could not find the backhaul binary in ${asset}"
    rm -rf "${tmp}"
    return 1
  fi

  install -m 0755 "${found}" "${BIN}"
  rm -rf "${tmp}"

  echo "[✓] Backhaul ${version} installed at ${BIN}"
}

write_service() {
  cat > "${SERVICE}" <<EOF
[Unit]
Description=Backhaul Tunnel
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=${BIN} -c %CONFIG_FILE%
Restart=always
RestartSec=3
LimitNOFILE=1048576

[Install]
WantedBy=multi-user.target
EOF
}

enable_service() {
  local config="$1"
  sed -i "s|%CONFIG_FILE%|${config}|g" "${SERVICE}"
  systemctl daemon-reload
  systemctl enable backhaul
  systemctl restart backhaul
}

get_cert() {
  local domain="$1"

  echo
  echo "[+] Getting TLS certificate for ${domain}"
  echo "IMPORTANT: DNS for the domain must point to this server and ports 80/443"
  echo "must be reachable for the selected certificate method."
  echo

  # Standalone certificate. If another service occupies 80, stop it temporarily.
  certbot certonly --standalone \
    --non-interactive \
    --agree-tos \
    --register-unsafely-without-email \
    -d "${domain}"

  cp "/etc/letsencrypt/live/${domain}/fullchain.pem" "${SERVER_CERT}"
  cp "/etc/letsencrypt/live/${domain}/privkey.pem" "${SERVER_KEY}"
  chmod 600 "${SERVER_KEY}"
  chmod 644 "${SERVER_CERT}"
}

write_server_config() {
  local bind_port="$1"
  local token="$2"
  local config_ports="$3"

  IFS=',' read -ra PORTS <<< "${config_ports}"
  local ports_toml=""
  for p in "${PORTS[@]}"; do
    p="$(echo "$p" | xargs)"
    [[ -n "$p" ]] && ports_toml+="${ports_toml:+,}\"${p}\""
  done

  cat > "${SERVER_CONFIG}" <<EOF
[server]
bind_addr = "0.0.0.0:${bind_port}"
transport = "wssmux"
token = "${token}"
keepalive_period = 30
nodelay = true
heartbeat = 15
channel_size = 16384
mux_con = 20
mux_version = 1

# Advanced buffer/socket settings
mux_framesize = 32768
mux_recievebuffer = 8388608
mux_streambuffer = 1048576
mss = 1360
so_rcvbuf = 4194304
so_sndbuf = 1048576
skip_optz = false

tls_cert = "${SERVER_CERT}"
tls_key = "${SERVER_KEY}"
sniffer = false

log_level = "info"
ports = [${ports_toml}]
EOF
}

write_client_config() {
  local remote_domain="$1"
  local remote_port="$2"
  local token="$3"

  cat > "${CLIENT_CONFIG}" <<EOF
[client]
remote_addr = "${remote_domain}:${remote_port}"
edge_ip = ""
transport = "wssmux"
token = "${token}"
keepalive_period = 45
dial_timeout = 10
nodelay = true
retry_interval = 3
connection_pool = 8
aggressive_pool = false
mux_version = 1

# Values matched to the supplied client configuration
mux_framesize = 32768
mux_recievebuffer = 8388608
mux_streambuffer = 1048576

sniffer = false
sniffer_log = "/root/backhaul.json"
log_level = "info"
EOF
}

install_iran() {
  echo
  echo "========================================"
  echo "       IRAN SERVER INSTALLATION"
  echo "========================================"

  read -r -p "Domain: " domain
  read -r -p "Tunnel port [2053]: " tunnel_port
  tunnel_port="${tunnel_port:-2053}"
  read -r -p "Config port(s) [8080,2052]: " config_ports
  config_ports="${config_ports:-8080,2052}"
  read -r -p "Token [${DEFAULT_TOKEN}]: " token
  token="${token:-$DEFAULT_TOKEN}"

  mkdir -p "${APP_DIR}"
  install_deps
  install_backhaul_binary
  get_cert "${domain}"
  write_server_config "${tunnel_port}" "${token}" "${config_ports}"
  write_service
  enable_service "${SERVER_CONFIG}"

  echo
  echo "========================================"
  echo "✓ Iran server installed"
  echo "✓ TLS certificate: ${SERVER_CERT}"
  echo "✓ TLS key:         ${SERVER_KEY}"
  echo "✓ Config:          ${SERVER_CONFIG}"
  echo "✓ Tunnel port:     ${tunnel_port}"
  echo "✓ Config ports:    ${config_ports}"
  echo "========================================"
  systemctl --no-pager --full status backhaul || true
}

install_foreign() {
  echo
  echo "========================================"
  echo "       FOREIGN CLIENT INSTALLATION"
  echo "========================================"

  read -r -p "Iran server domain: " domain
  read -r -p "Tunnel port [2053]: " remote_port
  remote_port="${remote_port:-2053}"
  read -r -p "Token [${DEFAULT_TOKEN}]: " token
  token="${token:-$DEFAULT_TOKEN}"

  mkdir -p "${APP_DIR}"
  install_deps
  install_backhaul_binary
  write_client_config "${domain}" "${remote_port}" "${token}"
  write_service
  enable_service "${CLIENT_CONFIG}"

  echo
  echo "========================================"
  echo "✓ Foreign client installed"
  echo "✓ Config:       ${CLIENT_CONFIG}"
  echo "✓ Remote:       ${domain}:${remote_port}"
  echo "========================================"
  systemctl --no-pager --full status backhaul || true
}

restart_service() {
  systemctl restart backhaul
  systemctl --no-pager --full status backhaul || true
}

status_service() {
  systemctl --no-pager --full status backhaul || true
}

uninstall() {
  echo
  read -r -p "Remove Backhaul, config and service? [y/N]: " answer
  [[ "${answer}" =~ ^[Yy]$ ]] || return 0

  systemctl disable --now backhaul 2>/dev/null || true
  rm -f "${SERVICE}"
  rm -f "${BIN}"
  rm -rf "${APP_DIR}"
  systemctl daemon-reload
  echo "[✓] Backhaul removed."
}

main_menu() {
  need_root

  while true; do
    clear || true
    echo "╔════════════════════════════════════╗"
    echo "║        BACKHAUL INSTALLER          ║"
    echo "╚════════════════════════════════════╝"
    echo
    echo "  1) 🇮🇷 Install Iran Server"
    echo "  2) 🌍 Install Foreign Server"
    echo "  3) 🔄 Restart Backhaul"
    echo "  4) 📊 Service Status"
    echo "  5) 🗑️  Uninstall"
    echo "  0) Exit"
    echo
    read -r -p "Select an option [0-5]: " choice

    case "${choice}" in
      1) install_iran; pause ;;
      2) install_foreign; pause ;;
      3) restart_service; pause ;;
      4) status_service; pause ;;
      5) uninstall; pause ;;
      0) exit 0 ;;
      *) echo "Invalid option."; sleep 1 ;;
    esac
  done
}

main_menu
