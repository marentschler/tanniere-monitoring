#!/usr/bin/env bash
set -euo pipefail

SERVICES=(
  "vedirect-mqtt.service"
  "smartshunt-mqtt.service"
)

for service in "${SERVICES[@]}"; do
  # Never resurrect a service that was deliberately left disabled, otherwise an
  # unconfigured optional service gets restarted every time the timer fires.
  if ! systemctl is-enabled --quiet "$service"; then
    continue
  fi

  if ! systemctl is-active --quiet "$service"; then
    logger -t vedirect-app-watchdog "$service inactive, restarting"
    systemctl restart "$service"
  fi
done