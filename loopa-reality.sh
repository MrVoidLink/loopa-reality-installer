#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/features/firewall.sh"
source "$SCRIPT_DIR/features/stats_api.sh"
source "$SCRIPT_DIR/features/config_manage.sh"
source "$SCRIPT_DIR/features/reality.sh"
source "$SCRIPT_DIR/features/vless_single.sh"
source "$SCRIPT_DIR/features/vless_2hop.sh"
source "$SCRIPT_DIR/features/uninstall.sh"

main_menu() {
  while true; do
    clear
    echo "Loopa Xray Wizard (v5.0)"
    echo "========================"
    echo "1) Create new Reality inbound"
    echo "2) Create new VLESS TCP inbound (no TLS)"
    echo "3) Create new VLESS TCP 2-Hop (IRAN -> FOREIGN, no TLS)"
    echo "4) Show existing configs (list + QR)"
    echo "5) Delete existing configs"
    echo "6) Firewall (ufw)"
    echo "7) Stats API (CPU/RAM/Load)"
    echo "8) Exit"
    echo "9) Uninstall Loopa/Xray (full cleanup)"
    read -rp "Select an option [1-9]: " CHOICE

    case $CHOICE in
      1) create_reality_inbound ;;
      2) create_vless_tcp_inbound ;;
      3) create_vless_2hop_inbound ;;
      4) show_existing_configs ;;
      5) delete_existing_config ;;
      6) firewall_menu ;;
      7) stats_api_menu ;;
      8) echo "Bye!"; exit 0 ;;
      9) uninstall_loopa_xray ;;
      *)
        echo "Invalid option."
        sleep 1
        ;;
    esac
  done
}

require_root
main_menu
