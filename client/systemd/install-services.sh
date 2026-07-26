#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/root/tanniere-monitoring-1/client"
SYSTEMD_DIR="/etc/systemd/system"

install -m 0755 "$ROOT_DIR/systemd/vedirect-app-watchdog.sh" /usr/local/bin/vedirect-app-watchdog.sh
install -m 0644 "$ROOT_DIR/systemd/vedirect-mqtt.service" "$SYSTEMD_DIR/vedirect-mqtt.service"
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
systemctl enable --now vedirect-app-watchdog.timer
systemctl enable --now watchdog.service

echo "Services installed. Reboot recommended to ensure hardware watchdog is active from boot."