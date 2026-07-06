connection_stats_support_status() {
  local missing=()

  if ! has jq || ! has python3 || ! has logrotate; then
    missing+=("packages")
  fi
  [ -f "$CONN_STATS_SCRIPT" ] || missing+=("script")
  [ -f "$CONN_STATS_LOGROTATE" ] || missing+=("logrotate")
  [ -f "$CONN_STATS_ROTATE_SERVICE" ] || missing+=("rotate-service")
  [ -f "$CONN_STATS_ROTATE_TIMER" ] || missing+=("rotate-timer")
  [ -f "$XRAY_ACCESS_LOG" ] || missing+=("access-log")

  if ! has jq || [ ! -f "$CONFIG" ]; then
    missing+=("xray-log-config")
  elif ! jq -e --arg access "$XRAY_ACCESS_LOG" --arg error "$XRAY_ERROR_LOG" '
    (.log.access // "") == $access and (.log.error // "") == $error
  ' "$CONFIG" >/dev/null 2>&1; then
    missing+=("xray-log-config")
  fi

  if ! systemctl is-enabled --quiet "$CONN_STATS_ROTATE_TIMER_NAME" >/dev/null 2>&1; then
    missing+=("timer-disabled")
  fi

  if [ ${#missing[@]} -eq 0 ]; then
    echo "ready"
    return 0
  fi

  printf 'needs setup (%s)\n' "$(IFS=', '; echo "${missing[*]}")"
}

detect_xray_runtime_user() {
  local xray_user=""
  xray_user=$(ps -o user= -p "$(pgrep -x xray | head -n1)" 2>/dev/null | awk 'NR==1 {print $1}' || true)
  if [ -z "$xray_user" ]; then
    xray_user=$(systemctl show -p User --value xray 2>/dev/null | tr -d '\r\n' || true)
  fi
  printf '%s\n' "${xray_user:-nobody}"
}

ensure_connection_log_files() {
  local xray_user xray_group
  xray_user=$(detect_xray_runtime_user)
  xray_group=$(id -gn "$xray_user" 2>/dev/null || printf 'nogroup')

  install -d -m 750 -o root -g "$xray_group" "$XRAY_LOG_DIR"
  touch "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
  chown "$xray_user:$xray_group" "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
  chmod 640 "$XRAY_ACCESS_LOG" "$XRAY_ERROR_LOG"
}

ensure_xray_access_logging() {
  local tmp
  ensure_connection_log_files

  tmp=$(mktemp)
  jq --arg access "$XRAY_ACCESS_LOG" --arg error "$XRAY_ERROR_LOG" '
    .log = ((.log // {}) + {access: $access, error: $error})
    | .log.loglevel = (.log.loglevel // "warning")
  ' "$CONFIG" > "$tmp" && mv "$tmp" "$CONFIG"
  chmod 644 "$CONFIG"
}

install_connection_stats_script() {
  cat > "$CONN_STATS_SCRIPT" <<'PY'
#!/usr/bin/env python3
import json
import re
import subprocess
import sys
from datetime import datetime, timedelta
from ipaddress import ip_address
from pathlib import Path

CONFIG_PATH = Path("/usr/local/etc/xray/config.json")
ACCESS_LOG_PATH = Path("/var/log/xray/access.log")
TIME_FORMAT = "%Y/%m/%d %H:%M:%S"
TIMESTAMP_RE = re.compile(r"^(\d{4}/\d{2}/\d{2} \d{2}:\d{2}:\d{2})")
SOURCE_RE = re.compile(r"(?:tcp:|udp:)?((?:\d{1,3}\.){3}\d{1,3}):\d+")


def load_inbounds():
    if not CONFIG_PATH.exists():
        return set()
    try:
        payload = json.loads(CONFIG_PATH.read_text(encoding="utf-8"))
    except Exception:
        return set()

    ports = set()
    for inbound in payload.get("inbounds", []):
        port = inbound.get("port")
        if isinstance(port, int):
            ports.add(port)
    return ports


def normalize_endpoint(endpoint):
    endpoint = endpoint.strip()
    if endpoint.startswith("["):
        if "]:" not in endpoint:
            return endpoint.strip("[]"), None
        host, port = endpoint[1:].split("]:", 1)
    else:
        if endpoint.count(":") == 1:
            host, port = endpoint.rsplit(":", 1)
        else:
            return endpoint, None

    if host.startswith("::ffff:"):
        host = host[7:]

    try:
        return host, int(port)
    except ValueError:
        return host, None


def safe_ip_sort(value):
    try:
        return (0, ip_address(value))
    except ValueError:
        return (1, value)


def current_connected_ips(ports):
    if not ports:
        return []

    try:
        output = subprocess.check_output(
            ["ss", "-Htn", "state", "established"],
            text=True,
            errors="ignore",
        )
    except Exception:
        return []

    ips = set()
    for line in output.splitlines():
        parts = line.split()
        if len(parts) < 4:
            continue
        local_host, local_port = normalize_endpoint(parts[2])
        peer_host, _ = normalize_endpoint(parts[3])
        if local_port not in ports or not peer_host:
            continue
        try:
            ip_address(peer_host)
        except ValueError:
            continue
        ips.add(peer_host)
    return sorted(ips, key=safe_ip_sort)


def read_access_events():
    if not ACCESS_LOG_PATH.exists():
        return []
    events = []

    with ACCESS_LOG_PATH.open("r", encoding="utf-8", errors="ignore") as handle:
        for line in handle:
            if "accepted" not in line:
                continue

            ts_match = TIMESTAMP_RE.match(line)
            if not ts_match:
                continue

            try:
                timestamp = datetime.strptime(ts_match.group(1), TIME_FORMAT)
            except ValueError:
                continue

            tail = line[ts_match.end():]
            source_match = SOURCE_RE.search(tail)
            if not source_match:
                continue

            source_ip = source_match.group(1)
            events.append((timestamp, source_ip))

    return events


def unique_ips_since(events, delta):
    cutoff = datetime.now() - delta
    ips = {ip for seen_at, ip in events if seen_at >= cutoff}
    return sorted(ips, key=safe_ip_sort)


def print_section(title, ips):
    print(title)
    if ips:
        for ip in ips:
            print(f"- {ip}")
    else:
        print("- none")
    print(f"Total unique IPs: {len(ips)}")
    print("")


def main():
    ports = load_inbounds()
    active_ips = current_connected_ips(ports)
    access_events = read_access_events()

    print_section("Active Now", active_ips)
    print_section("Last 10 Minutes", unique_ips_since(access_events, timedelta(minutes=10)))
    print_section("Last 1 Hour", unique_ips_since(access_events, timedelta(hours=1)))
    print_section("Last 24 Hours", unique_ips_since(access_events, timedelta(hours=24)))


if __name__ == "__main__":
    sys.exit(main())
PY

  chmod +x "$CONN_STATS_SCRIPT"
}

install_connection_stats_rotation() {
  cat > "$CONN_STATS_LOGROTATE" <<EOF
$XRAY_ACCESS_LOG $XRAY_ERROR_LOG {
    hourly
    rotate 24
    missingok
    notifempty
    compress
    delaycompress
    copytruncate
    create 0640 $(detect_xray_runtime_user) $(id -gn "$(detect_xray_runtime_user)" 2>/dev/null || printf 'nogroup')
}
EOF

  cat > "$CONN_STATS_ROTATE_SERVICE" <<EOF
[Unit]
Description=Hourly logrotate for Loopa Xray access logs

[Service]
Type=oneshot
ExecStart=/usr/sbin/logrotate -s $CONN_STATS_LOGROTATE_STATE $CONN_STATS_LOGROTATE
EOF

  cat > "$CONN_STATS_ROTATE_TIMER" <<EOF
[Unit]
Description=Run Loopa Xray log rotation hourly

[Timer]
OnCalendar=hourly
Persistent=true
Unit=$CONN_STATS_ROTATE_SERVICE_NAME

[Install]
WantedBy=timers.target
EOF

  systemctl daemon-reload
  systemctl enable --now "$CONN_STATS_ROTATE_TIMER_NAME"
}

install_connection_stats_support() {
  ensure_packages
  ensure_xray
  ensure_config

  if ! has python3; then
    apt update -y && apt install -y python3
  fi
  if ! has logrotate; then
    apt update -y && apt install -y logrotate
  fi

  ensure_xray_access_logging
  install_connection_stats_script
  install_connection_stats_rotation
  restart_xray || err "xray service failed to start after enabling access logs."

  echo "Connection stats support is ready."
  echo "Access log: $XRAY_ACCESS_LOG"
  echo "Retention: hourly rotation, last 24 hours"
  read -rp "Press Enter to return..." _
}

show_connection_stats_settings() {
  echo "Connection stats status: $(connection_stats_support_status)"
  echo "Access log path: $XRAY_ACCESS_LOG"
  echo "Error log path: $XRAY_ERROR_LOG"
  echo "Helper script: $CONN_STATS_SCRIPT"
  echo "Hourly rotation config: $CONN_STATS_LOGROTATE"
  echo "Rotation state file: $CONN_STATS_LOGROTATE_STATE"
  echo "Rotation timer:"
  systemctl status "$CONN_STATS_ROTATE_TIMER_NAME" --no-pager 2>/dev/null | sed -n '1,8p' || true
  read -rp "Press Enter to return..." _
}

show_connection_stats_report() {
  if [ "$(connection_stats_support_status)" != "ready" ]; then
    echo "Connection stats support is not ready yet. Running install/repair first..."
    sleep 1
    ensure_packages
    ensure_xray
    ensure_config
    if ! has python3; then
      apt update -y && apt install -y python3
    fi
    if ! has logrotate; then
      apt update -y && apt install -y logrotate
    fi
    ensure_xray_access_logging
    install_connection_stats_script
    install_connection_stats_rotation
    restart_xray || err "xray service failed to start after enabling access logs."
  fi

  clear
  echo "Unique client IPs"
  echo "================="
  python3 "$CONN_STATS_SCRIPT"
  read -rp "Press Enter to return..." _
}

connection_stats_menu() {
  while true; do
    clear
    echo "Loopa Connection Stats"
    echo "======================"
    echo "Status: $(connection_stats_support_status)"
    echo "1) Install/Repair and enable access logs"
    echo "2) Show unique IPs (now / 10m / 1h / 24h)"
    echo "3) Show settings"
    echo "4) Back to main menu"
    read -rp "Choose [1-4]: " CONNCHOICE

    case $CONNCHOICE in
      1) install_connection_stats_support ;;
      2) show_connection_stats_report ;;
      3) show_connection_stats_settings ;;
      4) break ;;
      *)
        echo "Invalid choice."
        sleep 1
        ;;
    esac
  done
}
