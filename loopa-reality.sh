#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/lib/core.sh"
source "$SCRIPT_DIR/features/firewall.sh"
source "$SCRIPT_DIR/features/stats_api.sh"
source "$SCRIPT_DIR/features/config_manage.sh"
source "$SCRIPT_DIR/features/reality.sh"
source "$SCRIPT_DIR/features/vless_single.sh"
source "$SCRIPT_DIR/features/vless_ws.sh"
source "$SCRIPT_DIR/features/vless_ws_fronted.sh"
source "$SCRIPT_DIR/features/vless_ws_tls_fronted.sh"
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
    echo "4) Create new VLESS WebSocket inbound (no TLS)"
    echo "5) Create new VLESS WebSocket fronted profile (seller-01 style)"
    echo "6) Create new VLESS WebSocket TLS fronted profile (seller-02 style)"
    echo "7) Show existing configs (list + QR)"
    echo "8) Delete existing configs"
    echo "9) Firewall (ufw)"
    echo "10) Stats API (CPU/RAM/Load)"
    echo "11) Exit"
    echo "12) Uninstall Loopa/Xray (full cleanup)"
    read -rp "Select an option [1-12]: " CHOICE

    case $CHOICE in
      1) create_reality_inbound ;;
      2) create_vless_tcp_inbound ;;
      3) create_vless_2hop_inbound ;;
      4) create_vless_ws_inbound ;;
      5) create_vless_ws_fronted_profile ;;
      6) create_vless_ws_tls_fronted_profile ;;
      7) show_existing_configs ;;
      8) delete_existing_config ;;
      9) firewall_menu ;;
      10) stats_api_menu ;;
      11) echo "Bye!"; exit 0 ;;
      12) uninstall_loopa_xray ;;
      *)
        echo "Invalid option."
        sleep 1
        ;;
    esac
  done
}

require_root
main_menu
