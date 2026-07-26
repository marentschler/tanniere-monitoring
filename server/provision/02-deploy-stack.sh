#!/usr/bin/env bash
# Ship the server/ directory to the Hetzner host and (re)start the stack.
# Idempotent: run it again after any change to config.yaml or the service configs.

. "$(dirname "$0")/lib.sh"

load_config
validate_config
require_cmd hcloud ssh tar

# config.yaml is the single source of truth, so re-render .env on every deploy.
ensure_secrets
render_env
ok "config.yaml is valid, .env rendered"

require_server_ip

# DNS must resolve to this host or the ACME HTTP-01 challenge cannot succeed.
if command -v nslookup >/dev/null 2>&1; then
	if nslookup "$DOMAIN" 2>/dev/null | grep -q "$SERVER_IP"; then
		ok "DNS: $DOMAIN resolves to $SERVER_IP"
	else
		warn "DNS: $DOMAIN does not resolve to $SERVER_IP (yet)."
		warn "Caddy will keep retrying, but HTTPS and MQTT TLS stay down until it does."
		warn "Create an A record:  ${DOMAIN}.  A  ${SERVER_IP}"
	fi
fi

# -------------------------------------------------------------------- upload ----
log "Uploading stack to ${DEPLOY_USER}@${SERVER_IP}:${REMOTE_DIR}"
remote "mkdir -p '$REMOTE_DIR'"

# config.yaml is deliberately excluded: it holds the Hetzner API token, which the
# server has no need for. The rendered .env carries everything the stack needs.
tar czf - -C "$SERVER_DIR" \
	--exclude='./data' \
	--exclude='./config.yaml' \
	--exclude='./mosquitto/certs' \
	--exclude='./mosquitto/passwd' \
	--exclude='./influxdb-data' \
	--exclude='./grafana-data' \
	. | remote "tar xzf - -C '$REMOTE_DIR'"

remote "chmod 600 '$REMOTE_DIR/.env' && chmod +x '$REMOTE_DIR'/scripts/*.sh"
ok "Files uploaded"

# ------------------------------------------------------------------ bootstrap ----
log "Running server bootstrap (compose up, TLS certificate, MQTT auth)"
remote_root "REMOTE_DIR='$REMOTE_DIR' bash '$REMOTE_DIR/scripts/server-bootstrap.sh'"

echo
ok "Deploy finished"
cat <<EOF

  Grafana   https://${DOMAIN}    (${GRAFANA_USERNAME} / password in config.yaml)
  MQTT TLS  ${DOMAIN}:8883       (${MQTT_USERNAME} / password in config.yaml)

  Status    ./provision/status.sh
  Logs      ./provision/ssh.sh 'cd ${REMOTE_DIR} && docker compose logs -f'
EOF
