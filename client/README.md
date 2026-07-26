# Client

VE.Direct client for Raspberry Pi.

This component reads telemetry from a Victron VE.Direct cable and publishes JSON payloads to MQTT.

## What this client does

Data flow:

1. Read VE.Direct serial frames from Victron device
2. Normalize selected fields into JSON
3. Publish to MQTT topic `victron/vedirect/<device_id>`

## Directory layout

- `src/vedirect_mqtt_bridge.py`: Main bridge process
- `.env.example`: Environment template
- `.env`: Active runtime configuration
- `requirements.txt`: Python dependencies
- `systemd/vedirect-mqtt.service`: Main app service unit
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

Example detected VE.Direct path:

`/dev/serial/by-id/usb-VictronEnergy_BV_VE_Direct_cable_<serial>-if00-port0`

## Manual run (test mode)

Install dependencies:

```bash
python3 -m venv .venv
. .venv/bin/activate
pip install -r requirements.txt
```

Run bridge:

```bash
. .venv/bin/activate
python src/vedirect_mqtt_bridge.py
```

Check MQTT stream:

```bash
mosquitto_sub -h 127.0.0.1 -t 'victron/vedirect/#' -v
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
   - `vedirect-app-watchdog.timer`
   - `watchdog.service`

Reboot is recommended once after installation so hardware watchdog is active from early boot.

## Watchdog design

### 1) App watchdog

- Implemented by `vedirect-app-watchdog.timer` + `vedirect-app-watchdog.service`
- Runs every 30 seconds
- If `vedirect-mqtt.service` is not active, it restarts it

### 2) Raspberry hardware watchdog

- Implemented by `watchdog.service` using `/dev/watchdog`
- Kernel boot flag enabled via `/boot/firmware/config.txt`
- If userspace hangs and watchdog is not fed, board is reset by hardware watchdog

## Operations

Check service health:

```bash
systemctl status vedirect-mqtt.service
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