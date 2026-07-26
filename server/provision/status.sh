#!/usr/bin/env bash
# Health snapshot: containers, TLS, and whether data is actually landing in InfluxDB.

. "$(dirname "$0")/lib.sh"

load_config
require_cmd hcloud ssh
require_server_ip

BUCKET="$INFLUXDB_BUCKET"

log "Server: $SERVER_NAME ($SERVER_IP)"
hcloud server describe "$SERVER_NAME" -o 'format={{.Status}}  {{.ServerType.Name}}  {{.Location.Name}}'

echo
log "Containers"
remote "cd '$REMOTE_DIR' && docker compose ps"

echo
log "Disk and memory"
remote "df -h / | tail -n 1 && free -h | sed -n '2p'"

echo
log "TLS certificate"
remote "ls -l '$REMOTE_DIR/mosquitto/certs' 2>/dev/null || echo 'no certificate synced yet'"

echo
log "Grafana health"
if [ -n "$DOMAIN" ]; then
	remote "curl -fsS --max-time 10 https://$DOMAIN/api/health || echo 'unreachable over HTTPS'"
else
	warn "domain not set in config.yaml, skipping"
fi

echo
echo
log "Most recent measurement in InfluxDB bucket '$BUCKET'"
remote_root "cd '$REMOTE_DIR' && docker compose exec -T influxdb influx query --raw '
from(bucket: \"$BUCKET\")
  |> range(start: -1h)
  |> filter(fn: (r) => r._measurement == \"victron_vedirect\")
  |> last()
  |> keep(columns: [\"_time\", \"device_id\", \"_field\", \"_value\"])
' 2>/dev/null || echo 'No data in the last hour (or InfluxDB is not ready).'"

echo
log "Certificate sync timer"
remote "systemctl list-timers mqtt-cert-sync.timer --no-pager 2>/dev/null | head -n 3 || true"
