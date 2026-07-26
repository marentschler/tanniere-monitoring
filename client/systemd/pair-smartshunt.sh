#!/usr/bin/env bash
# Ensure the SmartShunt is paired and trusted with this host's Bluetooth adapter.
#
# Idempotent: exits 0 immediately when the bond already exists, so it is safe as an
# ExecStartPre for smartshunt-mqtt.service. Pairing needs a passkey agent, which the
# bridge process cannot provide, so it is done here via bluetoothctl.
set -uo pipefail

ROOT_DIR="/root/tanniere-monitoring-1/client"
ENV_FILE="$ROOT_DIR/.env"
ATTEMPTS=3

if [[ -f "$ENV_FILE" ]]; then
  set -a
  # shellcheck disable=SC1090
  source "$ENV_FILE"
  set +a
fi

: "${SMARTSHUNT_BT_ADDRESS:=}"
: "${SMARTSHUNT_BT_PIN:=}"

if [[ -z "$SMARTSHUNT_BT_ADDRESS" ]]; then
  echo "SMARTSHUNT_BT_ADDRESS is not set in $ENV_FILE"
  exit 1
fi

MAC="$SMARTSHUNT_BT_ADDRESS"

is_paired() {
  bluetoothctl info "$MAC" 2>/dev/null | grep -qE '^[[:space:]]*Paired: yes'
}

is_trusted() {
  bluetoothctl info "$MAC" 2>/dev/null | grep -qE '^[[:space:]]*Trusted: yes'
}

# bluetoothctl echoes the passkey back, so its output is never logged verbatim.
run_bluetoothctl() {
  timeout 120 bluetoothctl >/dev/null 2>&1
}

if is_paired; then
  echo "SmartShunt $MAC is already paired"
  if ! is_trusted; then
    echo "Marking $MAC as trusted"
    bluetoothctl trust "$MAC" >/dev/null 2>&1
  fi
  exit 0
fi

if [[ -z "$SMARTSHUNT_BT_PIN" ]]; then
  echo "$MAC is not paired and SMARTSHUNT_BT_PIN is not set in $ENV_FILE."
  echo "Set the shunt's 6-digit VictronConnect PIN, or pair manually (see README.md)."
  exit 1
fi

for attempt in $(seq 1 "$ATTEMPTS"); do
  echo "Pairing with SmartShunt $MAC (attempt $attempt/$ATTEMPTS)"

  # An active LE scan is required for BlueZ to keep a device object around long
  # enough to pair, and the transport filter must be set before scanning.
  {
    echo "power on";            sleep 1
    echo "agent KeyboardDisplay"; sleep 1
    echo "default-agent";       sleep 1
    echo "menu scan";           sleep 1
    echo "transport le";        sleep 1
    echo "back";                sleep 1
    echo "scan on";             sleep 18
    echo "pair $MAC";           sleep 8
    echo "$SMARTSHUNT_BT_PIN";  sleep 15
    echo "trust $MAC";          sleep 3
    echo "scan off";            sleep 2
    echo "quit"
  } | run_bluetoothctl

  if is_paired; then
    echo "Paired with $MAC"
    is_trusted || bluetoothctl trust "$MAC" >/dev/null 2>&1
    exit 0
  fi

  echo "Pairing attempt $attempt did not succeed"
done

echo "Could not pair with $MAC after $ATTEMPTS attempts."
echo "Check that the shunt is in range and that Bluetooth GATT is enabled on it."
exit 1
