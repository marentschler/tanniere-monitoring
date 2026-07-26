# Server

This directory contains all setup/configuration for the cloud/server side:

- Mosquitto MQTT broker
- Telegraf MQTT consumer
- InfluxDB 2.x
- Grafana with pre-provisioned datasource and dashboard

## Quick start

1. Copy `.env.example` to `.env`.
2. Update secrets and hostnames.
3. Start stack:

   ```bash
   docker compose up -d
   ```

4. Validate services:

   ```bash
   docker compose ps
   ```

## Ports

- `1883`: MQTT (Mosquitto)
- `8086`: InfluxDB API
- `3000`: Grafana UI

## Data path

`MQTT topic victron/vedirect/<device_id> -> Telegraf -> InfluxDB bucket`

Grafana is preconfigured to read from the same InfluxDB bucket.