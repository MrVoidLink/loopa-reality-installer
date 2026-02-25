#!/bin/bash
set -euo pipefail

# Loopa Xray Setup Wizard (v5.0)
# Types:
# - VLESS + TCP + REALITY
# - VLESS + TCP + none (no TLS)

CONFIG="/usr/local/etc/xray/config.json"
DATA_DIR="$HOME"
STATS_SERVICE="/etc/systemd/system/loopa-stats-api.service"
STATS_SERVICE_NAME="loopa-stats-api"
STATS_SCRIPT="/usr/local/bin/loopa-stats-api.py"
XRAY_INSTALL_URL="https://github.com/XTLS/Xray-install/raw/main/install-release.sh"

err() { echo "ERROR: $*" >&2; exit 1; }
has() { command -v "$1" >/dev/null 2>&1; }

require_root() {
  if [ "${EUID:-$(id -u)}" -ne 0 ]; then
    err "Please run this script as root."
  fi
}

clean_input() {
  local value="$1"
  echo "$value" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -e 's/[[:space:]]//g'
}

validate_port() {
  local port="$1"
  [[ "$port" =~ ^[0-9]+$ ]] || err "Port must be numeric."
  (( port >= 1 && port <= 65535 )) || err "Port must be between 1 and 65535."
}

validate_domain() {
  local value="$1"
  printf %s "$value" | LC_ALL=C grep -qP '[^\x00-\x7F]' && err "Input contains non-ASCII characters."
  echo "$value" | grep -Eq '^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$' || err "Invalid domain format: $value"
}

detect_public_ip() {
  local ip=""

  # Optional override for non-standard network setups.
  if [ -n "${LOOPA_SERVER_ADDR:-}" ]; then
    ip=$(echo "${LOOPA_SERVER_ADDR}" | tr -d ' \r\n')
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  fi

  # Prefer the server IP used in the current SSH session:
  # SSH_CONNECTION format: "<client_ip> <client_port> <server_ip> <server_port>"
  if [ -n "${SSH_CONNECTION:-}" ]; then
    ip=$(echo "$SSH_CONNECTION" | awk '{print $3}')
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  fi

  local urls=(
    "https://api.ipify.org"
    "https://ipv4.icanhazip.com"
    "https://ifconfig.me/ip"
  )
  for url in "${urls[@]}"; do
    ip=$(curl -4fsS "$url" 2>/dev/null | tr -d '\r\n' || true)
    if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
      echo "$ip"
      return 0
    fi
  done

  ip=$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | head -n1 || true)
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$ip"
    return 0
  fi

  ip=$(hostname -I 2>/dev/null | awk '{print $1}' || true)
  if [[ "$ip" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]]; then
    echo "$ip"
    return 0
  fi
  return 1
}

encode_link_name() {
  local name="$1"
  echo "${name// /%20}"
}

ensure_packages() {
  local required=(jq qrencode openssl curl)
  for pkg in "${required[@]}"; do
    if ! has "$pkg"; then
      apt update -y
      apt install -y "$pkg"
    fi
  done
}

ensure_xray() {
  if ! has xray; then
    bash <(curl -L "$XRAY_INSTALL_URL") install
  fi
}

ensure_config() {
  mkdir -p "$(dirname "$CONFIG")"
  if [ ! -f "$CONFIG" ]; then
    cat > "$CONFIG" <<'JSON'
{
  "inbounds": [],
  "outbounds": [
    { "protocol": "freedom", "settings": {} }
  ]
}
JSON
  else
    if ! jq -e '.inbounds' "$CONFIG" >/dev/null 2>&1; then
      jq '. + {inbounds: []}' "$CONFIG" > /tmp/xray_cfg_tmp && mv /tmp/xray_cfg_tmp "$CONFIG"
    fi
    if ! jq -e '.outbounds' "$CONFIG" >/dev/null 2>&1; then
      jq '. + {outbounds: [{protocol:"freedom",settings:{}}]}' "$CONFIG" > /tmp/xray_cfg_tmp && mv /tmp/xray_cfg_tmp "$CONFIG"
    fi
  fi
}

tag_exists() {
  local tag="$1"
  jq -e --arg tag "$tag" '.inbounds[]? | select((.tag // "") == $tag)' "$CONFIG" >/dev/null 2>&1
}

port_exists() {
  local port="$1"
  jq -e --argjson p "$port" '.inbounds[]? | select((.port // -1) == $p)' "$CONFIG" >/dev/null 2>&1
}

ensure_tag_port_free() {
  local tag="$1"
  local port="$2"
  if port_exists "$port"; then
    err "Port $port already exists in xray inbounds."
  fi
  if tag_exists "$tag"; then
    err "Tag '$tag' already exists in xray inbounds."
  fi
}

restart_xray() {
  systemctl restart xray
  sleep 1
  systemctl is-active --quiet xray
}

firewall_status() {
  if ! has ufw; then
    echo "Firewall tool (ufw) not installed."
    return 1
  fi
  ufw status 2>/dev/null | head -n1
}

firewall_menu() {
  if ! has ufw; then
    apt update -y && apt install -y ufw
  fi

  while true; do
    clear
    STATUS_LINE=$(firewall_status)
    STATUS_STATE=$(echo "$STATUS_LINE" | awk '{print $2}')
    echo "Firewall (ufw)"
    echo "=============="
    echo "$STATUS_LINE"
    if [ "$STATUS_STATE" = "active" ]; then
      echo "1) Turn OFF firewall"
    else
      echo "1) Turn ON firewall"
    fi
    echo "2) Open a port (allow)"
    echo "3) Close a port (delete allow)"
    echo "4) List rules"
    echo "5) Back to main menu"
    read -rp "Choose [1-5]: " FWCHOICE

    case $FWCHOICE in
      1)
        if [ "$STATUS_STATE" = "active" ]; then
          ufw disable
          echo "Firewall turned OFF."
        else
          ufw --force enable
          echo "Firewall turned ON."
        fi
        sleep 1
        ;;
      2)
        if [ "$STATUS_STATE" != "active" ]; then
          ufw --force enable
          STATUS_STATE="active"
        fi
        read -rp "Enter port to open (e.g. 443): " FWPORT
        [ -z "$FWPORT" ] && { echo "No port entered."; sleep 1; continue; }
        ufw allow "${FWPORT}/tcp"
        echo "Allowed TCP port $FWPORT."
        sleep 1
        ;;
      3)
        if [ "$STATUS_STATE" != "active" ]; then
          echo "Firewall is OFF. Nothing to close."
          sleep 1
          continue
        fi
        read -rp "Enter port to close (delete allow): " FWPORT
        [ -z "$FWPORT" ] && { echo "No port entered."; sleep 1; continue; }
        if echo y | ufw delete allow "${FWPORT}/tcp"; then
          echo "Closed TCP port $FWPORT."
        else
          echo "Failed to close port $FWPORT."
        fi
        sleep 1
        ;;
      4)
        clear
        ufw status numbered
        echo ""
        read -rp "Press Enter to return..." _
        ;;
      5)
        break
        ;;
      *)
        echo "Invalid firewall option."
        sleep 1
        ;;
    esac
  done
}

stats_service_status() {
  if [ ! -f "$STATS_SERVICE" ]; then
    echo "not installed"
    return 0
  fi
  if systemctl is-active --quiet "$STATS_SERVICE_NAME"; then
    echo "running"
    return 0
  fi
  echo "stopped"
}

install_stats_api() {
  if ! has python3; then
    apt update -y && apt install -y python3
  fi

  read -rp "Bind address [127.0.0.1]: " STATS_BIND
  STATS_BIND=${STATS_BIND:-127.0.0.1}
  read -rp "Port [8799]: " STATS_PORT
  STATS_PORT=${STATS_PORT:-8799}
  read -rp "API key (optional, leave empty for no auth): " STATS_KEY
  read -rp "Allowed IP/CIDR (optional, leave empty for any): " STATS_ALLOW_IP

  cat > "$STATS_SCRIPT" <<'PY'
#!/usr/bin/env python3
import json
import os
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
from urllib.parse import urlparse, parse_qs

BIND = os.environ.get("LOOPA_STATS_BIND", "127.0.0.1")
PORT = int(os.environ.get("LOOPA_STATS_PORT", "8799"))
API_KEY = os.environ.get("LOOPA_STATS_API_KEY", "")

def read_cpu_percent():
  def read_stat():
    with open("/proc/stat", "r", encoding="utf-8") as f:
      parts = f.readline().strip().split()[1:]
    nums = [int(x) for x in parts[:8]]
    idle = nums[3] + nums[4]
    total = sum(nums)
    return total, idle
  total1, idle1 = read_stat()
  time.sleep(0.12)
  total2, idle2 = read_stat()
  total_delta = total2 - total1
  idle_delta = idle2 - idle1
  if total_delta <= 0:
    return 0.0
  return round((1 - (idle_delta / total_delta)) * 100, 2)

def read_mem_percent():
  mem_total = 0
  mem_available = 0
  with open("/proc/meminfo", "r", encoding="utf-8") as f:
    for line in f:
      if line.startswith("MemTotal:"):
        mem_total = int(line.split()[1])
      elif line.startswith("MemAvailable:"):
        mem_available = int(line.split()[1])
  if mem_total <= 0:
    return 0.0
  used = mem_total - mem_available
  return round((used / mem_total) * 100, 2)

def read_load_avg():
  with open("/proc/loadavg", "r", encoding="utf-8") as f:
    return float(f.read().split()[0])

class Handler(BaseHTTPRequestHandler):
  def _unauthorized(self):
    self.send_response(401)
    self.send_header("Content-Type", "application/json")
    self.end_headers()
    self.wfile.write(b"{\"error\":\"unauthorized\"}")

  def _authorized(self):
    if not API_KEY:
      return True
    provided = self.headers.get("X-API-Key", "")
    if provided == API_KEY:
      return True
    parsed = urlparse(self.path)
    token = parse_qs(parsed.query).get("token", [""])[0]
    return token == API_KEY

  def do_GET(self):
    parsed = urlparse(self.path)
    if parsed.path not in ("/", "/stats"):
      self.send_response(404)
      self.end_headers()
      return
    if not self._authorized():
      self._unauthorized()
      return
    payload = {
      "cpu_usage": read_cpu_percent(),
      "ram_usage": read_mem_percent(),
      "load_avg_1m": read_load_avg(),
    }
    body = json.dumps(payload).encode("utf-8")
    self.send_response(200)
    self.send_header("Content-Type", "application/json")
    self.send_header("Content-Length", str(len(body)))
    self.end_headers()
    self.wfile.write(body)

  def log_message(self, format, *args):
    return

def main():
  server = HTTPServer((BIND, PORT), Handler)
  server.serve_forever()

if __name__ == "__main__":
  main()
PY

  chmod +x "$STATS_SCRIPT"

  cat > "$STATS_SERVICE" <<EOF
[Unit]
Description=Loopa Stats API
After=network.target

[Service]
Type=simple
Environment=LOOPA_STATS_BIND=$STATS_BIND
Environment=LOOPA_STATS_PORT=$STATS_PORT
Environment=LOOPA_STATS_API_KEY=$STATS_KEY
ExecStart=/usr/bin/python3 $STATS_SCRIPT
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$STATS_SERVICE_NAME"

  if has ufw; then
    if ufw status 2>/dev/null | head -n1 | grep -q "active"; then
      if [ -n "$STATS_ALLOW_IP" ]; then
        ufw allow from "$STATS_ALLOW_IP" to any port "$STATS_PORT" proto tcp
      else
        ufw allow "${STATS_PORT}/tcp"
      fi
    fi
  fi

  echo "Stats API running on http://$STATS_BIND:$STATS_PORT"
  if [ -n "$STATS_KEY" ]; then
    echo "Use X-API-Key header or ?token=$STATS_KEY"
  fi
  read -rp "Press Enter to return..." _
}

remove_stats_api() {
  systemctl disable --now "$STATS_SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$STATS_SERVICE"
  rm -f "$STATS_SCRIPT"
  systemctl daemon-reload
  echo "Stats API removed."
  read -rp "Press Enter to return..." _
}

show_stats_settings() {
  if [ ! -f "$STATS_SERVICE" ]; then
    echo "Stats API is not installed."
    read -rp "Press Enter to return..." _
    return
  fi
  echo "Current Stats API settings:"
  grep -E "^Environment=LOOPA_STATS_" "$STATS_SERVICE" || true
  read -rp "Press Enter to return..." _
}

stats_api_menu() {
  while true; do
    clear
    STATUS=$(stats_service_status)
    echo "Loopa Stats API"
    echo "==============="
    echo "Status: $STATUS"
    echo "1) Install/Update and start"
    echo "2) Stop and remove"
    echo "3) Show settings"
    echo "4) Back to main menu"
    read -rp "Choose [1-4]: " STATSCHOICE

    case $STATSCHOICE in
      1) install_stats_api ;;
      2) remove_stats_api ;;
      3) show_stats_settings ;;
      4) break ;;
      *)
        echo "Invalid choice."
        sleep 1
        ;;
    esac
  done
}

list_config_files() {
  local files=()
  shopt -s nullglob
  files=( "$DATA_DIR"/loopa-reality-*.txt "$DATA_DIR"/loopa-vless-*.txt )
  shopt -u nullglob
  printf '%s\n' "${files[@]}"
}

show_existing_configs() {
  clear
  echo "Available Loopa configs:"
  mapfile -t FILES < <(list_config_files)
  if [ ${#FILES[@]} -eq 0 ]; then
    echo "No configs found yet."
    read -rp "Press Enter to return..." _
    return
  fi

  local i=1
  for f in "${FILES[@]}"; do
    echo "  $i) $(basename "$f")"
    ((i++))
  done
  echo ""
  read -rp "Select a config number: " NUM
  local IDX=$((NUM-1))
  if [ -z "${FILES[$IDX]:-}" ]; then
    echo "Invalid choice."
    sleep 1
    return
  fi

  local FILE="${FILES[$IDX]}"
  local LINK
  LINK=$(grep -E '^(Reality Link|VLESS Link):' "$FILE" | sed -E 's/^[^:]+:[[:space:]]*//' | head -n1 || true)
  if [ -z "$LINK" ]; then
    LINK=$(grep -Eo 'vless://[^[:space:]]+' "$FILE" | head -n1 || true)
  fi

  clear
  echo "Showing config: $(basename "$FILE")"
  if [ -z "$LINK" ]; then
    echo "No link found in file."
  else
    echo ""
    echo "$LINK"
    echo ""
    if has qrencode; then
      qrencode -t ansiutf8 "$LINK"
    else
      echo "qrencode is not installed."
    fi
  fi
  echo ""
  read -rp "Press Enter to return..." _
}

delete_existing_config() {
  clear
  echo "Delete existing config"
  mapfile -t FILES < <(list_config_files)
  if [ ${#FILES[@]} -eq 0 ]; then
    echo "No configs found yet."
    sleep 1
    return
  fi

  local i=1
  for f in "${FILES[@]}"; do
    echo "  $i) $(basename "$f")"
    ((i++))
  done
  echo ""
  read -rp "Select a config number to delete: " NUM
  local IDX=$((NUM-1))
  if [ -z "${FILES[$IDX]:-}" ]; then
    echo "Invalid choice."
    sleep 1
    return
  fi

  local FILE="${FILES[$IDX]}"
  local TAG_TO_DEL PORT_TO_DEL PRIV_TO_DEL CLIENT_JSON
  TAG_TO_DEL=$(awk -F': ' '/^Tag:/ {print $2; exit}' "$FILE")
  PORT_TO_DEL=$(awk -F': ' '/^Port:/ {print $2; exit}' "$FILE")
  PRIV_TO_DEL=$(awk -F': ' '/^PrivateKeyFile:/ {print $2; exit}' "$FILE")
  CLIENT_JSON=$(awk -F': ' '/^ClientConfigFile:/ {print $2; exit}' "$FILE")

  if [ -z "$TAG_TO_DEL" ] && [ -n "$PORT_TO_DEL" ]; then
    case "$(basename "$FILE")" in
      loopa-reality-*) TAG_TO_DEL="reality-$PORT_TO_DEL" ;;
      loopa-vless-*) TAG_TO_DEL="vless-$PORT_TO_DEL" ;;
    esac
  fi

  echo "Selected: $(basename "$FILE")"
  read -rp "Are you sure? [y/N]: " DELCHOICE
  if [[ ! "$DELCHOICE" =~ ^[Yy]$ ]]; then
    return
  fi

  if [ -f "$CONFIG" ] && [ -n "$TAG_TO_DEL" ]; then
    local TMPDEL
    TMPDEL=$(mktemp)
    if jq --arg tag "$TAG_TO_DEL" '
      if (.inbounds // null) then
        .inbounds = [ (.inbounds[]? | select(.tag != $tag)) ]
      else .
      end
    ' "$CONFIG" > "$TMPDEL"; then
      mv "$TMPDEL" "$CONFIG"
      echo "Removed inbound with tag: $TAG_TO_DEL"
      restart_xray || true
    else
      echo "Failed to update $CONFIG"
      rm -f "$TMPDEL"
    fi
  else
    echo "No valid tag found to delete."
  fi

  [ -n "${PRIV_TO_DEL:-}" ] && [ -f "$PRIV_TO_DEL" ] && rm -f "$PRIV_TO_DEL"
  [ -n "${CLIENT_JSON:-}" ] && [ -f "$CLIENT_JSON" ] && rm -f "$CLIENT_JSON"
  rm -f "$FILE"
  echo "Config deleted."
  sleep 1
}

create_reality_inbound() {
  clear
  echo "Create new Reality inbound"
  read -rp "Enter port number (e.g. 443): " PORT
  validate_port "$PORT"

  read -rp "Enter your domain (e.g. vpn.loopa-vpn.com): " DOMAIN
  read -rp "Enter camouflage SNI (e.g. www.microsoft.com): " CAMO
  read -rp "Enter tag name (default: reality-$PORT): " TAG
  TAG=${TAG:-reality-$PORT}

  DOMAIN=$(clean_input "$DOMAIN")
  CAMO=$(clean_input "$CAMO")
  validate_domain "$DOMAIN"
  validate_domain "$CAMO"

  ensure_packages
  ensure_xray
  ensure_config
  ensure_tag_port_free "$TAG" "$PORT"

  echo "Generating X25519 keypair..."
  XOUT=$(xray x25519 2>/dev/null || true)
  PRIV=$(echo "$XOUT" | awk -F': ' '/[Pp]rivate/ {print $2; exit}' | tr -d '\r\n')
  PUB=$(echo "$XOUT" | awk -F': ' '/Password|Public key|PublicKey/ {print $2; exit}' | tr -d '\r\n')
  [ -z "$PRIV" ] && err "Failed to read private key."
  SHORTID=$(openssl rand -hex 8)
  UUID=$(cat /proc/sys/kernel/random/uuid)

  PRIVFILE="/usr/local/etc/xray/reality-priv-${PORT}.key"
  echo -n "$PRIV" > "$PRIVFILE"
  chmod 600 "$PRIVFILE"

  INBOUND=$(jq -n \
    --arg port "$PORT" --arg tag "$TAG" --arg id "$UUID" \
    --arg priv "$PRIV" --arg short "$SHORTID" --arg camo "$CAMO" '
    {
      port: ($port|tonumber),
      protocol: "vless",
      tag: $tag,
      settings: { clients: [{ id: $id }], decryption: "none" },
      streamSettings: {
        network: "tcp",
        security: "reality",
        realitySettings: {
          privateKey: $priv,
          shortIds: [$short],
          serverNames: [$camo],
          dest: ($camo + ":443"),
          show: false,
          spiderX: "/"
        }
      }
    }')

  TMP=$(mktemp)
  jq ".inbounds += [ $INBOUND ]" "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

  chmod 644 "$CONFIG"
  restart_xray || err "xray service failed to start."

  LINK="vless://${UUID}@${DOMAIN}:${PORT}?security=reality&sni=${CAMO}&pbk=${PUB}&sid=${SHORTID}&fp=chrome&type=tcp#${TAG}"
  INFO_FILE="$DATA_DIR/loopa-reality-${PORT}.txt"

  cat > "$INFO_FILE" <<EOF
Tag: $TAG
Port: $PORT
Domain: $DOMAIN
SNI: $CAMO
UUID: $UUID
PublicKey: $PUB
PrivateKeyFile: $PRIVFILE
ShortId: $SHORTID
Reality Link: $LINK
EOF

  echo ""
  echo "VLESS REALITY LINK:"
  echo "$LINK"
  echo ""
  qrencode -t ansiutf8 "$LINK"
  echo ""
  echo "Saved info to: $INFO_FILE"
  read -rp "Press Enter to return..." _
}

create_vless_tcp_inbound() {
  clear
  echo "Create new VLESS TCP inbound (security=none)"
  read -rp "Enter port number (e.g. 443): " PORT
  validate_port "$PORT"

  read -rp "Enter tag name (default: vless-$PORT): " TAG
  TAG=${TAG:-vless-$PORT}
  read -rp "Enter UUID (leave empty to auto-generate): " UUID
  UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid)}
  read -rp "Enter link name (default: $TAG): " LINK_NAME
  LINK_NAME=${LINK_NAME:-$TAG}
  SAFE_LINK_NAME=$(encode_link_name "$LINK_NAME")

  SERVER_ADDR=$(detect_public_ip || true)
  [ -z "${SERVER_ADDR:-}" ] && err "Could not detect server public IPv4 address automatically."
  echo "Detected server address: $SERVER_ADDR"

  ensure_packages
  ensure_xray
  ensure_config
  ensure_tag_port_free "$TAG" "$PORT"

  INBOUND=$(jq -n \
    --arg port "$PORT" --arg tag "$TAG" --arg id "$UUID" '
    {
      port: ($port|tonumber),
      listen: "0.0.0.0",
      protocol: "vless",
      tag: $tag,
      settings: {
        clients: [{ id: $id, level: 8 }],
        decryption: "none"
      },
      streamSettings: {
        network: "tcp",
        security: "none",
        tcpSettings: {
          header: { type: "none" }
        }
      }
    }')

  TMP=$(mktemp)
  jq ".inbounds += [ $INBOUND ]" "$CONFIG" > "$TMP" && mv "$TMP" "$CONFIG"

  chmod 644 "$CONFIG"
  restart_xray || err "xray service failed to start."

  LINK="vless://${UUID}@${SERVER_ADDR}:${PORT}?encryption=none&security=none&type=tcp&headerType=none#${SAFE_LINK_NAME}"
  INFO_FILE="$DATA_DIR/loopa-vless-${PORT}.txt"
  CLIENT_JSON_FILE="$DATA_DIR/loopa-vless-client-${PORT}.json"

  cat > "$CLIENT_JSON_FILE" <<EOF
{
  "log": {
    "loglevel": "warning"
  },
  "dns": {
    "hosts": {
      "dns.google": [
        "8.8.8.8",
        "8.8.4.4",
        "2001:4860:4860::8888",
        "2001:4860:4860::8844"
      ],
      "dns.alidns.com": [
        "223.5.5.5",
        "223.6.6.6",
        "2400:3200::1",
        "2400:3200:baba::1"
      ],
      "one.one.one.one": [
        "1.1.1.1",
        "1.0.0.1",
        "2606:4700:4700::1111",
        "2606:4700:4700::1001"
      ],
      "1dot1dot1dot1.cloudflare-dns.com": [
        "1.1.1.1",
        "1.0.0.1",
        "2606:4700:4700::1111",
        "2606:4700:4700::1001"
      ],
      "cloudflare-dns.com": [
        "104.16.249.249",
        "104.16.248.249",
        "2606:4700::6810:f8f9",
        "2606:4700::6810:f9f9"
      ],
      "dns.cloudflare.com": [
        "104.16.132.229",
        "104.16.133.229",
        "2606:4700::6810:84e5",
        "2606:4700::6810:85e5"
      ],
      "dot.pub": [
        "1.12.12.12",
        "120.53.53.53"
      ],
      "doh.pub": [
        "1.12.12.12",
        "120.53.53.53"
      ],
      "dns.quad9.net": [
        "9.9.9.9",
        "149.112.112.112",
        "2620:fe::fe",
        "2620:fe::9"
      ],
      "dns.yandex.net": [
        "77.88.8.8",
        "77.88.8.1",
        "2a02:6b8::feed:0ff",
        "2a02:6b8:0:1::feed:0ff"
      ],
      "dns.sb": [
        "185.222.222.222",
        "2a09::"
      ],
      "dns.umbrella.com": [
        "208.67.220.220",
        "208.67.222.222",
        "2620:119:35::35",
        "2620:119:53::53"
      ],
      "dns.sse.cisco.com": [
        "208.67.220.220",
        "208.67.222.222",
        "2620:119:35::35",
        "2620:119:53::53"
      ],
      "engage.cloudflareclient.com": [
        "162.159.192.1",
        "2606:4700:d0::a29f:c001"
      ]
    },
    "servers": [
      {
        "address": "https://dns.alidns.com/dns-query",
        "domains": [
          "domain:alidns.com",
          "domain:doh.pub",
          "domain:dot.pub",
          "domain:360.cn",
          "domain:onedns.net"
        ],
        "skipFallback": true
      },
      {
        "address": "https://cloudflare-dns.com/dns-query",
        "domains": [
          "geosite:google"
        ],
        "skipFallback": true
      },
      {
        "address": "https://dns.alidns.com/dns-query",
        "domains": [
          "geosite:private",
          "geosite:cn"
        ],
        "skipFallback": true
      },
      {
        "address": "223.5.5.5",
        "domains": [
          "full:dns.alidns.com",
          "full:cloudflare-dns.com"
        ],
        "skipFallback": true
      },
      "https://cloudflare-dns.com/dns-query"
    ]
  },
  "inbounds": [
    {
      "tag": "socks",
      "port": 10808,
      "listen": "127.0.0.1",
      "protocol": "mixed",
      "sniffing": {
        "enabled": true,
        "destOverride": [
          "http",
          "tls"
        ],
        "routeOnly": false
      },
      "settings": {
        "auth": "noauth",
        "udp": true,
        "allowTransparent": false
      }
    }
  ],
  "outbounds": [
    {
      "tag": "proxy",
      "protocol": "vless",
      "settings": {
        "vnext": [
          {
            "address": "${SERVER_ADDR}",
            "port": ${PORT},
            "users": [
              {
                "id": "${UUID}",
                "email": "t@t.tt",
                "security": "auto",
                "encryption": "none"
              }
            ]
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      },
      "mux": {
        "enabled": false,
        "concurrency": -1
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    },
    {
      "tag": "block",
      "protocol": "blackhole"
    }
  ],
  "routing": {
    "domainStrategy": "AsIs",
    "rules": [
      {
        "type": "field",
        "inboundTag": [
          "api"
        ],
        "outboundTag": "api"
      },
      {
        "type": "field",
        "port": "443",
        "network": "udp",
        "outboundTag": "block"
      },
      {
        "type": "field",
        "outboundTag": "proxy",
        "domain": [
          "geosite:google"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "ip": [
          "geoip:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "domain": [
          "geosite:private"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "ip": [
          "223.5.5.5",
          "223.6.6.6",
          "2400:3200::1",
          "2400:3200:baba::1",
          "119.29.29.29",
          "1.12.12.12",
          "120.53.53.53",
          "2402:4e00::",
          "2402:4e00:1::",
          "180.76.76.76",
          "2400:da00::6666",
          "114.114.114.114",
          "114.114.115.115",
          "114.114.114.119",
          "114.114.115.119",
          "114.114.114.110",
          "114.114.115.110",
          "180.184.1.1",
          "180.184.2.2",
          "101.226.4.6",
          "218.30.118.6",
          "123.125.81.6",
          "140.207.198.6",
          "1.2.4.8",
          "210.2.4.8",
          "52.80.66.66",
          "117.50.22.22",
          "2400:7fc0:849e:200::4",
          "2404:c2c0:85d8:901::4",
          "117.50.10.10",
          "52.80.52.52",
          "2400:7fc0:849e:200::8",
          "2404:c2c0:85d8:901::8",
          "117.50.60.30",
          "52.80.60.30"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "domain": [
          "domain:alidns.com",
          "domain:doh.pub",
          "domain:dot.pub",
          "domain:360.cn",
          "domain:onedns.net"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "ip": [
          "geoip:cn"
        ]
      },
      {
        "type": "field",
        "outboundTag": "direct",
        "domain": [
          "geosite:cn"
        ]
      }
    ]
  }
}
EOF

  cat > "$INFO_FILE" <<EOF
Tag: $TAG
Port: $PORT
Address: $SERVER_ADDR
UUID: $UUID
ClientConfigFile: $CLIENT_JSON_FILE
VLESS Link: $LINK
EOF

  echo ""
  echo "VLESS LINK:"
  echo "$LINK"
  echo ""
  qrencode -t ansiutf8 "$LINK"
  echo ""
  echo "Saved info to: $INFO_FILE"
  echo "Saved client JSON to: $CLIENT_JSON_FILE"
  read -rp "Press Enter to return..." _
}

main_menu() {
  while true; do
    clear
    echo "Loopa Xray Wizard (v5.0)"
    echo "========================"
    echo "1) Create new Reality inbound"
    echo "2) Create new VLESS TCP inbound (no TLS)"
    echo "3) Show existing configs (list + QR)"
    echo "4) Delete existing configs"
    echo "5) Firewall (ufw)"
    echo "6) Stats API (CPU/RAM/Load)"
    echo "7) Exit"
    read -rp "Select an option [1-7]: " CHOICE

    case $CHOICE in
      1) create_reality_inbound ;;
      2) create_vless_tcp_inbound ;;
      3) show_existing_configs ;;
      4) delete_existing_config ;;
      5) firewall_menu ;;
      6) stats_api_menu ;;
      7) echo "Bye!"; exit 0 ;;
      *)
        echo "Invalid option."
        sleep 1
        ;;
    esac
  done
}

require_root
main_menu
