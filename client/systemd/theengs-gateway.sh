#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="/root/tanniere-monitoring-1/client"
ENV_FILE="$ROOT_DIR/.env"

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${THEENGS_MQTT_HOST:=127.0.0.1}"
: "${THEENGS_MQTT_PORT:=1883}"
: "${THEENGS_TOPIC:=victron/bluetooth}"
: "${THEENGS_TIME_BETWEEN:=60}"
: "${THEENGS_LOG_LEVEL:=INFO}"
: "${THEENGS_BT_KEY:=}"
: "${THEENGS_EXTRA_ARGS:=}"

ARGS=(
  -m TheengsGateway
  -H "$THEENGS_MQTT_HOST"
  -P "$THEENGS_MQTT_PORT"
  -pt "$THEENGS_TOPIC"
  -tb "$THEENGS_TIME_BETWEEN"
  -ll "$THEENGS_LOG_LEVEL"
)

if [[ -n "$THEENGS_BT_KEY" ]]; then
  ARGS+=( -bk "$THEENGS_BT_KEY" )
fi

if [[ -n "$THEENGS_EXTRA_ARGS" ]]; then
  # Intentionally split extra args like a shell command line.
  # shellcheck disable=SC2206
  EXTRA_ARGS=( $THEENGS_EXTRA_ARGS )
  ARGS+=( "${EXTRA_ARGS[@]}" )
fi

exec python3 "${ARGS[@]}"
