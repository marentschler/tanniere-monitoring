# Client

This service reads Victron VE.Direct serial data and publishes normalized JSON payloads to MQTT.

## Files

- `src/vedirect_mqtt_bridge.py`: Main bridge service.
- `.env.example`: Runtime configuration template.
- `requirements.txt`: Python dependencies.
- `systemd/vedirect-mqtt.service`: Optional Linux service unit.

## Quick start

1. Copy `.env.example` to `.env` and update values.
2. Install dependencies:

   ```bash
   pip install -r requirements.txt
   ```

3. Run:

   ```bash
   python src/vedirect_mqtt_bridge.py
   ```

## Notes

- Default serial speed for VE.Direct is `19200` baud.
- Publish topic format is `victron/vedirect/<device_id>`.