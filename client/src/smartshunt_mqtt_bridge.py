#!/usr/bin/env python3
"""Publish Victron SmartShunt telemetry to MQTT, read over Bluetooth GATT.

This device does not support "Instant readout via Bluetooth" (it advertises only a
4-byte product header with no payload), so values are read from Victron's vendor
GATT service instead. Each characteristic under 65970000-4bda-4c1e-af4b-551c4cf74769
maps to a VE.Direct register whose id is embedded in the UUID: 6597<reg>-4bda-...

The shunt accepts a single Bluetooth connection at a time, so this bridge connects,
reads, disconnects, and sleeps. That keeps the device reachable from VictronConnect
between polls and stops a wedged connection from locking everyone out.

Pairing is handled before start by pair-smartshunt.sh (an ExecStartPre in the unit),
because supplying the passkey needs a Bluetooth agent. If polling keeps failing - the
usual cause being a lost bond - this process exits so systemd restarts it and that
pairing step runs again.
"""
import asyncio
import json
import logging
import os
import signal
import struct
import sys
from datetime import datetime, timezone
from typing import Dict, Optional

import paho.mqtt.client as mqtt
from bleak import BleakClient, BleakScanner
from dotenv import load_dotenv


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("smartshunt-mqtt")

VICTRON_SERVICE_SUFFIX = "-4bda-4c1e-af4b-551c4cf74769"

# Sentinel each width uses to mean "not available".
NOT_AVAILABLE = {
    "<h": 0x7FFF,
    "<H": 0xFFFF,
    "<i": 0x7FFFFFFF,
    "<I": 0xFFFFFFFF,
}

# (register, payload field, struct format, scale)
# Voltage, current and power scalings are confirmed against this device: the reported
# power matches voltage * current. The rest come from Victron's register list and read
# as not-available until the shunt is configured and synchronised, so their scaling is
# unverified here.
REGISTERS = (
    ("ed8d", "battery_voltage_v", "<h", 0.01),
    ("ed8c", "battery_current_a", "<i", 0.001),
    ("ed8e", "battery_power_w", "<h", 1),
    ("0fff", "state_of_charge_pct", "<H", 0.01),
    ("eeff", "consumed_ah", "<i", 0.1),
    ("0ffe", "time_to_go_min", "<H", 1),
    ("ed7d", "starter_voltage_v", "<h", 0.01),
)

# Read separately: reported in 0.01 K and published as Celsius.
TEMPERATURE_REGISTER = "edec"


def parse_bool(value: str, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def characteristic(register: str) -> str:
    return f"6597{register}{VICTRON_SERVICE_SUFFIX}"


def decode(raw: bytes, fmt: str, scale) -> Optional[float]:
    """Decode a register value, returning None when the shunt reports no value."""
    try:
        value = struct.unpack(fmt, raw)[0]
    except struct.error:
        logger.warning("Unexpected width for %s value %s", fmt, raw.hex())
        return None

    if value == NOT_AVAILABLE[fmt]:
        return None

    scaled = value * scale
    return round(scaled, 3) if isinstance(scale, float) else scaled


class SmartShuntMQTTBridge:
    def __init__(self):
        load_dotenv()

        self.address = (os.getenv("SMARTSHUNT_BT_ADDRESS") or "").strip()
        self.device_id = os.getenv("SMARTSHUNT_DEVICE_ID", "smartshunt-01")
        self.poll_interval = int(os.getenv("SMARTSHUNT_POLL_INTERVAL", "30"))
        self.scan_timeout = int(os.getenv("SMARTSHUNT_SCAN_TIMEOUT", "20"))
        self.max_failures = int(os.getenv("SMARTSHUNT_MAX_FAILURES", "10"))
        self.failures = 0

        self.mqtt_host = os.getenv("MQTT_HOST", "127.0.0.1")
        self.mqtt_port = int(os.getenv("MQTT_PORT", "1883"))
        self.mqtt_username = os.getenv("MQTT_USERNAME")
        self.mqtt_password = os.getenv("MQTT_PASSWORD")
        self.mqtt_tls = parse_bool(os.getenv("MQTT_TLS", "false"))
        self.mqtt_keepalive = int(os.getenv("MQTT_KEEPALIVE", "60"))

        self.topic = f"victron/smartshunt/{self.device_id}"
        self.running = True

        self.client = mqtt.Client(
            mqtt.CallbackAPIVersion.VERSION2, client_id=f"smartshunt-{self.device_id}"
        )
        if self.mqtt_username:
            self.client.username_pw_set(self.mqtt_username, self.mqtt_password)
        if self.mqtt_tls:
            self.client.tls_set()

        self.client.on_connect = self.on_connect
        self.client.on_disconnect = self.on_disconnect

    def on_connect(self, client, userdata, flags, reason_code, properties):
        if reason_code == 0:
            logger.info("Connected to MQTT broker %s:%s", self.mqtt_host, self.mqtt_port)
        else:
            logger.error("MQTT connection failed with reason code: %s", reason_code)

    def on_disconnect(self, client, userdata, flags, reason_code, properties):
        if self.running:
            logger.warning("MQTT disconnected (reason code: %s)", reason_code)

    def stop(self):
        logger.info("Shutting down")
        self.running = False

    async def read_once(self) -> Optional[Dict]:
        """Connect, read every register, disconnect. None if the device is unreachable."""
        device = await BleakScanner.find_device_by_address(
            self.address, timeout=self.scan_timeout
        )
        if device is None:
            logger.warning("SmartShunt %s not found while scanning", self.address)
            return None

        values: Dict = {}
        async with BleakClient(device, timeout=30) as client:
            for register, field, fmt, scale in REGISTERS:
                try:
                    raw = await client.read_gatt_char(characteristic(register))
                except Exception as err:
                    logger.warning(
                        "Could not read register 0x%s (%s): %s", register.upper(), field, err
                    )
                    continue

                decoded = decode(raw, fmt, scale)
                if decoded is not None:
                    values[field] = decoded

            try:
                raw = await client.read_gatt_char(characteristic(TEMPERATURE_REGISTER))
                kelvin = decode(raw, "<H", 0.01)
                if kelvin is not None:
                    values["temperature_c"] = round(kelvin - 273.15, 2)
            except Exception as err:
                logger.warning("Could not read battery temperature: %s", err)

        return values

    def build_payload(self, values: Dict) -> Dict:
        payload = {
            "timestamp": datetime.now(timezone.utc).isoformat(),
            "device_id": self.device_id,
        }
        payload.update(values)
        return payload

    def publish(self, values: Dict):
        message = json.dumps(self.build_payload(values))
        result = self.client.publish(self.topic, message, qos=1, retain=False)

        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            logger.info(
                "Published %d values for %s (%s)",
                len(values),
                self.device_id,
                ", ".join(f"{k}={v}" for k, v in values.items()),
            )
        else:
            logger.error("Failed to publish payload (rc=%s)", result.rc)

    async def sleep_until_next_poll(self):
        """Sleep in short steps so a shutdown signal is acted on promptly."""
        for _ in range(self.poll_interval):
            if not self.running:
                return
            await asyncio.sleep(1)

    async def run(self):
        loop = asyncio.get_running_loop()
        for sig in (signal.SIGINT, signal.SIGTERM):
            loop.add_signal_handler(sig, self.stop)

        self.client.connect(self.mqtt_host, self.mqtt_port, self.mqtt_keepalive)
        self.client.loop_start()

        logger.info(
            "Polling SmartShunt %s every %ss", self.address, self.poll_interval
        )
        while self.running:
            try:
                values = await self.read_once()
            except Exception as err:
                # A failed poll is normal (device asleep, radio contention); the next
                # cycle retries rather than taking the service down.
                logger.warning("Poll failed: %s: %s", type(err).__name__, err)
                values = None

            if values:
                self.failures = 0
                self.publish(values)
            else:
                if values is not None:
                    logger.warning("Connected but no registers returned a value")
                self.failures += 1
                if self.failures >= self.max_failures:
                    # Most often a dropped bond. Exiting lets systemd restart us, which
                    # re-runs the pairing step; looping here would never recover.
                    logger.error(
                        "%d consecutive failed polls; exiting so the service restarts "
                        "and re-checks pairing",
                        self.failures,
                    )
                    self.client.loop_stop()
                    self.client.disconnect()
                    return 1

            await self.sleep_until_next_poll()

        self.client.loop_stop()
        self.client.disconnect()
        return 0


def main() -> Optional[int]:
    bridge = SmartShuntMQTTBridge()

    if not bridge.address:
        logger.error("SMARTSHUNT_BT_ADDRESS is not set in .env")
        return 1

    return asyncio.run(bridge.run())


if __name__ == "__main__":
    try:
        sys.exit(main())
    except Exception as err:
        logger.exception("Fatal error: %s", err)
        sys.exit(1)
