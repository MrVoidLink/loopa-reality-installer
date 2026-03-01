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
