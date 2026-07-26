#!/usr/bin/env bash
# Validate config.yaml, generate any missing secrets into it, and render the
# .env file docker compose consumes. Safe to re-run: existing secrets are kept.

. "$(dirname "$0")/lib.sh"

if [ ! -f "$CONFIG_FILE" ]; then
	log "Creating config.yaml from the template"
	cp "$CONFIG_EXAMPLE" "$CONFIG_FILE"
	chmod 600 "$CONFIG_FILE" 2>/dev/null || true
	cat <<EOF

Created server/config.yaml. Fill in these required values, then run this script again:

  hcloud_token   Hetzner API token with Read & Write scope
                 (or export HCLOUD_TOKEN in your shell)

And choose one domain mode:

  domain         set your own hostname and DNS A record manually
  OR
  auto_domain    set to true to use <server-ip>.sslip.io automatically

Optional:

  acme_email         contact email for Let's Encrypt (defaults to admin@<domain>)
  dyndns_update_url  provider update URL with {ip} and optionally {domain}
  google_dns_*       enable native Google Cloud DNS updates (project/zone/record)

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

if [ -n "$DOMAIN" ]; then
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
else
cat <<EOF

Credentials (domain pending)
  auto_domain is enabled, so DOMAIN will be generated after the server is created.
  Expected format: <server-ip>.${AUTO_DOMAIN_SUFFIX}

MQTT and Grafana credentials are ready and saved in config.yaml.

Next: ./provision/01-create-server.sh
EOF
fi
