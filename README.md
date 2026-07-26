# tanniere-monitoring

End-to-end Victron VE.Direct monitoring stack with MQTT transport, InfluxDB storage, and Grafana dashboards.

Project layout:

- `client/`: Edge service that reads VE.Direct serial data and publishes it to MQTT.
- `server/`: Cloud/server stack (MQTT broker + Telegraf + InfluxDB + Grafana).

## 1) Client setup (VE.Direct -> MQTT)

1. Go to `client/`.
2. Copy `.env.example` to `.env` and set your values.
3. Install dependencies:

	```bash
	pip install -r requirements.txt
	```

4. Start bridge:

	```bash
	python src/vedirect_mqtt_bridge.py
	```

## 2) Server setup (MQTT -> InfluxDB -> Grafana)

1. Go to `server/`.
2. Copy `.env.example` to `.env` and update secrets.
3. Start stack:

	```bash
	docker compose up -d
	```

4. Open Grafana at `http://<server-host>:3000` and log in with credentials from `.env`.

## Data flow

`Victron VE.Direct device -> client bridge -> MQTT topic victron/vedirect/<device_id> -> Telegraf -> InfluxDB -> Grafana`
