#!/usr/bin/env python3
import json
import logging
import os
import signal
import sys
from datetime import datetime, timezone
from typing import Dict, Optional

import paho.mqtt.client as mqtt
import serial
from dotenv import load_dotenv


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(message)s",
)
logger = logging.getLogger("vedirect-mqtt")


def parse_bool(value: str, default: bool = False) -> bool:
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


def coerce_number(value: str):
    try:
        return int(value)
    except ValueError:
        try:
            return float(value)
        except ValueError:
            return value


def build_payload(device_id: str, frame: Dict[str, str]) -> Dict:
    values = {k: coerce_number(v) for k, v in frame.items() if k != "Checksum"}

    payload = {
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "device_id": device_id,
        "battery_voltage_v": round(values["V"] / 1000.0, 3) if "V" in values else None,
        "battery_current_a": round(values["I"] / 1000.0, 3) if "I" in values else None,
        "panel_voltage_v": round(values["VPV"] / 1000.0, 3) if "VPV" in values else None,
        "panel_power_w": values.get("PPV"),
        "load_current_a": round(values["IL"] / 1000.0, 3) if "IL" in values else None,
        "yield_today_kwh": round(values["H20"] / 100.0, 3) if "H20" in values else None,
        "yield_yesterday_kwh": round(values["H22"] / 100.0, 3) if "H22" in values else None,
        "max_power_today_w": values.get("H21"),
        "max_power_yesterday_w": values.get("H23"),
        "charger_state": values.get("CS"),
        "mppt_state": values.get("MPPT"),
        "error_code": values.get("ERR"),
        "relay_state": values.get("Relay"),
        "firmware_version": values.get("FW"),
        "product_id": values.get("PID"),
        "serial_number": values.get("SER#"),
    }

    return {k: v for k, v in payload.items() if v is not None}


class VEDirectMQTTBridge:
    def __init__(self):
        load_dotenv()

        self.serial_port = os.getenv("SERIAL_PORT", "/dev/ttyUSB0")
        self.serial_baudrate = int(os.getenv("SERIAL_BAUDRATE", "19200"))
        self.device_id = os.getenv("DEVICE_ID", "victron-device")

        self.mqtt_host = os.getenv("MQTT_HOST", "127.0.0.1")
        self.mqtt_port = int(os.getenv("MQTT_PORT", "1883"))
        self.mqtt_username = os.getenv("MQTT_USERNAME")
        self.mqtt_password = os.getenv("MQTT_PASSWORD")
        self.mqtt_tls = parse_bool(os.getenv("MQTT_TLS", "false"))
        self.mqtt_keepalive = int(os.getenv("MQTT_KEEPALIVE", "60"))

        self.topic = f"victron/vedirect/{self.device_id}"
        self.running = True
        self.frame: Dict[str, str] = {}

        self.client = mqtt.Client(mqtt.CallbackAPIVersion.VERSION2, client_id=f"vedirect-{self.device_id}")
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

    def stop(self, signum: int, frame):
        logger.info("Received signal %s, shutting down", signum)
        self.running = False

    def publish_frame(self):
        payload = build_payload(self.device_id, self.frame)
        message = json.dumps(payload)
        result = self.client.publish(self.topic, message, qos=1, retain=False)

        if result.rc == mqtt.MQTT_ERR_SUCCESS:
            logger.info("Published payload for %s", self.device_id)
        else:
            logger.error("Failed to publish payload (rc=%s)", result.rc)

    def run(self):
        signal.signal(signal.SIGINT, self.stop)
        signal.signal(signal.SIGTERM, self.stop)

        self.client.connect(self.mqtt_host, self.mqtt_port, self.mqtt_keepalive)
        self.client.loop_start()

        logger.info("Opening VE.Direct serial port %s at %d baud", self.serial_port, self.serial_baudrate)
        with serial.Serial(self.serial_port, self.serial_baudrate, timeout=1) as ser:
            while self.running:
                line = ser.readline().decode("utf-8", errors="ignore").strip()
                if not line or "\t" not in line:
                    continue

                key, value = line.split("\t", 1)
                self.frame[key] = value

                if key == "Checksum":
                    self.publish_frame()
                    self.frame = {}

        self.client.loop_stop()
        self.client.disconnect()


if __name__ == "__main__":
    try:
        bridge = VEDirectMQTTBridge()
        bridge.run()
    except serial.SerialException as err:
        logger.error("Unable to open serial port: %s", err)
        sys.exit(1)
    except Exception as err:
        logger.exception("Fatal error: %s", err)
        sys.exit(1)