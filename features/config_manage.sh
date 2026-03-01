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
