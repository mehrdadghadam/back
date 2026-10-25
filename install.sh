#!/usr/bin/env bash
set -Eeuo pipefail
APP_DIR=/etc/backhaul
BIN=/usr/local/bin/backhaul
SYSTEMD_DIR=/etc/systemd/system
MAX_FILE="$APP_DIR/max-tunnels"
VERSION="${BACKHAUL_VERSION:-v0.7.2}"
DEFAULT_TOKEN=somi

need_root(){ [[ $EUID -eq 0 ]] || { echo '[-] Run as root.'; exit 1; }; }
pause(){ read -r -p 'Press Enter to continue...' _; }
service_name(){ echo "backhaul-$1"; }
service_file(){ echo "$SYSTEMD_DIR/$(service_name "$1").service"; }
server_config(){ echo "$APP_DIR/server-$1.toml"; }
client_config(){ echo "$APP_DIR/client-$1.toml"; }
valid_port(){ [[ "$1" =~ ^[0-9]+$ ]] && (( 10#$1 >= 1 && 10#$1 <= 65535 )); }
valid_domain(){ [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ && "$1" == *.* && "$1" != *..* ]]; }

install_deps(){ export DEBIAN_FRONTEND=noninteractive; apt-get update -y; apt-get install -y curl ca-certificates tar certbot openssl; }
install_binary(){
  local arch asset tmp found url
  case "$(uname -m)" in x86_64|amd64) arch=amd64;; aarch64|arm64) arch=arm64;; armv7l|armv7) arch=armv7;; *) echo "[-] Unsupported architecture: $(uname -m)"; return 1;; esac
  asset="backhaul_linux_${arch}.tar.gz"; url="https://github.com/Musixal/Backhaul/releases/download/${VERSION}/${asset}"; tmp=$(mktemp -d)
  echo "[+] Downloading Backhaul $VERSION ($arch)..."
  if ! curl -fL --retry 3 "$url" -o "$tmp/$asset"; then rm -rf "$tmp"; return 1; fi
  tar -xzf "$tmp/$asset" -C "$tmp"
  found=$(find "$tmp" -type f -name backhaul -perm -u+x | head -n 1 || true)
  if [[ -z "$found" ]]; then echo '[-] Binary not found in archive.'; rm -rf "$tmp"; return 1; fi
  install -m 0755 "$found" "$BIN"; rm -rf "$tmp"
}
get_max(){
  local n=''
  [[ -f "$MAX_FILE" ]] && n=$(cat "$MAX_FILE" 2>/dev/null || true)
  if [[ ! "$n" =~ ^([1-9]|[1-9][0-9]|100)$ ]]; then
    read -r -p 'Maximum tunnel IDs [10] (1-100): ' n; n=${n:-10}
    [[ "$n" =~ ^([1-9]|[1-9][0-9]|100)$ ]] || { echo '[-] Choose 1-100.'; return 1; }
    mkdir -p "$APP_DIR"; printf '%s\n' "$n" > "$MAX_FILE"
  fi
  echo "$n"
}
select_id(){
  local max id; max=$(get_max) || return 1
  read -r -p "Tunnel number (1-$max): " id
  [[ "$id" =~ ^[0-9]+$ ]] && (( id >= 1 && id <= max )) || { echo '[-] Invalid tunnel ID.'; return 1; }
  echo "$id"
}
set_max(){ local n; read -r -p 'Maximum tunnel IDs [10] (1-100): ' n; n=${n:-10}; [[ "$n" =~ ^([1-9]|[1-9][0-9]|100)$ ]] || { echo '[-] Choose 1-100.'; return 1; }; mkdir -p "$APP_DIR"; echo "$n" > "$MAX_FILE"; echo "[+] Maximum set to $n."; }

get_cert(){
  local domain="$1"
  local cert_dir="/etc/letsencrypt/live/$domain"

  echo "[+] Using Certbot to issue/check the certificate for: $domain"
  echo "[!] Required: DNS A record points to this Iran server, inbound TCP/80 is open,"
  echo "    and no other service is occupying port 80 during standalone validation."

  if ! command -v certbot >/dev/null 2>&1; then
    echo "[-] Certbot is not installed. Installing it now..."
    export DEBIAN_FRONTEND=noninteractive
    apt-get update -y || return 1
    apt-get install -y certbot || return 1
  fi

  # Certbot standalone needs to bind TCP port 80. Give a clear error before issuance.
  if command -v ss >/dev/null 2>&1 && ss -ltnH '( sport = :80 )' | grep -q .; then
    echo "[-] Something is already listening on TCP port 80:"
    ss -ltnp '( sport = :80 )' || true
    echo "    Stop that web server temporarily, then run the installer again."
    return 1
  fi

  # Reuse the existing Certbot lineage if present; otherwise create it.
  if ! certbot certonly --standalone \
      --non-interactive --agree-tos --register-unsafely-without-email \
      --preferred-challenges http --cert-name "$domain" \
      --keep-until-expiring -d "$domain"; then
    echo "[-] Certbot failed to issue/renew the certificate for $domain."
    echo "    Check DNS, provider firewall/security group, host firewall, and TCP port 80."
    echo "    Detailed Certbot log: /var/log/letsencrypt/letsencrypt.log"
    return 1
  fi

  if [[ ! -s "$cert_dir/fullchain.pem" || ! -s "$cert_dir/privkey.pem" ]]; then
    echo "[-] Certbot returned, but the expected certificate files are missing:"
    echo "    $cert_dir/fullchain.pem"
    echo "    $cert_dir/privkey.pem"
    echo "    Available Certbot lineages:"
    certbot certificates || true
    return 1
  fi

  # Validate that the certificate and key can be read and are a matching pair.
  if ! openssl x509 -in "$cert_dir/fullchain.pem" -noout -subject >/dev/null 2>&1; then
    echo "[-] The Certbot fullchain file is not a readable certificate."
    return 1
  fi
  local cert_pub key_pub
  cert_pub="$(openssl x509 -in "$cert_dir/fullchain.pem" -pubkey -noout 2>/dev/null | openssl pkey -pubin -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  key_pub="$(openssl pkey -in "$cert_dir/privkey.pem" -pubout -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
  if [[ -z "$cert_pub" || -z "$key_pub" || "$cert_pub" != "$key_pub" ]]; then
    echo "[-] The certificate and private key do not match or cannot be read."
    return 1
  fi

  echo "[+] Certbot certificate verified:"
  echo "    Certificate: $cert_dir/fullchain.pem"
  echo "    Private key: $cert_dir/privkey.pem"
}
validate_forward(){
  local raw=$1 item; local -a arr
  [[ -n "$raw" ]] || { echo '[-] Forwarding list cannot be empty.'; return 1; }
  IFS=',' read -r -a arr <<< "$raw"
  for item in "${arr[@]}"; do
    item=$(echo "$item" | xargs)
    [[ "$item" =~ ^[A-Za-z0-9.:-]+(=[A-Za-z0-9.:-]+)?$ ]] || { echo "[-] Invalid forwarding entry: $item"; echo '    Examples: 443, 4000=5000, 443=1.1.1.1:5201, 443-600'; return 1; }
  done
}
install_cert_renew_hook(){
  install -d /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/99-backhaul-restart.sh <<'HOOK'
#!/usr/bin/env bash
shopt -s nullglob
for file in /etc/systemd/system/backhaul-*.service; do
  name=${file##*/}
  name=${name%.service}
  [[ "$name" =~ ^backhaul-[0-9]+$ ]] || continue
  if systemctl is-active --quiet "$name"; then
    systemctl restart "$name" || true
  fi
done
HOOK
  chmod 755 /etc/letsencrypt/renewal-hooks/deploy/99-backhaul-restart.sh
}

write_server_config(){
  local id=$1 domain=$2 port=$3 token=$4 raw=$5 p list='' cfg; local -a arr
  cfg=$(server_config "$id"); IFS=',' read -r -a arr <<< "$raw"
  for p in "${arr[@]}"; do p=$(echo "$p" | xargs); [[ -n "$p" ]] && list+="${list:+, }\"$p\""; done
  cat > "$cfg" <<EOF2
[server]
bind_addr = "0.0.0.0:$port"
transport = "wssmux"
token = "$token"
keepalive_period = 30
nodelay = true
heartbeat = 15
channel_size = 16384
mux_con = 20
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 8388608
mux_streambuffer = 1048576
mss = 1360
so_rcvbuf = 4194304
so_sndbuf = 1048576
skip_optz = false
tls_cert = "/etc/letsencrypt/live/$domain/fullchain.pem"
tls_key = "/etc/letsencrypt/live/$domain/privkey.pem"
sniffer = false
log_level = "info"
ports = [$list]
EOF2
  chmod 600 "$cfg"
}
write_client_config(){
  local id=$1 domain=$2 port=$3 token=$4 cfg; cfg=$(client_config "$id")
  cat > "$cfg" <<EOF2
[client]
remote_addr = "$domain:$port"
edge_ip = ""
transport = "wssmux"
token = "$token"
keepalive_period = 45
dial_timeout = 10
nodelay = true
retry_interval = 3
connection_pool = 8
aggressive_pool = false
mux_version = 1
mux_framesize = 32768
mux_recievebuffer = 8388608
mux_streambuffer = 1048576
sniffer = false
sniffer_log = "/root/backhaul.json"
log_level = "info"
EOF2
  chmod 600 "$cfg"
}
write_service(){ local id=$1 cfg=$2 svc; svc=$(service_file "$id"); cat > "$svc" <<EOF2
[Unit]
Description=Backhaul WSSMUX Tunnel $id
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
ExecStart=$BIN -c $cfg
Restart=always
RestartSec=3
LimitNOFILE=1048576
[Install]
WantedBy=multi-user.target
EOF2
}
enable_service(){ local s; s=$(service_name "$1"); systemctl daemon-reload; systemctl enable "$s"; systemctl restart "$s"; }
install_iran(){
  local id=$1 domain port raw token
  read -r -p "Domain for tunnel $id (must point to this server): " domain; domain=${domain,,}
  valid_domain "$domain" || { echo '[-] Enter a valid hostname, not an IP.'; return 1; }
  read -r -p 'Tunnel listening port [2053]: ' port; port=${port:-2053}; valid_port "$port" || { echo '[-] Invalid tunnel port.'; return 1; }
  read -r -p 'Forwarding ports/rules, comma-separated [8080,2052]: ' raw; raw=${raw:-8080,2052}; validate_forward "$raw" || return 1
  read -r -p "Token [${DEFAULT_TOKEN}]: " token; token=${token:-$DEFAULT_TOKEN}
  [[ "$token" =~ ^[A-Za-z0-9._-]+$ ]] || { echo '[-] Token can use letters, digits, dot, underscore, hyphen only.'; return 1; }
  mkdir -p "$APP_DIR"; install_deps; install_binary; get_cert "$domain" || return 1; install_cert_renew_hook
  write_server_config "$id" "$domain" "$port" "$token" "$raw"; write_service "$id" "$(server_config "$id")"; enable_service "$id"
  echo "[+] Iran tunnel $id installed. Domain=$domain Port=$port Forwarding=$raw"
  echo "    Config: $(server_config "$id")"; echo "    TLS cert: /etc/letsencrypt/live/$domain/fullchain.pem"; echo "    TLS key:  /etc/letsencrypt/live/$domain/privkey.pem"
  systemctl --no-pager --full status "$(service_name "$id")" || true
}
install_foreign(){
  local id=$1 domain port token
  read -r -p 'Iran tunnel domain: ' domain; domain=${domain,,}; valid_domain "$domain" || { echo '[-] Invalid domain.'; return 1; }
  read -r -p 'Iran tunnel port [2053]: ' port; port=${port:-2053}; valid_port "$port" || { echo '[-] Invalid remote port.'; return 1; }
  read -r -p "Token (must match Iran tunnel) [${DEFAULT_TOKEN}]: " token; token=${token:-$DEFAULT_TOKEN}
  [[ "$token" =~ ^[A-Za-z0-9._-]+$ ]] || { echo '[-] Token can use letters, digits, dot, underscore, hyphen only.'; return 1; }
  mkdir -p "$APP_DIR"; install_deps; install_binary; write_client_config "$id" "$domain" "$port" "$token"; write_service "$id" "$(client_config "$id")"; enable_service "$id"
  echo "[+] Foreign client tunnel $id installed. Config: $(client_config "$id")"; systemctl --no-pager --full status "$(service_name "$id")" || true
}
restart_tunnel(){ systemctl restart "$(service_name "$1")"; systemctl --no-pager --full status "$(service_name "$1")" || true; }
status_tunnel(){ systemctl --no-pager --full status "$(service_name "$1")" || true; }
logs_tunnel(){ journalctl -u "$(service_name "$1")" -n 100 --no-pager; }
remove_tunnel(){ local id=$1 answer; read -r -p "Remove tunnel $id and its config? [y/N]: " answer; [[ "$answer" =~ ^[Yy]$ ]] || return 0; systemctl disable --now "$(service_name "$id")" 2>/dev/null || true; rm -f "$(service_file "$id")" "$(server_config "$id")" "$(client_config "$id")"; systemctl daemon-reload; echo '[+] Removed. Certificate intentionally retained.'; }
remove_all(){ local answer file id; read -r -p 'Remove all numeric tunnel services/configs and binary? [y/N]: ' answer; [[ "$answer" =~ ^[Yy]$ ]] || return 0; shopt -s nullglob; for file in "$SYSTEMD_DIR"/backhaul-*.service; do id=${file##*/backhaul-}; id=${id%.service}; [[ "$id" =~ ^[0-9]+$ ]] || continue; systemctl disable --now "$(service_name "$id")" 2>/dev/null || true; rm -f "$file" "$(server_config "$id")" "$(client_config "$id")"; done; shopt -u nullglob; rm -f "$BIN"; rm -rf "$APP_DIR"; systemctl daemon-reload; echo '[+] Removed tunnel services/configs and binary. Certificates retained.'; }
main(){
  need_root
  while true; do
    clear || true
    echo '========== BACKHAUL MULTI-TUNNEL =========='
    echo '1) Install Iran tunnel (domain + SSL + forwarding)'
    echo '2) Install foreign/client tunnel'
    echo '3) Restart tunnel'
    echo '4) Tunnel status'
    echo '5) Tunnel logs'
    echo '6) Remove one tunnel'
    echo '7) Remove all numeric tunnels'
    echo '8) Set maximum tunnel IDs (1-100)'
    echo '0) Exit'
    read -r -p 'Choose [0-8]: ' choice
    case "$choice" in
      1) id=$(select_id) || { pause; continue; }; install_iran "$id" || true; pause;;
      2) id=$(select_id) || { pause; continue; }; install_foreign "$id" || true; pause;;
      3) id=$(select_id) || { pause; continue; }; restart_tunnel "$id"; pause;;
      4) id=$(select_id) || { pause; continue; }; status_tunnel "$id"; pause;;
      5) id=$(select_id) || { pause; continue; }; logs_tunnel "$id"; pause;;
      6) id=$(select_id) || { pause; continue; }; remove_tunnel "$id"; pause;;
      7) remove_all; pause;;
      8) set_max || true; pause;;
      0) exit 0;;
      *) echo 'Invalid option.'; sleep 1;;
    esac
  done
}
main
