#!/usr/bin/env bash
# Validate config.yaml, generate any missing secrets into it, and render the
# .env file docker compose consumes. Safe to re-run: existing secrets are kept.

. "$(dirname "$0")/lib.sh"

if [ ! -f "$CONFIG_FILE" ]; then
	log "Creating config.yaml from the template"
	cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE" 2>/dev/null || true
	cat <<EOF

Created server/config.yaml. Fill in these three values, then run this script again:

  hcloud_token   Hetzner API token with Read & Write scope
  domain         the hostname Grafana and MQTT will use
  acme_email     where Let's Encrypt sends expiry notices

Everything else has a working default, and the passwords generate themselves.
EOF
	exit 0
fi

load_config
validate_config
ok "config.yaml is valid"

ensure_secrets
render_env
ok "Rendered $ENV_FILE from config.yaml"

cat <<EOF

Credentials
  Grafana    https://${DOMAIN}
             ${GRAFANA_USERNAME} / ${GRAFANA_PASSWORD}

  MQTT       ${DOMAIN}:8883 (TLS)
             ${MQTT_USERNAME} / ${MQTT_PASSWORD}

  InfluxDB   via ./provision/tunnel.sh -> http://localhost:8086
             ${INFLUXDB_USERNAME} / ${INFLUXDB_PASSWORD}

Client configuration -- put this in client/.env on the device with the
VE.Direct cable:

  MQTT_HOST=${DOMAIN}
  MQTT_PORT=8883
  MQTT_TLS=true
  MQTT_USERNAME=${MQTT_USERNAME}
  MQTT_PASSWORD=${MQTT_PASSWORD}

These secrets live only in server/config.yaml, which is never committed.
Back it up somewhere safe.

Next: ./provision/01-create-server.sh
EOF
