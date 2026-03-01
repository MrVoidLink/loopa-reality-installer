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
