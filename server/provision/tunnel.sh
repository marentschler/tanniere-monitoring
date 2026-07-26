#!/usr/bin/env bash
# Forward the admin ports that are deliberately not exposed publicly.
# Leave this running, then use the URLs below.
#
#   http://localhost:8086  InfluxDB UI  (admin credentials from server/.env)
#   http://localhost:3001  Grafana, bypassing Caddy (useful if TLS is broken)

. "$(dirname "$0")/lib.sh"

load_config
require_cmd hcloud ssh
require_server_ip

cat <<EOF
Tunnels open while this stays running:

  InfluxDB UI   http://localhost:8086
  Grafana raw   http://localhost:3001

Press Ctrl-C to close.
EOF

# shellcheck disable=SC2046
exec ssh -N $(ssh_opts) \
	-L 8086:127.0.0.1:8086 \
	-L 3001:127.0.0.1:3000 \
	"${DEPLOY_USER}@${SERVER_IP}"
