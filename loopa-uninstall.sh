cat > ~/loopa-uninstall.sh <<'SH'
#!/bin/bash
set -e

echo "=== Loopa / Xray UNINSTALL helper ==="
echo "This will stop Xray, remove configs, binaries, keys, log files, and optional packages."
echo

# ask for confirmation
read -p "Are you sure you want to proceed? THIS WILL REMOVE Xray and Loopa files (y/N): " CONF
[ "${CONF,,}" != "y" ] && echo "Aborted." && exit 0

# Stop & disable service
if systemctl list-unit-files | grep -q '^xray.service'; then
  echo "Stopping and disabling xray.service..."
  sudo systemctl stop xray || true
  sudo systemctl disable xray || true
fi

# Kill any running xray
echo "Killing any running xray processes..."
pkill -9 xray 2>/dev/null || true

# Remove typical Loopa/Xray files and directories
TO_REMOVE=(
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
  "/etc/systemd/system/xray.service.d/10-donot_touch_single_conf.conf"
)

echo "The script will remove the following paths if they exist:"
for p in "${TO_REMOVE[@]}"; do
  echo "  $p"
done
echo
read -p "Proceed to delete the above files/directories? (y/N): " RM_FILES
if [ "${RM_FILES,,}" = "y" ]; then
  for p in "${TO_REMOVE[@]}"; do
    if [ -e "$p" ]; then
      echo "Removing $p ..."
      rm -rf "$p" || true
    fi
  done
  # reload systemd
  systemctl daemon-reload || true
  systemctl reset-failed || true
  echo "Removed files and reloaded systemd."
else
  echo "Skipping deletion of files."
fi

# Remove user-created loopa files in home
echo
echo "Removing user-local loopa files (~/loopa-reality-*.txt, /tmp/loopa*, /tmp/xray*) ..."
rm -f ~/loopa-reality-*.txt /tmp/loopa* /tmp/xray* 2>/dev/null || true

# Optionally remove packages installed earlier
echo
read -p "Remove packages jq, qrencode, openssl, curl? (y/N): " RM_PKG
if [ "${RM_PKG,,}" = "y" ]; then
  echo "Removing packages (apt remove -y) ..."
  apt remove -y jq qrencode openssl curl || true
  apt autoremove -y || true
else
  echo "Skipping package removal."
fi

echo
echo "=== Done. Summary ==="
echo " - Xray service stopped/disabled (if existed)."
echo " - Candidate xray files/directories removed (if you accepted)."
echo " - Local loopa files removed."
echo
echo "If you want, reboot the server to ensure all leftover processes are gone."
SH

chmod +x ~/loopa-uninstall.sh
echo "Uninstall script created at ~/loopa-uninstall.sh"
echo "Run it with: sudo ~/loopa-uninstall.sh"
