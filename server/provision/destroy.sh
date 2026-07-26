#!/usr/bin/env bash
# Delete the server and its firewall. This destroys all stored measurements.

. "$(dirname "$0")/lib.sh"

load_config
require_cmd hcloud

if ! server_exists; then
	warn "Server '$SERVER_NAME' does not exist."
else
	SERVER_IP="$(server_ip)"
	cat <<EOF
About to permanently delete:

  server    $SERVER_NAME ($SERVER_IP)
  firewall  $FIREWALL_NAME

All InfluxDB measurements and Grafana settings on it are lost. Hetzner
snapshots and backups, if any, are NOT deleted by this script.
EOF
	confirm "Type 'yes' to continue:" || die "Aborted."

	log "Deleting server"
	hcloud server delete "$SERVER_NAME"
	ok "Server deleted"
fi

if hcloud firewall describe "$FIREWALL_NAME" >/dev/null 2>&1; then
	log "Deleting firewall"
	hcloud firewall delete "$FIREWALL_NAME" || warn "Could not delete '$FIREWALL_NAME' (still attached to something?)"
fi

ok "Done. The SSH key '$SSH_KEY_NAME' was left in the project."
