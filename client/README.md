# Client

VE.Direct + Bluetooth client for Raspberry Pi.

This component reads telemetry from a Victron VE.Direct cable and from a Victron SmartShunt over Bluetooth, then publishes JSON payloads to MQTT.

## What this client does

Data flow:

1. Read VE.Direct serial frames from Victron device
2. Normalize selected fields into JSON
3. Publish VE.Direct telemetry to MQTT topic `victron/vedirect/<device_id>`
4. Publish decoded SmartShunt telemetry to MQTT topic `victron/smartshunt/<device_id>`

## Directory layout

- `src/vedirect_mqtt_bridge.py`: Main bridge process
- `src/smartshunt_mqtt_bridge.py`: SmartShunt Bluetooth bridge process
- `.env.example`: Environment template
- `.env`: Active runtime configuration
- `requirements.txt`: Python dependencies
- `systemd/vedirect-mqtt.service`: Main app service unit
- `systemd/smartshunt-mqtt.service`: SmartShunt Bluetooth bridge service
- `systemd/pair-smartshunt.sh`: Idempotent SmartShunt Bluetooth pairing helper
- `systemd/vedirect-app-watchdog.sh`: App watchdog check script
- `systemd/vedirect-app-watchdog.service`: App watchdog one-shot service
- `systemd/vedirect-app-watchdog.timer`: Periodic watchdog timer
- `systemd/watchdog.conf`: Raspberry hardware watchdog config template
- `systemd/install-services.sh`: Installer for all services

## Prerequisites

- Raspberry Pi running Linux with systemd
- Victron VE.Direct USB cable connected
- Python 3 available
- MQTT broker reachable (local or remote)

## Configuration

All manual inputs are centralized in one file: `.env`.
Do not edit service scripts or unit files for normal configuration changes.

Create your runtime config:

```bash
cp .env.example .env
```

Edit `.env` values:

- `SERIAL_PORT`: VE.Direct serial port path (recommended: `/dev/serial/by-id/...`)
- `SERIAL_BAUDRATE`: Usually `19200`
- `DEVICE_ID`: Device label used in MQTT topic
- `MQTT_HOST`: MQTT broker host/IP
- `MQTT_PORT`: MQTT broker port (default `1883`)
- `MQTT_USERNAME`: MQTT username (optional)
- `MQTT_PASSWORD`: MQTT password (optional)
- `MQTT_TLS`: `true` or `false`
- `MQTT_KEEPALIVE`: Keepalive seconds
- `SMARTSHUNT_DEVICE_ID`: Device label used in the SmartShunt MQTT topic
- `SMARTSHUNT_BT_ADDRESS`: SmartShunt Bluetooth MAC
- `SMARTSHUNT_BT_PIN`: 6-digit VictronConnect PIN, used only when pairing is needed
- `SMARTSHUNT_MAX_FAILURES`: Failed polls before the service restarts itself (default `10`)
- `SMARTSHUNT_POLL_INTERVAL`: Seconds between polls (default `30`)
- `SMARTSHUNT_SCAN_TIMEOUT`: Seconds to look for the device each poll (default `20`)

Example detected VE.Direct path:

`/dev/serial/by-id/usb-VictronEnergy_BV_VE_Direct_cable_<serial>-if00-port0`

## Manual run (test mode)

Install dependencies:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

Run VE.Direct bridge:

```bash
. .venv/bin/activate
python src/vedirect_mqtt_bridge.py
```

Run SmartShunt bridge:

```bash
. .venv/bin/activate
python src/smartshunt_mqtt_bridge.py
```

Check MQTT stream:

```bash
mosquitto_sub -h 127.0.0.1 -t 'victron/vedirect/#' -v
mosquitto_sub -h 127.0.0.1 -t 'victron/smartshunt/#' -v
```

## Install as app service with watchdogs

Run installer:

```bash
sudo ./systemd/install-services.sh
```

What installer does:

1. Installs service/timer files into `/etc/systemd/system`
2. Installs watchdog check script to `/usr/local/bin/vedirect-app-watchdog.sh`
3. Installs `watchdog` package
4. Enables Raspberry watchdog boot flag (`dtparam=watchdog=on`)
5. Enables and starts:
   - `vedirect-mqtt.service`
   - `smartshunt-mqtt.service` (only if `SMARTSHUNT_BT_ADDRESS` is set)
   - `vedirect-app-watchdog.timer`
   - `watchdog.service`

Reboot is recommended once after installation so hardware watchdog is active from early boot.

## Watchdog design

### 1) App watchdog

- Implemented by `vedirect-app-watchdog.timer` + `vedirect-app-watchdog.service`
- Runs every 30 seconds
- If an enabled service (`vedirect-mqtt`, `smartshunt-mqtt`) is not active, it restarts it
- Services left disabled are skipped, so an unconfigured optional service is not restart-looped

### 2) Raspberry hardware watchdog

- Implemented by `watchdog.service` using `/dev/watchdog`
- Kernel boot flag enabled via `/boot/firmware/config.txt`
- If userspace hangs and watchdog is not fed, board is reset by hardware watchdog

## Read-only filesystem mode (best effort)

If your root filesystem is read-only, you cannot keep durable local queues across reboot.

Recommended best-effort pattern:

1. App publishes only to local Mosquitto (`MQTT_HOST=127.0.0.1`)
2. Local Mosquitto bridges to cloud broker over TLS
3. During WAN outages, local Mosquitto keeps a RAM queue
4. When WAN returns, broker forwards backlog

Limits in this mode:

- Data queued in RAM is lost on reboot/power loss.
- This protects against network outages, not power cycles.

### Configure volatile local Mosquitto bridge

In `.env`, set bridge values:

- `BRIDGE_REMOTE_HOST`
- `BRIDGE_REMOTE_PORT` (usually `8883`)
- `BRIDGE_REMOTE_USERNAME`
- `BRIDGE_REMOTE_PASSWORD`
- `BRIDGE_TOPIC` (default `victron/vedirect/#`)
- `BRIDGE_TOPIC_SMARTSHUNT` (default `victron/smartshunt/#`)

Then run:

```bash
sudo /usr/local/bin/configure-mosquitto-bridge.sh
```

This creates `/etc/mosquitto/conf.d/90-victron-bridge.conf` with:

- `persistence false`
- TLS bridge to remote broker
- RAM queue (`max_queued_messages 5000`)

### Verify bridge

```bash
systemctl status mosquitto
journalctl -u mosquitto -n 100 --no-pager
mosquitto_sub -h 127.0.0.1 -t 'victron/vedirect/#' -v
mosquitto_sub -h 127.0.0.1 -t 'victron/smartshunt/#' -v
```

## Operations

Check service health:

```bash
systemctl status vedirect-mqtt.service
systemctl status smartshunt-mqtt.service
systemctl status vedirect-app-watchdog.timer
systemctl status watchdog.service
```

Check timer schedule:

```bash
systemctl list-timers --all | grep vedirect-app-watchdog
```

Tail app logs:

```bash
journalctl -u vedirect-mqtt.service -f
journalctl -u smartshunt-mqtt.service -f
```

Tail app watchdog logs:

```bash
journalctl -u vedirect-app-watchdog.service -f
```

Tail hardware watchdog logs:

```bash
journalctl -u watchdog.service -f
```

Restart app service:

```bash
systemctl restart vedirect-mqtt.service
systemctl restart smartshunt-mqtt.service
```

## Troubleshooting

### No VE.Direct serial device

Check USB and serial nodes:

```bash
lsusb
ls -l /dev/ttyUSB* /dev/ttyACM* /dev/serial/by-id/*
dmesg | grep -Ei 'tty(USB|ACM)|victron|ftdi|cp210|ch34'
```

### MQTT connection refused

- Verify broker host/port in `.env`
- Verify broker is listening
- If local broker is used: `systemctl status mosquitto`

### WAN is down

- Client still publishes to local Mosquitto.
- Local Mosquitto queues in RAM until WAN returns.
- Queue is lost if the device reboots while WAN is still down.

### Service not starting

```bash
systemctl status vedirect-mqtt.service
journalctl -u vedirect-mqtt.service -n 100 --no-pager
```

### Hardware watchdog not active

Check device and boot flag:

```bash
ls -l /dev/watchdog /dev/watchdog0
grep -n '^dtparam=watchdog=on' /boot/firmware/config.txt
systemctl status watchdog.service
```

## Security notes

- Protect `.env` because it may contain MQTT credentials
- Prefer MQTT auth and TLS for remote brokers
- Use firewall rules to restrict MQTT ingress when exposed over network

## Expected MQTT payload

Example topic:

`victron/vedirect/smartsolar-01`

Example payload:

```json
{
  "timestamp": "2026-07-26T14:29:06.714704+00:00",
  "device_id": "smartsolar-01",
  "battery_voltage_v": 13.211,
  "battery_current_a": -3.879,
  "firmware_version": 410,
  "product_id": "0xC030"
}
```
## SmartShunt over Bluetooth

The SmartShunt is read by `smartshunt-mqtt.service` over Victron's vendor **GATT**
service, not from Bluetooth advertisements. This device does not offer "Instant
readout via Bluetooth" - it advertises only a 4-byte product header with no payload -
so passive advertisement decoding cannot work here.

Values come from characteristics under `65970000-4bda-4c1e-af4b-551c4cf74769`, where
each UUID embeds the VE.Direct register id: `6597<reg>-4bda-4c1e-af4b-551c4cf74769`.

### Setup

1. In VictronConnect, enable **Bluetooth GATT** on the shunt and note its 6-digit PIN.
   Enabling Instant Readout is *not* required.
2. Put the MAC in `SMARTSHUNT_BT_ADDRESS` and the PIN in `SMARTSHUNT_BT_PIN`, then
   start the service:

   ```bash
   systemctl enable --now smartshunt-mqtt.service
   journalctl -u smartshunt-mqtt.service -f
   ```

Pairing is automatic. `pair-smartshunt.sh` runs as an `ExecStartPre` and pairs the
device when no bond exists, retrying up to three times; when the bond is already
present it exits immediately. Supplying the passkey needs a Bluetooth agent, which the
bridge process cannot provide, so it is done there via `bluetoothctl` rather than in
Python. Pairing also requires an active LE scan with the transport filter set, which
the helper handles.

To pair by hand instead, or to check the bond:

```bash
/usr/local/bin/pair-smartshunt.sh          # idempotent
bluetoothctl info <MAC>                    # expect Paired: yes / Bonded: yes
```

If the bond is lost while running, polls start failing; after
`SMARTSHUNT_MAX_FAILURES` consecutive failures the bridge exits so systemd restarts it
and the pairing step runs again.

### Polling model

The shunt accepts a single Bluetooth connection at a time. The bridge therefore
connects, reads, disconnects, and sleeps `SMARTSHUNT_POLL_INTERVAL` seconds, so the
device stays reachable from VictronConnect between polls and a wedged connection
cannot lock everyone out. A failed poll is logged and retried on the next cycle.

### Published fields

`battery_voltage_v`, `battery_current_a`, `battery_power_w`, `state_of_charge_pct`,
`consumed_ah`, `time_to_go_min`, `starter_voltage_v`, `temperature_c`.

Registers the shunt reports as not-available are omitted from the payload rather than
published as nulls. Expect `state_of_charge_pct`, `consumed_ah` and `time_to_go_min`
to be missing until the shunt has its battery capacity configured and has been
synchronised by a full charge; `starter_voltage_v` and `temperature_c` are absent
unless something is wired to the aux input.

Voltage, current and power scalings are confirmed against a real device (reported
power matches voltage x current). The remaining scalings come from Victron's register
list and are unverified while those registers read as not-available.
