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
