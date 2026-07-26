#!/usr/bin/env bash
# Add or update an MQTT user on the running server (e.g. a second VE.Direct
# device, or an MQTT Explorer session for debugging).
#
#   ./provision/03-add-mqtt-user.sh smartsolar-02
#   ./provision/03-add-mqtt-user.sh smartsolar-02 'a-password-i-chose'
#   ./provision/03-add-mqtt-user.sh --delete smartsolar-02

. "$(dirname "$0")/lib.sh"

load_config
require_cmd hcloud ssh
require_server_ip

if [ "${1:-}" = "--delete" ]; then
	USERNAME="${2:-}"
	[ -n "$USERNAME" ] || die "usage: $0 --delete <username>"
	remote_root "REMOTE_DIR='$REMOTE_DIR' bash '$REMOTE_DIR/scripts/mqtt-user.sh' --delete '$USERNAME'"
	ok "Deleted MQTT user '$USERNAME'"
	exit 0
fi

USERNAME="${1:-}"
[ -n "$USERNAME" ] || die "usage: $0 <username> [password]"
PASSWORD="${2:-}"

if [ -z "$PASSWORD" ]; then
	PASSWORD="$(gen_secret 32)"
	log "Generated a random password"
fi

remote_root "REMOTE_DIR='$REMOTE_DIR' bash '$REMOTE_DIR/scripts/mqtt-user.sh' '$USERNAME' '$PASSWORD'"

echo
ok "MQTT user ready"
cat <<EOF

  Host      ${DOMAIN}
  Port      8883 (TLS)
  Username  ${USERNAME}
  Password  ${PASSWORD}

This user is not recorded in config.yaml -- save the password now.
EOF
