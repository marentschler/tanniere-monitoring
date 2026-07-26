#!/usr/bin/env bash
set -euo pipefail

SERVICES=(
  "vedirect-mqtt.service"
  "theengs-gateway.service"
)

for service in "${SERVICES[@]}"; do
  if ! systemctl is-active --quiet "$service"; then
    logger -t vedirect-app-watchdog "$service inactive, restarting"
    systemctl restart "$service"
  fi
done