#!/usr/bin/env bash
# Runs ON THE SERVER as root, invoked by provision/02-deploy-stack.sh.
# Prepares MQTT auth, obtains the TLS certificate, then brings the stack up.

set -euo pipefail

DIR="${REMOTE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$DIR"

log()  { printf '==> %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*" >&2; }
die()  { printf 'error %s\n' "$*" >&2; exit 1; }

[ -f .env ] || die "No .env in $DIR"

# .env is usually authored on Windows. A stray CR would end up inside DOMAIN and
# break certificate issuance in a way that is very tedious to diagnose.
if grep -q $'\r' .env; then
	log "Normalising CRLF line endings in .env"
	sed -i 's/\r$//' .env
fi

set -a
# shellcheck disable=SC1091
. ./.env
set +a

: "${DOMAIN:?DOMAIN must be set in .env}"
: "${MQTT_USERNAME:?MQTT_USERNAME must be set in .env}"
: "${MQTT_PASSWORD:?MQTT_PASSWORD must be set in .env}"

command -v docker >/dev/null 2>&1 || die "Docker is not installed. Did cloud-init finish?"

log "Creating data directories"
mkdir -p mosquitto/certs data/caddy-data data/caddy-config
chmod 700 data

log "Writing MQTT credentials for user '$MQTT_USERNAME'"
bash scripts/mqtt-user.sh "$MQTT_USERNAME" "$MQTT_PASSWORD"

log "Installing the certificate sync timer"
sed "s|__REMOTE_DIR__|$DIR|g" systemd/mqtt-cert-sync.service >/etc/systemd/system/mqtt-cert-sync.service
install -m 0644 systemd/mqtt-cert-sync.timer /etc/systemd/system/mqtt-cert-sync.timer
systemctl daemon-reload
systemctl enable --now mqtt-cert-sync.timer

# Caddy has to obtain the certificate before Mosquitto's TLS listener can bind,
# so bring up everything that does not depend on it first.
log "Starting Caddy, InfluxDB and Grafana"
docker compose up -d caddy influxdb grafana

log "Waiting for the Let's Encrypt certificate for $DOMAIN (up to 180s)"
cert_ready=false
for _ in $(seq 1 36); do
	if bash scripts/sync-mqtt-certs.sh --quiet; then
		cert_ready=true
		break
	fi
	sleep 5
done

if [ "$cert_ready" = true ]; then
	log "Certificate installed for Mosquitto"
else
	warn "No certificate yet for $DOMAIN."
	warn "Most likely the DNS A record does not point at this server, or port 80 is blocked."
	warn "Caddy retries on its own; once it succeeds the mqtt-cert-sync timer picks the"
	warn "certificate up (within 12h) or you can force it with:"
	warn "  sudo systemctl start mqtt-cert-sync.service"
	warn "Mosquitto will restart-loop until the certificate exists. Check with:"
	warn "  docker compose logs caddy"
fi

log "Starting the full stack"
docker compose up -d

log "Current state"
docker compose ps
