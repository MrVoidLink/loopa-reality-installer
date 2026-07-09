mtproxy_is_installed() {
  [ -x "$MTPROXY_BIN" ] && [ -f "$MTPROXY_SERVICE" ] && [ -f "$MTPROXY_ENV_FILE" ]
}

mtproxy_load_env() {
  if [ ! -f "$MTPROXY_ENV_FILE" ]; then
    return 1
  fi
  # shellcheck disable=SC1090
  source "$MTPROXY_ENV_FILE"
  if [[ "${MTPROXY_SECRET:-}" == dd* ]] && [ ${#MTPROXY_SECRET} -eq 34 ]; then
    MTPROXY_PADDING_MODE="${MTPROXY_PADDING_MODE:-Y}"
    MTPROXY_SECRET="${MTPROXY_SECRET:2}"
  fi
  MTPROXY_PADDING_MODE=${MTPROXY_PADDING_MODE:-Y}
}

mtproxy_client_secret() {
  mtproxy_load_env || return 1
  if [[ "${MTPROXY_PADDING_MODE:-Y}" =~ ^[Nn]$ ]]; then
    printf '%s\n' "$MTPROXY_SECRET"
    return 0
  fi
  printf 'dd%s\n' "$MTPROXY_SECRET"
}

mtproxy_status() {
  if ! mtproxy_is_installed; then
    echo "not installed"
    return 0
  fi
  if systemctl is-active --quiet "$MTPROXY_SERVICE_NAME"; then
    echo "running"
    return 0
  fi
  echo "stopped"
}

mtproxy_write_env() {
  local public_host="$1"
  local public_port="$2"
  local local_port="$3"
  local workers="$4"
  local secret="$5"
  local tag="$6"
  local padding_mode="$7"

  cat > "$MTPROXY_ENV_FILE" <<EOF
MTPROXY_PUBLIC_HOST='$public_host'
MTPROXY_PORT='$public_port'
MTPROXY_LOCAL_PORT='$local_port'
MTPROXY_WORKERS='$workers'
MTPROXY_SECRET='$secret'
MTPROXY_TAG='$tag'
MTPROXY_PADDING_MODE='$padding_mode'
EOF
}

mtproxy_patch_makefile() {
  local makefile="$MTPROXY_SRC_DIR/Makefile"
  [ -f "$makefile" ] || err "MTProxy Makefile not found."

  if ! grep -q -- "-fcommon" "$makefile"; then
    sed -i '/^CFLAGS = /{/ -fcommon/! s/^CFLAGS = /CFLAGS = -fcommon /;}' "$makefile"
    sed -i '/^LDFLAGS = /{/ -fcommon/! s/^LDFLAGS = /LDFLAGS = -fcommon /;}' "$makefile"
  fi
}

mtproxy_ensure_build_deps() {
  local required=(git curl build-essential libssl-dev zlib1g-dev openssl qrencode)
  local pkg

  for pkg in "${required[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      apt update -y
      apt install -y "$pkg"
    fi
  done
}

mtproxy_refresh_upstream_files() {
  install -d -m 755 "$MTPROXY_WORK_DIR"
  curl -fsSL https://core.telegram.org/getProxySecret -o "$MTPROXY_SECRET_FILE"
  curl -fsSL https://core.telegram.org/getProxyConfig -o "$MTPROXY_CONFIG_FILE"
}

mtproxy_build_binary() {
  if [ -d "$MTPROXY_SRC_DIR/.git" ]; then
    git -C "$MTPROXY_SRC_DIR" fetch --depth 1 origin master
    git -C "$MTPROXY_SRC_DIR" reset --hard FETCH_HEAD
  else
    rm -rf "$MTPROXY_SRC_DIR"
    git clone --depth 1 "$MTPROXY_REPO_URL" "$MTPROXY_SRC_DIR"
  fi

  mtproxy_patch_makefile
  make -C "$MTPROXY_SRC_DIR" clean >/dev/null 2>&1 || true
  make -C "$MTPROXY_SRC_DIR"

  install -d -m 755 "$MTPROXY_WORK_DIR"
  install -m 755 "$MTPROXY_SRC_DIR/objs/bin/mtproto-proxy" "$MTPROXY_BIN"
}

mtproxy_generate_secret() {
  openssl rand -hex 16
}

mtproxy_write_service() {
  mtproxy_load_env || err "MTProxy config not found."

  local exec_cmd
  exec_cmd="$MTPROXY_BIN -u nobody -p $MTPROXY_LOCAL_PORT -H $MTPROXY_PORT -S $MTPROXY_SECRET --aes-pwd $MTPROXY_SECRET_FILE $MTPROXY_CONFIG_FILE -M $MTPROXY_WORKERS"
  if [ -n "${MTPROXY_TAG:-}" ]; then
    exec_cmd="$exec_cmd -P $MTPROXY_TAG"
  fi

  cat > "$MTPROXY_SERVICE" <<EOF
[Unit]
Description=Loopa Telegram MTProto Proxy
After=network.target

[Service]
Type=simple
WorkingDirectory=$MTPROXY_WORK_DIR
ExecStart=$exec_cmd
Restart=on-failure
RestartSec=2

[Install]
WantedBy=multi-user.target
EOF
}

mtproxy_write_summary() {
  mtproxy_load_env || err "MTProxy config not found."
  local client_secret
  client_secret=$(mtproxy_client_secret)

  cat > "$MTPROXY_INFO_FILE" <<EOF
Loopa Telegram Proxy
====================
Public Host: $MTPROXY_PUBLIC_HOST
Public Port: $MTPROXY_PORT
Local Stats Port: $MTPROXY_LOCAL_PORT
Workers: $MTPROXY_WORKERS
Secret: $MTPROXY_SECRET
Client Secret: $client_secret
Tag: ${MTPROXY_TAG:-none}
Status: $(mtproxy_status)

tg://proxy?server=$MTPROXY_PUBLIC_HOST&port=$MTPROXY_PORT&secret=$client_secret
https://t.me/proxy?server=$MTPROXY_PUBLIC_HOST&port=$MTPROXY_PORT&secret=$client_secret
EOF
}

mtproxy_allow_port_if_needed() {
  local port="$1"
  if has ufw && ufw status 2>/dev/null | head -n1 | grep -q "active"; then
    ufw allow "${port}/tcp" >/dev/null 2>&1 || true
  fi
}

mtproxy_remove_ufw_port_if_needed() {
  local port="$1"
  if has ufw && ufw status 2>/dev/null | head -n1 | grep -q "active"; then
    remove_ufw_rules_for_port "$port"
  fi
}

mtproxy_install_or_update() {
  local current_port=""
  local current_local_port=""
  local current_host=""
  local current_workers=""
  local current_tag=""
  local current_secret=""
  local public_host
  local public_port
  local local_port
  local workers
  local host_prompt
  local padding_mode
  local current_padding_mode=""
  local secret_action
  local tag
  local secret
  local detected_host

  if mtproxy_load_env; then
    current_port="${MTPROXY_PORT:-}"
    current_local_port="${MTPROXY_LOCAL_PORT:-}"
    current_host="${MTPROXY_PUBLIC_HOST:-}"
    current_workers="${MTPROXY_WORKERS:-}"
    current_tag="${MTPROXY_TAG:-}"
    current_secret="${MTPROXY_SECRET:-}"
    current_padding_mode="${MTPROXY_PADDING_MODE:-Y}"
  fi

  detected_host=$(detect_public_ip || true)
  host_prompt=${current_host:-$detected_host}

  clear
  echo "Install / Update Telegram MTProto Proxy"
  echo "======================================="
  echo "If you want channel promotion inside Telegram clients,"
  echo "register the proxy in @MTProxybot and set the tag here."
  echo
  if [ -n "$host_prompt" ]; then
    read -rp "Public host/IP [$host_prompt]: " public_host
    public_host=${public_host:-$host_prompt}
  else
    read -rp "Public host/IP: " public_host
  fi
  [ -n "$public_host" ] || err "Public host/IP is required."
  validate_host_or_ip "$public_host"

  read -rp "Public port [${current_port:-3443}]: " public_port
  public_port=${public_port:-${current_port:-3443}}
  validate_port "$public_port"

  read -rp "Local stats port [${current_local_port:-3256}]: " local_port
  local_port=${local_port:-${current_local_port:-3256}}
  validate_port "$local_port"

  [ "$public_port" != "$local_port" ] || err "Public port and local stats port must be different."

  if port_listening "$public_port" && [ "${current_port:-}" != "$public_port" ]; then
    err "Port $public_port is already in use."
  fi
  if port_listening "$local_port" && [ "${current_local_port:-}" != "$local_port" ]; then
    err "Local port $local_port is already in use."
  fi

  read -rp "Worker count [${current_workers:-1}]: " workers
  workers=${workers:-${current_workers:-1}}
  [[ "$workers" =~ ^[0-9]+$ ]] || err "Worker count must be numeric."
  (( workers >= 1 )) || err "Worker count must be at least 1."

  read -rp "Enable random padding? [${current_padding_mode:-Y}/n]: " padding_mode
  padding_mode=${padding_mode:-${current_padding_mode:-Y}}
  read -rp "Proxy tag from @MTProxybot (optional) [${current_tag:-none}]: " tag
  if [ -z "$tag" ]; then
    tag="$current_tag"
  fi

  if [ -n "$current_secret" ]; then
    read -rp "Generate a new client secret now? [y/N]: " secret_action
    if [[ "$secret_action" =~ ^[Yy]$ ]]; then
      secret=$(mtproxy_generate_secret)
    else
      secret="$current_secret"
    fi
  else
    secret=$(mtproxy_generate_secret)
  fi

  echo
  echo "Building MTProxy and downloading Telegram upstream files..."
  mtproxy_ensure_build_deps
  mtproxy_build_binary
  mtproxy_refresh_upstream_files
  mtproxy_write_env "$public_host" "$public_port" "$local_port" "$workers" "$secret" "$tag" "$padding_mode"
  mtproxy_write_service
  systemctl daemon-reload
  systemctl enable "$MTPROXY_SERVICE_NAME"
  systemctl restart "$MTPROXY_SERVICE_NAME"
  mtproxy_allow_port_if_needed "$public_port"
  mtproxy_write_summary

  echo
  echo "MTProto proxy is ready."
  echo "Summary file: $MTPROXY_INFO_FILE"
  mtproxy_show_links
}

mtproxy_show_links() {
  if ! mtproxy_load_env; then
    echo "MTProto proxy is not installed."
    read -rp "Press Enter to return..." _
    return
  fi

  local tg_link
  local https_link
  local client_secret
  client_secret=$(mtproxy_client_secret)
  tg_link="tg://proxy?server=$MTPROXY_PUBLIC_HOST&port=$MTPROXY_PORT&secret=$client_secret"
  https_link="https://t.me/proxy?server=$MTPROXY_PUBLIC_HOST&port=$MTPROXY_PORT&secret=$client_secret"

  clear
  echo "Telegram Proxy Links"
  echo "===================="
  echo "Status: $(mtproxy_status)"
  echo "Host: $MTPROXY_PUBLIC_HOST"
  echo "Port: $MTPROXY_PORT"
  echo "Secret: $MTPROXY_SECRET"
  echo "Client Secret: $client_secret"
  echo "Tag: ${MTPROXY_TAG:-none}"
  echo
  echo "$tg_link"
  echo "$https_link"
  echo
  if has qrencode; then
    qrencode -t ANSIUTF8 "$https_link" || true
    echo
  fi
  read -rp "Press Enter to return..." _
}

mtproxy_show_status() {
  clear
  echo "Telegram MTProto Proxy"
  echo "======================"
  echo "Status: $(mtproxy_status)"
  if mtproxy_load_env; then
    echo "Host: $MTPROXY_PUBLIC_HOST"
    echo "Public Port: $MTPROXY_PORT"
    echo "Local Stats Port: $MTPROXY_LOCAL_PORT"
    echo "Workers: $MTPROXY_WORKERS"
    echo "Tag: ${MTPROXY_TAG:-none}"
    echo "Summary file: $MTPROXY_INFO_FILE"
    echo
    systemctl status "$MTPROXY_SERVICE_NAME" --no-pager 2>/dev/null | sed -n '1,8p' || true
  else
    echo "No saved MTProxy config."
  fi
  read -rp "Press Enter to return..." _
}

mtproxy_rotate_secret() {
  local padding_mode
  local new_secret

  mtproxy_load_env || err "MTProto proxy is not installed."

  clear
  echo "Rotate MTProto Secret"
  echo "====================="
  echo "Old links will stop working after restart."
  read -rp "Enable random padding for the new secret? [Y/n]: " padding_mode
  new_secret=$(mtproxy_generate_secret)

  mtproxy_write_env "$MTPROXY_PUBLIC_HOST" "$MTPROXY_PORT" "$MTPROXY_LOCAL_PORT" "$MTPROXY_WORKERS" "$new_secret" "${MTPROXY_TAG:-}" "$padding_mode"
  mtproxy_write_service
  systemctl daemon-reload
  mtproxy_refresh_upstream_files
  systemctl restart "$MTPROXY_SERVICE_NAME"
  mtproxy_write_summary

  echo "Secret rotated."
  mtproxy_show_links
}

mtproxy_set_tag() {
  local new_tag

  mtproxy_load_env || err "MTProto proxy is not installed."

  clear
  echo "Set / Clear Proxy Tag"
  echo "====================="
  echo "Get the tag from @MTProxybot if you want Telegram-side promotion."
  read -rp "Proxy tag (leave empty to clear) [${MTPROXY_TAG:-none}]: " new_tag

  mtproxy_write_env "$MTPROXY_PUBLIC_HOST" "$MTPROXY_PORT" "$MTPROXY_LOCAL_PORT" "$MTPROXY_WORKERS" "$MTPROXY_SECRET" "$new_tag" "${MTPROXY_PADDING_MODE:-Y}"
  mtproxy_write_service
  systemctl daemon-reload
  systemctl restart "$MTPROXY_SERVICE_NAME"
  mtproxy_write_summary

  echo "Proxy tag updated."
  read -rp "Press Enter to return..." _
}

mtproxy_refresh_config() {
  mtproxy_load_env || err "MTProto proxy is not installed."

  mtproxy_refresh_upstream_files
  systemctl restart "$MTPROXY_SERVICE_NAME"
  mtproxy_write_summary

  echo "Telegram upstream files refreshed and service restarted."
  read -rp "Press Enter to return..." _
}

mtproxy_restart() {
  mtproxy_load_env || err "MTProto proxy is not installed."

  mtproxy_refresh_upstream_files
  systemctl restart "$MTPROXY_SERVICE_NAME"
  mtproxy_write_summary

  echo "MTProto proxy restarted."
  read -rp "Press Enter to return..." _
}

mtproxy_remove() {
  local port=""
  local confirm=""

  clear
  echo "Remove Telegram MTProto Proxy"
  echo "============================="
  read -rp "Type REMOVE to continue: " confirm
  if [ "$confirm" != "REMOVE" ]; then
    echo "Canceled."
    sleep 1
    return
  fi

  if mtproxy_load_env; then
    port="${MTPROXY_PORT:-}"
  fi

  systemctl disable --now "$MTPROXY_SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$MTPROXY_SERVICE" "$MTPROXY_ENV_FILE" "$MTPROXY_INFO_FILE"
  rm -rf "$MTPROXY_WORK_DIR" "$MTPROXY_SRC_DIR"
  systemctl daemon-reload
  systemctl reset-failed >/dev/null 2>&1 || true

  if [[ "$port" =~ ^[0-9]+$ ]]; then
    mtproxy_remove_ufw_port_if_needed "$port"
  fi

  echo "MTProto proxy removed."
  read -rp "Press Enter to return..." _
}

telegram_proxy_menu() {
  while true; do
    clear
    echo "Telegram Proxy"
    echo "=============="
    echo "Status: $(mtproxy_status)"
    echo "1) Install/Update MTProto proxy"
    echo "2) Show proxy link"
    echo "3) Rotate secret"
    echo "4) Set/Clear MTProxy tag"
    echo "5) Refresh Telegram upstream config"
    echo "6) Restart proxy"
    echo "7) Show status"
    echo "8) Remove proxy"
    echo "9) Back"
    read -rp "Choose [1-9]: " TGCHOICE

    case $TGCHOICE in
      1) mtproxy_install_or_update ;;
      2) mtproxy_show_links ;;
      3) mtproxy_rotate_secret ;;
      4) mtproxy_set_tag ;;
      5) mtproxy_refresh_config ;;
      6) mtproxy_restart ;;
      7) mtproxy_show_status ;;
      8) mtproxy_remove ;;
      9) break ;;
      *)
        echo "Invalid choice."
        sleep 1
        ;;
    esac
  done
}
