#!/usr/bin/env bash
# Add or update a Mosquitto user. Runs on the server as root.
#
#   scripts/mqtt-user.sh <username> <password>
#   scripts/mqtt-user.sh --delete <username>
#
# Existing users are preserved. Mosquitto reloads the password file on SIGHUP,
# so changes take effect without dropping other connections.

set -euo pipefail

DIR="${REMOTE_DIR:-$(cd "$(dirname "$0")/.." && pwd)}"
cd "$DIR"

IMAGE="eclipse-mosquitto:2.0"
PASSWD="mosquitto/passwd"

usage() { printf 'usage: %s <username> <password> | --delete <username>\n' "$0" >&2; exit 2; }

mosquitto_passwd_cmd() {
	# -u 0 so the tool can write into the bind-mounted directory.
	docker run --rm -u 0 -v "$DIR/mosquitto:/work" "$IMAGE" mosquitto_passwd "$@"
}

mkdir -p mosquitto

if [ "${1:-}" = "--delete" ]; then
	USERNAME="${2:-}"
	[ -n "$USERNAME" ] || usage
	[ -f "$PASSWD" ] || { echo "No password file at $PASSWD" >&2; exit 1; }
	mosquitto_passwd_cmd -D /work/passwd "$USERNAME"
	echo "Removed MQTT user '$USERNAME'."
else
	USERNAME="${1:-}"
	PASSWORD="${2:-}"
	[ -n "$USERNAME" ] && [ -n "$PASSWORD" ] || usage

	if [ -f "$PASSWD" ]; then
		# -b adds or updates a single user, leaving the rest of the file intact.
		mosquitto_passwd_cmd -b /work/passwd "$USERNAME" "$PASSWORD"
	else
		mosquitto_passwd_cmd -c -b /work/passwd "$USERNAME" "$PASSWORD"
	fi
	echo "Set password for MQTT user '$USERNAME'."
fi

chown 1883:1883 "$PASSWD"
chmod 600 "$PASSWD"

if [ -n "$(docker compose ps -q mosquitto 2>/dev/null || true)" ]; then
	docker compose kill -s HUP mosquitto >/dev/null
	echo "Signalled Mosquitto to reload the password file."
fi
