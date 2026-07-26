#!/usr/bin/env bash
# Shared helpers for the provisioning scripts. Sourced, not executed.
#
# All configuration comes from server/config.yaml. server/.env is a generated
# artifact (docker compose needs key=value) and should never be edited by hand.

set -euo pipefail

PROVISION_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVER_DIR="$(cd "$PROVISION_DIR/.." && pwd)"
CONFIG_FILE="$SERVER_DIR/config.yaml"
CONFIG_EXAMPLE="$SERVER_DIR/config.example.yaml"
ENV_FILE="$SERVER_DIR/.env"

if [ -t 1 ]; then
	C_RESET=$'\033[0m'; C_INFO=$'\033[36m'; C_OK=$'\033[32m'; C_WARN=$'\033[33m'; C_ERR=$'\033[31m'
else
	C_RESET=""; C_INFO=""; C_OK=""; C_WARN=""; C_ERR=""
fi

log()  { printf '%s==>%s %s\n' "$C_INFO" "$C_RESET" "$*"; }
ok()   { printf '%s  ok%s %s\n' "$C_OK" "$C_RESET" "$*"; }
warn() { printf '%s warn%s %s\n' "$C_WARN" "$C_RESET" "$*" >&2; }
die()  { printf '%serror%s %s\n' "$C_ERR" "$C_RESET" "$*" >&2; exit 1; }

require_cmd() {
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
	done
}

# ---------------------------------------------------------------- config.yaml ---

# Read one flat `key: value` pair. Inline comments are NOT stripped, so that a
# password containing '#' survives; keep comments on their own lines.
cfg() {
	local key="$1" value
	value="$(sed -n "s/^${key}:[[:space:]]*//p" "$CONFIG_FILE" 2>/dev/null | head -n 1 | tr -d '\r')"
	# Strip matching surrounding quotes and trailing whitespace.
	value="${value%"${value##*[![:space:]]}"}"
	case "$value" in
		'"'*'"') value="${value#\"}"; value="${value%\"}" ;;
		"'"*"'") value="${value#\'}"; value="${value%\'}" ;;
	esac
	printf '%s' "$value"
}

# Replace one key's value in config.yaml, preserving comments and order.
cfg_set() {
	local key="$1" value="$2" tmp
	grep -q "^${key}:" "$CONFIG_FILE" || die "Key '$key' is missing from $CONFIG_FILE. Compare it against config.example.yaml."
	tmp="${CONFIG_FILE}.tmp"
	awk -v key="$key" -v val="$value" '
		!done && index($0, key ":") == 1 { printf "%s: \"%s\"\n", key, val; done = 1; next }
		{ print }
	' "$CONFIG_FILE" >"$tmp"
	mv "$tmp" "$CONFIG_FILE"
}

expand_tilde() {
	case "$1" in
		"~/"*) printf '%s' "$HOME/${1#\~/}" ;;
		*)     printf '%s' "$1" ;;
	esac
}

is_true() {
	case "$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')" in
		1 | true | yes | on) return 0 ;;
		*) return 1 ;;
	esac
}

load_config() {
	if [ ! -f "$CONFIG_FILE" ]; then
		die "No $CONFIG_FILE yet. Create it with:
       cp server/config.example.yaml server/config.yaml
     then fill in hcloud_token, domain and acme_email."
	fi

	EXTERNAL_HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"
	EXTERNAL_GOOGLE_DNS_TOKEN="${GOOGLE_DNS_TOKEN:-}"

	HCLOUD_TOKEN="$(cfg hcloud_token)"
	if [ -z "$HCLOUD_TOKEN" ] && [ -n "$EXTERNAL_HCLOUD_TOKEN" ]; then
		HCLOUD_TOKEN="$EXTERNAL_HCLOUD_TOKEN"
	fi
	SERVER_NAME="$(cfg server_name)";         : "${SERVER_NAME:=tanniere-monitoring}"
	SERVER_TYPE="$(cfg server_type)";         : "${SERVER_TYPE:=cx22}"
	SERVER_IMAGE="$(cfg server_image)";       : "${SERVER_IMAGE:=ubuntu-24.04}"
	SERVER_LOCATION="$(cfg server_location)"; : "${SERVER_LOCATION:=nbg1}"
	ENABLE_BACKUPS="$(cfg enable_backups)"

	SSH_KEY_PATH="$(expand_tilde "$(cfg ssh_key_path)")"
	: "${SSH_KEY_PATH:=$HOME/.ssh/id_ed25519}"
	SSH_KEY_NAME="$(cfg ssh_key_name)";       : "${SSH_KEY_NAME:=${SERVER_NAME}-key}"
	DEPLOY_USER="$(cfg deploy_user)";         : "${DEPLOY_USER:=deploy}"
	REMOTE_DIR="$(cfg remote_dir)";           : "${REMOTE_DIR:=/opt/tanniere-monitoring}"
	SSH_ALLOWED_IPS="$(cfg ssh_allowed_ips)";   : "${SSH_ALLOWED_IPS:=0.0.0.0/0,::/0}"
	MQTT_ALLOWED_IPS="$(cfg mqtt_allowed_ips)"; : "${MQTT_ALLOWED_IPS:=0.0.0.0/0,::/0}"

	DOMAIN="$(cfg domain)"
	AUTO_DOMAIN="$(cfg auto_domain)"; : "${AUTO_DOMAIN:=false}"
	AUTO_DOMAIN_SUFFIX="$(cfg auto_domain_suffix)"; : "${AUTO_DOMAIN_SUFFIX:=sslip.io}"
	DYNDNS_UPDATE_URL="$(cfg dyndns_update_url)"
	GOOGLE_DNS_ENABLED="$(cfg google_dns_enabled)"; : "${GOOGLE_DNS_ENABLED:=false}"
	GOOGLE_DNS_PROJECT="$(cfg google_dns_project)"
	GOOGLE_DNS_ZONE="$(cfg google_dns_zone)"
	GOOGLE_DNS_RECORD="$(cfg google_dns_record)"
	GOOGLE_DNS_TTL="$(cfg google_dns_ttl)"; : "${GOOGLE_DNS_TTL:=60}"
	GOOGLE_DNS_TOKEN="$(cfg google_dns_token)"
	if [ -z "$GOOGLE_DNS_TOKEN" ] && [ -n "$EXTERNAL_GOOGLE_DNS_TOKEN" ]; then
		GOOGLE_DNS_TOKEN="$EXTERNAL_GOOGLE_DNS_TOKEN"
	fi
	ACME_EMAIL="$(cfg acme_email)"
	if [ -z "$ACME_EMAIL" ] && [ -n "$DOMAIN" ]; then
		# LetsEncrypt email is optional; default to a predictable contact when omitted.
		ACME_EMAIL="admin@${DOMAIN}"
	fi
	TIMEZONE="$(cfg timezone)";               : "${TIMEZONE:=UTC}"

	MQTT_USERNAME="$(cfg mqtt_username)";     : "${MQTT_USERNAME:=victron}"
	MQTT_PASSWORD="$(cfg mqtt_password)"

	INFLUXDB_USERNAME="$(cfg influxdb_username)"; : "${INFLUXDB_USERNAME:=admin}"
	INFLUXDB_PASSWORD="$(cfg influxdb_password)"
	INFLUXDB_ORG="$(cfg influxdb_org)";       : "${INFLUXDB_ORG:=tanniere}"
	INFLUXDB_BUCKET="$(cfg influxdb_bucket)"; : "${INFLUXDB_BUCKET:=victron}"
	INFLUXDB_RETENTION="$(cfg influxdb_retention)"; : "${INFLUXDB_RETENTION:=0}"
	INFLUXDB_ADMIN_TOKEN="$(cfg influxdb_admin_token)"

	GRAFANA_USERNAME="$(cfg grafana_username)"; : "${GRAFANA_USERNAME:=admin}"
	GRAFANA_PASSWORD="$(cfg grafana_password)"

	FIREWALL_NAME="${SERVER_NAME}-fw"

	# hcloud picks the token up from the environment.
	export HCLOUD_TOKEN
}

# Fail early on the values only a human can supply.
validate_config() {
	[ -n "$HCLOUD_TOKEN" ] || die "No Hetzner token configured. Set hcloud_token in $CONFIG_FILE or export HCLOUD_TOKEN in your shell."

	if [ -z "$DOMAIN" ] && ! is_true "$AUTO_DOMAIN"; then
		die "domain is empty in $CONFIG_FILE. Set domain, or set auto_domain: true to use <server-ip>.sslip.io automatically."
	fi
	if is_true "$GOOGLE_DNS_ENABLED" && [ -z "$DOMAIN" ]; then
		die "google_dns_enabled is true but domain is empty. Set domain to your DDNS host."
	fi
	if is_true "$GOOGLE_DNS_ENABLED" && is_true "$AUTO_DOMAIN"; then
		die "google_dns_enabled and auto_domain cannot both be true. Google DNS mode expects an explicit domain."
	fi

	if [ -n "$DOMAIN" ]; then
		case "$DOMAIN" in
			*example.com | *example.org | \<*)
				die "domain is still the placeholder '$DOMAIN'. Use a hostname you control." ;;
		esac
		case "$DOMAIN" in
			*.*) ;;
			*) die "domain '$DOMAIN' is not a fully qualified hostname." ;;
		esac
	fi
	if [ -n "$ACME_EMAIL" ]; then
		case "$ACME_EMAIL" in
			*@*.*) ;;
			*) die "acme_email '$ACME_EMAIL' does not look like an email address." ;;
		esac
	fi

	if is_true "$GOOGLE_DNS_ENABLED"; then
		[ -n "$GOOGLE_DNS_PROJECT" ] || die "google_dns_project is required when google_dns_enabled is true."
		[ -n "$GOOGLE_DNS_ZONE" ] || die "google_dns_zone is required when google_dns_enabled is true."
		if [ -z "$GOOGLE_DNS_RECORD" ]; then
			GOOGLE_DNS_RECORD="$DOMAIN"
		fi
		case "$GOOGLE_DNS_TTL" in
			''|*[!0-9]*) die "google_dns_ttl must be an integer number of seconds." ;;
		esac
	fi
}

gen_secret() {
	local len="${1:-32}"
	if command -v openssl >/dev/null 2>&1; then
		openssl rand -base64 $((len * 2)) | tr -dc 'A-Za-z0-9' | head -c "$len"
	else
		LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom | head -c "$len"
	fi
}

# Fill in any blank secret and persist it back to config.yaml.
ensure_secrets() {
	local generated=0

	if [ -z "$MQTT_PASSWORD" ]; then
		MQTT_PASSWORD="$(gen_secret 32)"; cfg_set mqtt_password "$MQTT_PASSWORD"; generated=1
	fi
	if [ -z "$INFLUXDB_PASSWORD" ]; then
		INFLUXDB_PASSWORD="$(gen_secret 24)"; cfg_set influxdb_password "$INFLUXDB_PASSWORD"; generated=1
	fi
	if [ -z "$INFLUXDB_ADMIN_TOKEN" ]; then
		INFLUXDB_ADMIN_TOKEN="$(gen_secret 64)"; cfg_set influxdb_admin_token "$INFLUXDB_ADMIN_TOKEN"; generated=1
	fi
	if [ -z "$GRAFANA_PASSWORD" ]; then
		GRAFANA_PASSWORD="$(gen_secret 24)"; cfg_set grafana_password "$GRAFANA_PASSWORD"; generated=1
	fi

	if [ "$generated" -eq 1 ]; then
		chmod 600 "$CONFIG_FILE" 2>/dev/null || true
		ok "Generated the missing secrets and saved them to config.yaml"
	fi
}

# Project config.yaml into the .env file docker compose consumes.
render_env() {
	cat >"$ENV_FILE" <<EOF
# GENERATED from config.yaml by the provisioning scripts. Do not edit.
# Change config.yaml and re-run ./provision/02-deploy-stack.sh instead.

TZ=${TIMEZONE}

DOMAIN=${DOMAIN}
ACME_EMAIL=${ACME_EMAIL}

MQTT_USERNAME=${MQTT_USERNAME}
MQTT_PASSWORD=${MQTT_PASSWORD}

INFLUXDB_INIT_USERNAME=${INFLUXDB_USERNAME}
INFLUXDB_INIT_PASSWORD=${INFLUXDB_PASSWORD}
INFLUXDB_INIT_ORG=${INFLUXDB_ORG}
INFLUXDB_INIT_BUCKET=${INFLUXDB_BUCKET}
INFLUXDB_INIT_RETENTION=${INFLUXDB_RETENTION}
INFLUXDB_INIT_ADMIN_TOKEN=${INFLUXDB_ADMIN_TOKEN}

GRAFANA_ADMIN_USER=${GRAFANA_USERNAME}
GRAFANA_ADMIN_PASSWORD=${GRAFANA_PASSWORD}
EOF
	chmod 600 "$ENV_FILE" 2>/dev/null || true
}

# ---------------------------------------------------------------------- hcloud ---

server_exists() {
	hcloud server describe "$SERVER_NAME" >/dev/null 2>&1
}

server_ip() {
	hcloud server ip "$SERVER_NAME" 2>/dev/null | tr -d '\r\n'
}

require_server_ip() {
	server_exists || die "Server '$SERVER_NAME' does not exist. Run provision/01-create-server.sh first."
	SERVER_IP="$(server_ip)"
	[ -n "$SERVER_IP" ] || die "Could not determine the public IPv4 of '$SERVER_NAME'."
}

# Turn "1.2.3.4/32, ::/0" into a JSON array.
ips_to_json() {
	local raw="$1" out="" ip
	local IFS=','
	for ip in $raw; do
		ip="$(printf '%s' "$ip" | tr -d '[:space:]')"
		[ -n "$ip" ] || continue
		out="${out}\"${ip}\","
	done
	[ -n "$out" ] || die "Empty IP list where at least one CIDR is required."
	printf '[%s]' "${out%,}"
}

# ------------------------------------------------------------------------- ssh ---

ssh_opts() {
	printf '%s' "-o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o ServerAliveInterval=15 -i $SSH_KEY_PATH"
}

# Run a command on the server as the deploy user.
remote() {
	# shellcheck disable=SC2046
	ssh $(ssh_opts) "${DEPLOY_USER}@${SERVER_IP}" "$@"
}

# Run a command on the server as root, via passwordless sudo.
remote_root() {
	# shellcheck disable=SC2046
	ssh $(ssh_opts) "${DEPLOY_USER}@${SERVER_IP}" "sudo -n bash -c $(printf '%q' "$*")"
}

wait_for_ssh() {
	local attempts="${1:-60}" i
	log "Waiting for SSH on ${SERVER_IP} (up to $((attempts * 5))s)"
	for i in $(seq 1 "$attempts"); do
		if remote true >/dev/null 2>&1; then
			ok "SSH is up"
			return 0
		fi
		sleep 5
	done
	die "SSH did not become available. Check the Hetzner console for '$SERVER_NAME'."
}

wait_for_cloud_init() {
	log "Waiting for cloud-init to finish (first boot installs Docker, a few minutes)"
	if remote "cloud-init status --wait" >/dev/null 2>&1; then
		ok "cloud-init finished"
	else
		warn "cloud-init reported a non-zero status. Inspect /var/log/cloud-init-output.log on the server."
	fi
}

confirm() {
	local prompt="$1" answer
	read -r -p "$prompt " answer
	[ "$answer" = "yes" ]
}
