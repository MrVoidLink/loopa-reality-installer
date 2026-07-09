mtproxy_ensure_runtime_dirs() {
  install -d -m 755 "$MTPROXY_WORK_DIR" "$MTPROXY_ENV_DIR"
}

mtproxy_instance_slug_from_name() {
  local name="$1"
  local slug

  slug=$(printf '%s' "$name" \
    | tr '[:upper:]' '[:lower:]' \
    | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//; s/-{2,}/-/g')

  printf '%s\n' "${slug:-proxy}"
}

mtproxy_instance_env_file() {
  printf '%s/%s.env\n' "$MTPROXY_ENV_DIR" "$1"
}

mtproxy_instance_service_name() {
  printf '%s-%s\n' "$MTPROXY_SERVICE_PREFIX" "$1"
}

mtproxy_instance_service_file() {
  printf '/etc/systemd/system/%s.service\n' "$(mtproxy_instance_service_name "$1")"
}

mtproxy_instance_info_file() {
  printf '%s-%s.txt\n' "$MTPROXY_INFO_PREFIX" "$1"
}

mtproxy_list_instances() {
  local env_files=()
  local env_file

  mtproxy_ensure_runtime_dirs
  shopt -s nullglob
  env_files=("$MTPROXY_ENV_DIR"/*.env)
  shopt -u nullglob

  for env_file in "${env_files[@]}"; do
    basename "$env_file" .env
  done | sort
}

mtproxy_instance_count() {
  local instances=()
  mapfile -t instances < <(mtproxy_list_instances)
  printf '%s\n' "${#instances[@]}"
}

mtproxy_running_count() {
  local instances=()
  local slug
  local running=0

  mapfile -t instances < <(mtproxy_list_instances)
  for slug in "${instances[@]}"; do
    if [ "$(mtproxy_status "$slug")" = "running" ]; then
      running=$((running + 1))
    fi
  done

  printf '%s\n' "$running"
}

mtproxy_client_secret_value() {
  local secret="$1"
  local padding_mode="${2:-Y}"

  if [[ "$padding_mode" =~ ^[Nn]$ ]]; then
    printf '%s\n' "$secret"
    return 0
  fi

  printf 'dd%s\n' "$secret"
}

mtproxy_load_env() {
  local slug="$1"
  local env_file

  env_file=$(mtproxy_instance_env_file "$slug")
  [ -f "$env_file" ] || return 1

  # shellcheck disable=SC1090
  source "$env_file"

  MTPROXY_INSTANCE_SLUG="$slug"
  MTPROXY_INSTANCE_NAME=${MTPROXY_INSTANCE_NAME:-$slug}
  if [[ "${MTPROXY_SECRET:-}" == dd* ]] && [ ${#MTPROXY_SECRET} -eq 34 ]; then
    MTPROXY_PADDING_MODE="${MTPROXY_PADDING_MODE:-Y}"
    MTPROXY_SECRET="${MTPROXY_SECRET:2}"
  fi
  MTPROXY_PADDING_MODE=${MTPROXY_PADDING_MODE:-Y}
}

mtproxy_write_env() {
  local slug="$1"
  local instance_name="$2"
  local public_host="$3"
  local public_port="$4"
  local local_port="$5"
  local workers="$6"
  local secret="$7"
  local tag="$8"
  local padding_mode="$9"
  local env_file

  env_file=$(mtproxy_instance_env_file "$slug")
  cat > "$env_file" <<EOF
MTPROXY_INSTANCE_NAME='$instance_name'
MTPROXY_PUBLIC_HOST='$public_host'
MTPROXY_PORT='$public_port'
MTPROXY_LOCAL_PORT='$local_port'
MTPROXY_WORKERS='$workers'
MTPROXY_SECRET='$secret'
MTPROXY_TAG='$tag'
MTPROXY_PADDING_MODE='$padding_mode'
EOF
}

mtproxy_is_installed() {
  local slug="$1"

  [ -x "$MTPROXY_BIN" ] \
    && [ -f "$(mtproxy_instance_env_file "$slug")" ] \
    && [ -f "$(mtproxy_instance_service_file "$slug")" ]
}

mtproxy_status() {
  local slug="$1"
  local service_name

  service_name=$(mtproxy_instance_service_name "$slug")
  if ! mtproxy_is_installed "$slug"; then
    echo "not installed"
    return 0
  fi
  if systemctl is-active --quiet "$service_name"; then
    echo "running"
    return 0
  fi
  if systemctl is-failed --quiet "$service_name"; then
    echo "failed"
    return 0
  fi
  echo "stopped"
}

mtproxy_overview_status() {
  local total
  local running

  total=$(mtproxy_instance_count)
  if [ "$total" -eq 0 ]; then
    echo "no proxies"
    return 0
  fi

  running=$(mtproxy_running_count)
  echo "$total installed ($running running)"
}

mtproxy_patch_makefile() {
  local makefile="$MTPROXY_SRC_DIR/Makefile"
  [ -f "$makefile" ] || err "MTProxy Makefile not found."

  if ! grep -q -- "-fcommon" "$makefile"; then
    sed -i '/^CFLAGS = /{/ -fcommon/! s/^CFLAGS = /CFLAGS = -fcommon /;}' "$makefile"
    sed -i '/^LDFLAGS = /{/ -fcommon/! s/^LDFLAGS = /LDFLAGS = -fcommon /;}' "$makefile"
  fi
}

mtproxy_patch_source() {
  local pid_file="$MTPROXY_SRC_DIR/common/pid.c"
  [ -f "$pid_file" ] || err "MTProxy pid.c not found."

  if grep -q "assert (!(p & 0xffff0000));" "$pid_file"; then
    perl -0pi -e 's/int p = getpid \(\);\s+assert \(!\(p & 0xffff0000\)\);\s+PID\.pid = p;/int p = getpid ();\n    PID.pid = (unsigned short) p;/g' "$pid_file"
  fi
}

mtproxy_ensure_build_deps() {
  local required=(git curl build-essential libssl-dev zlib1g-dev openssl qrencode perl)
  local pkg

  for pkg in "${required[@]}"; do
    if ! dpkg -s "$pkg" >/dev/null 2>&1; then
      apt update -y
      apt install -y "$pkg"
    fi
  done
}

mtproxy_refresh_upstream_files() {
  mtproxy_ensure_runtime_dirs
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
  mtproxy_patch_source
  make -C "$MTPROXY_SRC_DIR" clean >/dev/null 2>&1 || true
  make -C "$MTPROXY_SRC_DIR"

  install -d -m 755 "$MTPROXY_WORK_DIR"
  install -m 755 "$MTPROXY_SRC_DIR/objs/bin/mtproto-proxy" "$MTPROXY_BIN"
}

mtproxy_generate_secret() {
  openssl rand -hex 16
}

mtproxy_write_service() {
  local slug="$1"
  local service_name
  local service_file
  local exec_cmd

  mtproxy_load_env "$slug" || err "MTProxy config not found."
  service_name=$(mtproxy_instance_service_name "$slug")
  service_file=$(mtproxy_instance_service_file "$slug")

  exec_cmd="$MTPROXY_BIN -u nobody -p $MTPROXY_LOCAL_PORT -H $MTPROXY_PORT -S $MTPROXY_SECRET --aes-pwd $MTPROXY_SECRET_FILE $MTPROXY_CONFIG_FILE -M $MTPROXY_WORKERS"
  if [ -n "${MTPROXY_TAG:-}" ]; then
    exec_cmd="$exec_cmd -P $MTPROXY_TAG"
  fi

  cat > "$service_file" <<EOF
[Unit]
Description=Loopa Telegram MTProto Proxy ($slug)
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
  local slug="$1"
  local info_file
  local client_secret

  mtproxy_load_env "$slug" || err "MTProxy config not found."
  info_file=$(mtproxy_instance_info_file "$slug")
  client_secret=$(mtproxy_client_secret_value "$MTPROXY_SECRET" "$MTPROXY_PADDING_MODE")

  cat > "$info_file" <<EOF
Loopa Telegram Proxy
====================
Instance: $MTPROXY_INSTANCE_NAME
Slug: $slug
Public Host: $MTPROXY_PUBLIC_HOST
Public Port: $MTPROXY_PORT
Local Stats Port: $MTPROXY_LOCAL_PORT
Workers: $MTPROXY_WORKERS
Secret: $MTPROXY_SECRET
Client Secret: $client_secret
Tag: ${MTPROXY_TAG:-none}
Status: $(mtproxy_status "$slug")

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

mtproxy_migrate_legacy_instance() {
  local instances=()
  local slug="default"
  local padding_mode="Y"
  local legacy_secret=""
  local legacy_tag=""

  [ -f "$MTPROXY_LEGACY_ENV_FILE" ] || return 0
  mapfile -t instances < <(mtproxy_list_instances)
  [ ${#instances[@]} -eq 0 ] || return 0

  # shellcheck disable=SC1090
  source "$MTPROXY_LEGACY_ENV_FILE"
  [ -n "${MTPROXY_PUBLIC_HOST:-}" ] || return 0

  legacy_secret="${MTPROXY_SECRET:-}"
  legacy_tag="${MTPROXY_TAG:-}"
  padding_mode="${MTPROXY_PADDING_MODE:-Y}"
  if [[ "$legacy_secret" == dd* ]] && [ ${#legacy_secret} -eq 34 ]; then
    legacy_secret="${legacy_secret:2}"
    padding_mode="Y"
  fi

  mtproxy_write_env \
    "$slug" \
    "default" \
    "$MTPROXY_PUBLIC_HOST" \
    "$MTPROXY_PORT" \
    "$MTPROXY_LOCAL_PORT" \
    "${MTPROXY_WORKERS:-1}" \
    "$legacy_secret" \
    "$legacy_tag" \
    "$padding_mode"
  mtproxy_write_service "$slug"

  systemctl disable --now "$MTPROXY_LEGACY_SERVICE_NAME" >/dev/null 2>&1 || true
  rm -f "$MTPROXY_LEGACY_SERVICE" "$MTPROXY_LEGACY_ENV_FILE" "$MTPROXY_LEGACY_INFO_FILE"
  systemctl daemon-reload

  if [ -x "$MTPROXY_BIN" ] && [ -f "$MTPROXY_SECRET_FILE" ] && [ -f "$MTPROXY_CONFIG_FILE" ]; then
    systemctl enable "$(mtproxy_instance_service_name "$slug")" >/dev/null 2>&1 || true
    systemctl restart "$(mtproxy_instance_service_name "$slug")" >/dev/null 2>&1 || true
  fi

  mtproxy_write_summary "$slug" >/dev/null 2>&1 || true
}

mtproxy_default_instance_name() {
  local index=1
  local candidate_slug

  while true; do
    candidate_slug=$(mtproxy_instance_slug_from_name "proxy-$index")
    if [ ! -f "$(mtproxy_instance_env_file "$candidate_slug")" ]; then
      printf 'proxy-%s\n' "$index"
      return 0
    fi
    index=$((index + 1))
  done
}

mtproxy_port_reserved() {
  local port="$1"
  local ignore_slug="${2:-}"
  local instances=()
  local slug

  if port_listening "$port"; then
    if [ -z "$ignore_slug" ]; then
      return 0
    fi
  fi

  mapfile -t instances < <(mtproxy_list_instances)
  for slug in "${instances[@]}"; do
    [ "$slug" = "$ignore_slug" ] && continue
    mtproxy_load_env "$slug" >/dev/null || continue
    if [ "${MTPROXY_PORT:-}" = "$port" ] || [ "${MTPROXY_LOCAL_PORT:-}" = "$port" ]; then
      return 0
    fi
  done

  return 1
}

mtproxy_next_free_port() {
  local port="$1"

  while [ "$port" -le 65535 ]; do
    if ! mtproxy_port_reserved "$port"; then
      printf '%s\n' "$port"
      return 0
    fi
    port=$((port + 1))
  done

  err "No free port found."
}

mtproxy_select_instance() {
  local prompt="$1"
  local instances=()
  local choice
  local index
  local slug

  mtproxy_migrate_legacy_instance
  mapfile -t instances < <(mtproxy_list_instances)
  if [ ${#instances[@]} -eq 0 ]; then
    echo "No MTProto proxies installed yet."
    read -rp "Press Enter to return..." _
    return 1
  fi

  while true; do
    clear
    echo "$prompt"
    echo "=============================="
    for index in "${!instances[@]}"; do
      slug="${instances[$index]}"
      mtproxy_load_env "$slug" >/dev/null || continue
      echo "$((index + 1))) $MTPROXY_INSTANCE_NAME [$slug] - port $MTPROXY_PORT - $(mtproxy_status "$slug")"
    done
    echo "0) Cancel"
    read -rp "Choose [0-${#instances[@]}]: " choice

    if [ "$choice" = "0" ]; then
      return 1
    fi
    if [[ "$choice" =~ ^[0-9]+$ ]] && (( choice >= 1 && choice <= ${#instances[@]} )); then
      printf '%s\n' "${instances[$((choice - 1))]}"
      return 0
    fi

    echo "Invalid choice."
    sleep 1
  done
}

mtproxy_create_instance() {
  local instance_name
  local slug
  local public_host
  local public_port
  local local_port
  local workers
  local padding_mode
  local tag
  local secret
  local detected_host
  local default_name

  mtproxy_migrate_legacy_instance
  detected_host=$(detect_public_ip || true)
  default_name=$(mtproxy_default_instance_name)

  clear
  echo "Create New Telegram MTProto Proxy"
  echo "================================="
  echo "Each proxy gets its own service, ports, secret, and summary file."
  echo
  read -rp "Instance name [$default_name]: " instance_name
  instance_name=${instance_name:-$default_name}
  slug=$(mtproxy_instance_slug_from_name "$instance_name")
  [ -f "$(mtproxy_instance_env_file "$slug")" ] && err "Instance '$slug' already exists."

  if [ -n "$detected_host" ]; then
    read -rp "Public host/IP [$detected_host]: " public_host
    public_host=${public_host:-$detected_host}
  else
    read -rp "Public host/IP: " public_host
  fi
  [ -n "$public_host" ] || err "Public host/IP is required."
  validate_host_or_ip "$public_host"

  read -rp "Public port [$(mtproxy_next_free_port 3443)]: " public_port
  public_port=${public_port:-$(mtproxy_next_free_port 3443)}
  validate_port "$public_port"
  mtproxy_port_reserved "$public_port" && err "Port $public_port is already reserved."

  read -rp "Local stats port [$(mtproxy_next_free_port 3256)]: " local_port
  local_port=${local_port:-$(mtproxy_next_free_port 3256)}
  validate_port "$local_port"
  [ "$public_port" != "$local_port" ] || err "Public port and local stats port must be different."
  mtproxy_port_reserved "$local_port" && err "Local port $local_port is already reserved."

  read -rp "Worker count [1]: " workers
  workers=${workers:-1}
  [[ "$workers" =~ ^[0-9]+$ ]] || err "Worker count must be numeric."
  (( workers >= 1 )) || err "Worker count must be at least 1."

  read -rp "Enable random padding? [Y/n]: " padding_mode
  padding_mode=${padding_mode:-Y}
  read -rp "Proxy tag from @MTProxybot (optional) [none]: " tag

  secret=$(mtproxy_generate_secret)

  echo
  echo "Building shared MTProxy binary and downloading Telegram upstream files..."
  mtproxy_ensure_build_deps
  mtproxy_build_binary
  mtproxy_refresh_upstream_files

  mtproxy_write_env "$slug" "$instance_name" "$public_host" "$public_port" "$local_port" "$workers" "$secret" "$tag" "$padding_mode"
  mtproxy_write_service "$slug"
  systemctl daemon-reload
  systemctl enable "$(mtproxy_instance_service_name "$slug")" >/dev/null 2>&1
  systemctl restart "$(mtproxy_instance_service_name "$slug")"
  mtproxy_allow_port_if_needed "$public_port"
  mtproxy_write_summary "$slug"

  echo
  echo "MTProto proxy '$instance_name' is ready."
  echo "Summary file: $(mtproxy_instance_info_file "$slug")"
  mtproxy_show_links "$slug"
}

mtproxy_show_links() {
  local slug="${1:-}"
  local client_secret
  local tg_link
  local https_link

  mtproxy_migrate_legacy_instance
  if [ -z "$slug" ]; then
    slug=$(mtproxy_select_instance "Show Proxy Link") || return
  fi
  mtproxy_load_env "$slug" || err "MTProto proxy is not installed."

  client_secret=$(mtproxy_client_secret_value "$MTPROXY_SECRET" "$MTPROXY_PADDING_MODE")
  tg_link="tg://proxy?server=$MTPROXY_PUBLIC_HOST&port=$MTPROXY_PORT&secret=$client_secret"
  https_link="https://t.me/proxy?server=$MTPROXY_PUBLIC_HOST&port=$MTPROXY_PORT&secret=$client_secret"

  clear
  echo "Telegram Proxy Links"
  echo "===================="
  echo "Instance: $MTPROXY_INSTANCE_NAME [$slug]"
  echo "Status: $(mtproxy_status "$slug")"
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
  local slug
  local service_name

  mtproxy_migrate_legacy_instance
  slug=$(mtproxy_select_instance "Show Proxy Status") || return
  mtproxy_load_env "$slug" || err "MTProto proxy is not installed."
  service_name=$(mtproxy_instance_service_name "$slug")

  clear
  echo "Telegram MTProto Proxy"
  echo "======================"
  echo "Instance: $MTPROXY_INSTANCE_NAME [$slug]"
  echo "Status: $(mtproxy_status "$slug")"
  echo "Host: $MTPROXY_PUBLIC_HOST"
  echo "Public Port: $MTPROXY_PORT"
  echo "Local Stats Port: $MTPROXY_LOCAL_PORT"
  echo "Workers: $MTPROXY_WORKERS"
  echo "Tag: ${MTPROXY_TAG:-none}"
  echo "Summary file: $(mtproxy_instance_info_file "$slug")"
  echo
  systemctl status "$service_name" --no-pager 2>/dev/null | sed -n '1,10p' || true
  read -rp "Press Enter to return..." _
}

mtproxy_list_proxy_instances() {
  local instances=()
  local slug

  mtproxy_migrate_legacy_instance
  mapfile -t instances < <(mtproxy_list_instances)

  clear
  echo "Telegram Proxy Instances"
  echo "========================"
  if [ ${#instances[@]} -eq 0 ]; then
    echo "No MTProto proxies installed yet."
  else
    for slug in "${instances[@]}"; do
      mtproxy_load_env "$slug" >/dev/null || continue
      echo "- $MTPROXY_INSTANCE_NAME [$slug] | public $MTPROXY_PORT | local $MTPROXY_LOCAL_PORT | $(mtproxy_status "$slug")"
    done
  fi
  echo
  read -rp "Press Enter to return..." _
}

mtproxy_rotate_secret() {
  local slug
  local padding_mode
  local new_secret
  local service_name

  mtproxy_migrate_legacy_instance
  slug=$(mtproxy_select_instance "Rotate Proxy Secret") || return
  mtproxy_load_env "$slug" || err "MTProto proxy is not installed."
  service_name=$(mtproxy_instance_service_name "$slug")

  clear
  echo "Rotate MTProto Secret"
  echo "====================="
  echo "Instance: $MTPROXY_INSTANCE_NAME [$slug]"
  echo "Old links will stop working after restart."
  read -rp "Enable random padding for the new secret? [Y/n]: " padding_mode
  padding_mode=${padding_mode:-Y}
  new_secret=$(mtproxy_generate_secret)

  mtproxy_write_env "$slug" "$MTPROXY_INSTANCE_NAME" "$MTPROXY_PUBLIC_HOST" "$MTPROXY_PORT" "$MTPROXY_LOCAL_PORT" "$MTPROXY_WORKERS" "$new_secret" "${MTPROXY_TAG:-}" "$padding_mode"
  mtproxy_write_service "$slug"
  systemctl daemon-reload
  mtproxy_refresh_upstream_files
  systemctl restart "$service_name"
  mtproxy_write_summary "$slug"

  echo "Secret rotated."
  mtproxy_show_links "$slug"
}

mtproxy_set_tag() {
  local slug
  local new_tag
  local service_name

  mtproxy_migrate_legacy_instance
  slug=$(mtproxy_select_instance "Set / Clear Proxy Tag") || return
  mtproxy_load_env "$slug" || err "MTProto proxy is not installed."
  service_name=$(mtproxy_instance_service_name "$slug")

  clear
  echo "Set / Clear Proxy Tag"
  echo "====================="
  echo "Instance: $MTPROXY_INSTANCE_NAME [$slug]"
  echo "Get the tag from @MTProxybot if you want Telegram-side promotion."
  read -rp "Proxy tag (leave empty to clear) [${MTPROXY_TAG:-none}]: " new_tag

  mtproxy_write_env "$slug" "$MTPROXY_INSTANCE_NAME" "$MTPROXY_PUBLIC_HOST" "$MTPROXY_PORT" "$MTPROXY_LOCAL_PORT" "$MTPROXY_WORKERS" "$MTPROXY_SECRET" "$new_tag" "$MTPROXY_PADDING_MODE"
  mtproxy_write_service "$slug"
  systemctl daemon-reload
  systemctl restart "$service_name"
  mtproxy_write_summary "$slug"

  echo "Proxy tag updated."
  read -rp "Press Enter to return..." _
}

mtproxy_refresh_config() {
  local instances=()
  local slug

  mtproxy_migrate_legacy_instance
  mapfile -t instances < <(mtproxy_list_instances)
  if [ ${#instances[@]} -eq 0 ]; then
    echo "No MTProto proxies installed yet."
    read -rp "Press Enter to return..." _
    return
  fi

  mtproxy_refresh_upstream_files
  for slug in "${instances[@]}"; do
    systemctl restart "$(mtproxy_instance_service_name "$slug")" >/dev/null 2>&1 || true
    mtproxy_write_summary "$slug" >/dev/null 2>&1 || true
  done

  echo "Telegram upstream files refreshed."
  echo "All MTProto proxies were restarted."
  read -rp "Press Enter to return..." _
}

mtproxy_restart() {
  local slug
  local service_name

  mtproxy_migrate_legacy_instance
  slug=$(mtproxy_select_instance "Restart Proxy") || return
  mtproxy_load_env "$slug" || err "MTProto proxy is not installed."
  service_name=$(mtproxy_instance_service_name "$slug")

  mtproxy_refresh_upstream_files
  systemctl restart "$service_name"
  mtproxy_write_summary "$slug"

  echo "MTProto proxy restarted."
  read -rp "Press Enter to return..." _
}

mtproxy_remove() {
  local slug
  local port=""
  local confirm=""
  local service_name
  local service_file
  local info_file
  local env_file

  mtproxy_migrate_legacy_instance
  slug=$(mtproxy_select_instance "Remove Proxy") || return
  mtproxy_load_env "$slug" || err "MTProto proxy is not installed."

  clear
  echo "Remove Telegram MTProto Proxy"
  echo "============================="
  echo "Instance: $MTPROXY_INSTANCE_NAME [$slug]"
  read -rp "Type REMOVE to continue: " confirm
  if [ "$confirm" != "REMOVE" ]; then
    echo "Canceled."
    sleep 1
    return
  fi

  port="${MTPROXY_PORT:-}"
  service_name=$(mtproxy_instance_service_name "$slug")
  service_file=$(mtproxy_instance_service_file "$slug")
  info_file=$(mtproxy_instance_info_file "$slug")
  env_file=$(mtproxy_instance_env_file "$slug")

  systemctl disable --now "$service_name" >/dev/null 2>&1 || true
  rm -f "$service_file" "$env_file" "$info_file"
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
    mtproxy_migrate_legacy_instance
    echo "Telegram Proxy"
    echo "=============="
    echo "Status: $(mtproxy_overview_status)"
    echo "1) Create new MTProto proxy"
    echo "2) Show proxy link"
    echo "3) Rotate secret"
    echo "4) Set/Clear MTProxy tag"
    echo "5) Refresh Telegram upstream config (restart all)"
    echo "6) Restart proxy"
    echo "7) Show status"
    echo "8) List proxies"
    echo "9) Remove proxy"
    echo "10) Back"
    read -rp "Choose [1-10]: " TGCHOICE

    case $TGCHOICE in
      1) mtproxy_create_instance ;;
      2) mtproxy_show_links ;;
      3) mtproxy_rotate_secret ;;
      4) mtproxy_set_tag ;;
      5) mtproxy_refresh_config ;;
      6) mtproxy_restart ;;
      7) mtproxy_show_status ;;
      8) mtproxy_list_proxy_instances ;;
      9) mtproxy_remove ;;
      10) break ;;
      *)
        echo "Invalid choice."
        sleep 1
        ;;
    esac
  done
}
