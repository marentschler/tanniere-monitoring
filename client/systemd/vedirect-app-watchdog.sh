#!/usr/bin/env bash
set -euo pipefail

SERVICE_NAME="vedirect-mqtt.service"

if ! systemctl is-active --quiet "$SERVICE_NAME"; then
  logger -t vedirect-app-watchdog "$SERVICE_NAME inactive, restarting"
  systemctl restart "$SERVICE_NAME"
fi