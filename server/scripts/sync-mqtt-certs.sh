#!/usr/bin/env bash
# Copy the certificate Caddy obtained for $DOMAIN into a location Mosquitto can
# read, and reload Mosquitto when it changed. Runs on the server as root, both
# from server-bootstrap.sh and from the mqtt-cert-sync.timer.
#
# Exit codes: 0 = certificate present (copied or already current), 1 = not yet
# issued. The bootstrap script polls on that distinction.

set -euo pipefail

DIR="${REMOTE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$DIR"

QUIET=false
[ "${1:-}" = "--quiet" ] && QUIET=true
say() { [ "$QUIET" = true ] || printf '%s\n' "$*"; }

# shellcheck disable=SC1091
. ./.env
: "${DOMAIN:?DOMAIN must be set in .env}"

CERT_DIR="data/caddy-data/caddy/certificates"
DEST="mosquitto/certs"

# The issuer directory name varies (Let's Encrypt vs ZeroSSL fallback), so search.
CERT_SRC="$(find "$CERT_DIR" -type f -name "${DOMAIN}.crt" 2>/dev/null | head -n 1 || true)"
if [ -z "$CERT_SRC" ]; then
	say "No certificate for ${DOMAIN} under ${CERT_DIR} yet."
	exit 1
fi
KEY_SRC="${CERT_SRC%.crt}.key"
[ -f "$KEY_SRC" ] || { say "Certificate found but private key is missing: $KEY_SRC"; exit 1; }

mkdir -p "$DEST"

changed=false
cmp -s "$CERT_SRC" "$DEST/server.crt" || changed=true
cmp -s "$KEY_SRC" "$DEST/server.key" || changed=true

if [ "$changed" = false ]; then
	say "Certificate for ${DOMAIN} is already current."
	exit 0
fi

install -m 0644 "$CERT_SRC" "$DEST/server.crt"
install -m 0600 "$KEY_SRC" "$DEST/server.key"
# uid/gid 1883 is the mosquitto user inside the eclipse-mosquitto image.
chown 1883:1883 "$DEST/server.crt" "$DEST/server.key"
say "Installed certificate for ${DOMAIN} into ${DEST}."

if [ -n "$(docker compose ps -q mosquitto 2>/dev/null || true)" ]; then
	say "Restarting Mosquitto to load the new certificate."
	docker compose restart mosquitto
fi
