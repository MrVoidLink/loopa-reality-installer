#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/features/firewall.sh"
source "$SCRIPT_DIR/features/stats_api.sh"
source "$SCRIPT_DIR/features/config_manage.sh"
source "$SCRIPT_DIR/features/reality.sh"
source "$SCRIPT_DIR/features/vless_single.sh"
source "$SCRIPT_DIR/features/uninstall.sh"

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
    echo "8) Uninstall Loopa/Xray (full cleanup)"
    read -rp "Select an option [1-8]: " CHOICE

    case $CHOICE in
      1) create_reality_inbound ;;
      2) create_vless_tcp_inbound ;;
      3) show_existing_configs ;;
      4) delete_existing_config ;;
      5) firewall_menu ;;
      6) stats_api_menu ;;
      7) echo "Bye!"; exit 0 ;;
      8) uninstall_loopa_xray ;;
      *)
        echo "Invalid option."
        sleep 1
        ;;
    esac
  done
}

require_root
main_menu
