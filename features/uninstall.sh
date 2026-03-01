collect_loopa_artifact_files() {
  local files=()
  local home_dir
  shopt -s nullglob

  files+=(
    "$DATA_DIR"/loopa-reality-*.txt
    "$DATA_DIR"/loopa-vless-*.txt
    "$DATA_DIR"/loopa-vless-client-*.json
    /root/loopa-reality-*.txt
    /root/loopa-vless-*.txt
    /root/loopa-vless-client-*.json
  )

  for home_dir in /home/*; do
    [ -d "$home_dir" ] || continue
    files+=(
      "$home_dir"/loopa-reality-*.txt
      "$home_dir"/loopa-vless-*.txt
      "$home_dir"/loopa-vless-client-*.json
    )
  done

  shopt -u nullglob
  if [ ${#files[@]} -eq 0 ]; then
    return 0
  fi
  printf '%s\n' "${files[@]}" | awk 'NF' | sort -u
}

collect_loopa_inbound_ports() {
  local files=()
  mapfile -t files < <(collect_loopa_artifact_files | grep -E 'loopa-(reality|vless)-[0-9]+\.txt$' || true)
  if [ ${#files[@]} -eq 0 ]; then
    return 0
  fi
  awk -F': ' '/^Port:[[:space:]]*[0-9]+/ {print $2}' "${files[@]}" | tr -d '\r' | awk '/^[0-9]+$/' | sort -n -u
}

collect_stats_port() {
  if [ -f "$STATS_SERVICE" ]; then
    awk -F= '/^Environment=LOOPA_STATS_PORT=/ {print $3; exit}' "$STATS_SERVICE"
  fi
}

collect_xray_config_ports() {
  if ! has jq; then
    return 0
  fi
  if [ ! -f "$CONFIG" ]; then
    return 0
  fi
  jq -r '.inbounds[]?.port // empty' "$CONFIG" 2>/dev/null | awk '/^[0-9]+$/' | sort -n -u
}

stop_loopa_services() {
  systemctl disable --now "$STATS_SERVICE_NAME" >/dev/null 2>&1 || true
  systemctl stop xray >/dev/null 2>&1 || true
  systemctl disable xray >/dev/null 2>&1 || true
  pkill -9 xray 2>/dev/null || true
  pkill -f "$STATS_SCRIPT" 2>/dev/null || true
}

remove_ufw_rules_for_port() {
  local port="$1"
  local RULES=()
  local rule_no

  while true; do
    mapfile -t RULES < <(ufw status numbered 2>/dev/null | awk -v p="${port}/tcp" '
      index($0, p) {
        if (match($0, /\[[[:space:]]*([0-9]+)\]/, m)) {
          print m[1]
        }
      }
    ' | sort -nr)

    if [ ${#RULES[@]} -eq 0 ]; then
      break
    fi

    for rule_no in "${RULES[@]}"; do
      echo y | ufw delete "$rule_no" >/dev/null 2>&1 || true
    done
  done
}

cleanup_loopa_ufw_rules() {
  local ports=()
  local XRAY_PORTS=()
  local stats_port
  local port

  if ! has ufw; then
    return 0
  fi
  if ! ufw status 2>/dev/null | head -n1 | grep -q "active"; then
    return 0
  fi

  mapfile -t ports < <(collect_loopa_inbound_ports)
  mapfile -t XRAY_PORTS < <(collect_xray_config_ports)
  if [ ${#XRAY_PORTS[@]} -gt 0 ]; then
    ports+=("${XRAY_PORTS[@]}")
  fi
  stats_port=$(collect_stats_port || true)
  if [[ "${stats_port:-}" =~ ^[0-9]+$ ]]; then
    ports+=("$stats_port")
  fi

  if [ ${#ports[@]} -eq 0 ]; then
    return 0
  fi

  mapfile -t ports < <(printf '%s\n' "${ports[@]}" | awk '/^[0-9]+$/' | sort -n -u)
  for port in "${ports[@]}"; do
    remove_ufw_rules_for_port "$port"
  done
}

remove_loopa_system_paths() {
  local to_remove=(
    "/usr/local/etc/xray"
    "/etc/xray"
    "/var/log/xray"
    "/usr/local/share/xray"
    "/usr/share/xray"
    "/usr/local/bin/xray"
    "/usr/bin/xray"
    "/etc/systemd/system/xray.service"
    "/lib/systemd/system/xray.service"
    "/etc/systemd/system/xray.service.d"
    "/etc/systemd/system/xray@.service"
    "/etc/systemd/system/multi-user.target.wants/xray.service"
    "$STATS_SERVICE"
    "$STATS_SCRIPT"
    "/etc/systemd/system/multi-user.target.wants/${STATS_SERVICE_NAME}.service"
  )
  local path

  for path in "${to_remove[@]}"; do
    if [ -e "$path" ]; then
      rm -rf "$path" || true
    fi
  done
}

remove_loopa_local_artifacts() {
  local files=()
  local f

  mapfile -t files < <(collect_loopa_artifact_files)
  for f in "${files[@]}"; do
    rm -f "$f" || true
  done

  rm -f /tmp/loopa* /tmp/xray* 2>/dev/null || true
}

remove_optional_packages() {
  local packages=(jq qrencode curl openssl ufw python3)
  apt remove -y "${packages[@]}" >/dev/null 2>&1 || true
  apt autoremove -y >/dev/null 2>&1 || true
}

uninstall_loopa_xray() {
  clear
  echo "=== Loopa / Xray Full Uninstall ==="
  echo "This will remove:"
  echo " - Xray service and files"
  echo " - Loopa-generated config files and client JSON files"
  echo " - Loopa Stats API service/script"
  echo " - Matching UFW rules for Loopa/Xray ports"
  echo
  read -rp "Type UNINSTALL to continue: " CONFIRM
  if [ "$CONFIRM" != "UNINSTALL" ]; then
    echo "Canceled."
    sleep 1
    return
  fi

  echo "Stopping services..."
  stop_loopa_services

  echo "Removing matching UFW rules..."
  cleanup_loopa_ufw_rules

  echo "Removing system files..."
  remove_loopa_system_paths

  echo "Removing local artifacts..."
  remove_loopa_local_artifacts

  systemctl daemon-reload || true
  systemctl reset-failed || true

  echo
  read -rp "Also remove helper packages (jq qrencode curl openssl ufw python3)? [y/N]: " RM_PKG
  if [[ "$RM_PKG" =~ ^[Yy]$ ]]; then
    echo "Removing optional packages..."
    remove_optional_packages
  fi

  echo
  echo "Uninstall completed."
  echo "Recommended: reboot the server once."
  read -rp "Press Enter to return..." _
}
