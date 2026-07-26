#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/root/tanniere-monitoring-1/client"
SYSTEMD_DIR="/etc/systemd/system"

install -m 0755 "$ROOT_DIR/systemd/vedirect-app-watchdog.sh" /usr/local/bin/vedirect-app-watchdog.sh
install -m 0755 "$ROOT_DIR/systemd/configure-mosquitto-bridge.sh" /usr/local/bin/configure-mosquitto-bridge.sh
install -m 0755 "$ROOT_DIR/systemd/pair-smartshunt.sh" /usr/local/bin/pair-smartshunt.sh
install -m 0644 "$ROOT_DIR/systemd/vedirect-mqtt.service" "$SYSTEMD_DIR/vedirect-mqtt.service"
install -m 0644 "$ROOT_DIR/systemd/smartshunt-mqtt.service" "$SYSTEMD_DIR/smartshunt-mqtt.service"
install -m 0644 "$ROOT_DIR/systemd/vedirect-app-watchdog.service" "$SYSTEMD_DIR/vedirect-app-watchdog.service"
install -m 0644 "$ROOT_DIR/systemd/vedirect-app-watchdog.timer" "$SYSTEMD_DIR/vedirect-app-watchdog.timer"

if ! grep -q '^dtparam=watchdog=on' /boot/firmware/config.txt; then
  echo 'dtparam=watchdog=on' >> /boot/firmware/config.txt
fi

apt-get update
apt-get install -y watchdog
install -m 0644 "$ROOT_DIR/systemd/watchdog.conf" /etc/watchdog.conf

systemctl daemon-reload
systemctl enable --now vedirect-mqtt.service
# The SmartShunt bridge needs a paired device to talk to, so it is only enabled once
# an address is configured. Pairing itself is a manual step, see README.md.
if grep -qE '^SMARTSHUNT_BT_ADDRESS=.+' "$ROOT_DIR/.env"; then
  systemctl enable --now smartshunt-mqtt.service
else
  echo "SMARTSHUNT_BT_ADDRESS not set in .env; leaving smartshunt-mqtt.service disabled."
  echo "Pair the shunt (see README.md), set the address, then:"
  echo "  systemctl enable --now smartshunt-mqtt.service"
fi
systemctl enable --now vedirect-app-watchdog.timer
systemctl enable --now watchdog.service

echo "Services installed. Reboot recommended to ensure hardware watchdog is active from boot."