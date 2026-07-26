#!/usr/bin/env bash
# One-command provisioning from a DDNS hostname.
#
# Example:
#   HCLOUD_TOKEN=xxx ./provision/10-auto-setup.sh --dyndns-host myhome.duckdns.org
#
# Optional credential overrides:
#   --mqtt-username alice --mqtt-password secret
#   --grafana-username admin --grafana-password secret
#
# Optional DDNS update callback (provider URL with placeholders):
#   --dyndns-update-url 'https://example/api/update?hostname={domain}&myip={ip}&token=...'
#
# Optional Google Cloud DNS mode:
#   --google-dns-project my-project --google-dns-zone my-zone
#   --google-dns-record monitor.example.com --google-dns-ttl 60
#   --google-dns-token '<oauth-token>'

set -euo pipefail

. "$(dirname "$0")/lib.sh"

usage() {
	cat <<EOF
Usage:
  $0 --dyndns-host <hostname> [options]

Required:
  --dyndns-host <hostname>       Public hostname used for HTTPS and MQTT TLS.

Options:
	--hcloud-token <token>         Hetzner API token (or set HCLOUD_TOKEN env var).
  --acme-email <email>           Let's Encrypt email (defaults to admin@<dyndns-host>). 
  --mqtt-username <name>
  --mqtt-password <password>
  --grafana-username <name>
  --grafana-password <password>
  --dyndns-update-url <url>      Provider update URL; supports {ip} and {domain} placeholders.
	--google-dns-project <id>      Google Cloud project id.
	--google-dns-zone <name>       Google Cloud DNS managed zone name.
	--google-dns-record <fqdn>     A record to update (defaults to --dyndns-host).
	--google-dns-ttl <seconds>     Record TTL (default 60).
	--google-dns-token <token>     OAuth2 access token for this run only (not stored in config).

Flow:
  1) Initialize config.yaml if missing
  2) Write provided values into config.yaml
  3) Run init, create-server, deploy-stack
EOF
}

DYNDNS_HOST=""
HCLOUD_TOKEN_ARG=""
ACME_EMAIL_ARG=""
MQTT_USERNAME_ARG=""
MQTT_PASSWORD_ARG=""
GRAFANA_USERNAME_ARG=""
GRAFANA_PASSWORD_ARG=""
DYNDNS_UPDATE_URL_ARG=""
GOOGLE_DNS_PROJECT_ARG=""
GOOGLE_DNS_ZONE_ARG=""
GOOGLE_DNS_RECORD_ARG=""
GOOGLE_DNS_TTL_ARG=""
GOOGLE_DNS_TOKEN_ARG=""
ENV_HCLOUD_TOKEN="${HCLOUD_TOKEN:-}"
ENV_GOOGLE_DNS_TOKEN="${GOOGLE_DNS_TOKEN:-}"

while [ "$#" -gt 0 ]; do
	case "$1" in
		--dyndns-host)
			DYNDNS_HOST="${2:-}"; shift 2 ;;
		--hcloud-token)
			HCLOUD_TOKEN_ARG="${2:-}"; shift 2 ;;
		--acme-email)
			ACME_EMAIL_ARG="${2:-}"; shift 2 ;;
		--mqtt-username)
			MQTT_USERNAME_ARG="${2:-}"; shift 2 ;;
		--mqtt-password)
			MQTT_PASSWORD_ARG="${2:-}"; shift 2 ;;
		--grafana-username)
			GRAFANA_USERNAME_ARG="${2:-}"; shift 2 ;;
		--grafana-password)
			GRAFANA_PASSWORD_ARG="${2:-}"; shift 2 ;;
		--dyndns-update-url)
			DYNDNS_UPDATE_URL_ARG="${2:-}"; shift 2 ;;
		--google-dns-project)
			GOOGLE_DNS_PROJECT_ARG="${2:-}"; shift 2 ;;
		--google-dns-zone)
			GOOGLE_DNS_ZONE_ARG="${2:-}"; shift 2 ;;
		--google-dns-record)
			GOOGLE_DNS_RECORD_ARG="${2:-}"; shift 2 ;;
		--google-dns-ttl)
			GOOGLE_DNS_TTL_ARG="${2:-}"; shift 2 ;;
		--google-dns-token)
			GOOGLE_DNS_TOKEN_ARG="${2:-}"; shift 2 ;;
		-h|--help)
			usage; exit 0 ;;
		*)
			die "Unknown argument: $1" ;;
	esac
done

[ -n "$DYNDNS_HOST" ] || die "--dyndns-host is required"

# Ensure config exists.
if [ ! -f "$CONFIG_FILE" ]; then
	bash "$PROVISION_DIR/00-init.sh" >/dev/null
fi

load_config

if [ -n "$HCLOUD_TOKEN_ARG" ]; then
	export HCLOUD_TOKEN="$HCLOUD_TOKEN_ARG"
elif [ -n "$ENV_HCLOUD_TOKEN" ]; then
	export HCLOUD_TOKEN="$ENV_HCLOUD_TOKEN"
fi

cfg_set domain "$DYNDNS_HOST"
cfg_set auto_domain "false"

if [ -n "$ACME_EMAIL_ARG" ]; then
	cfg_set acme_email "$ACME_EMAIL_ARG"
else
	CURRENT_ACME="$(cfg acme_email)"
	if [ -z "$CURRENT_ACME" ]; then
		cfg_set acme_email "admin@${DYNDNS_HOST}"
	fi
fi

if [ -n "$MQTT_USERNAME_ARG" ]; then
	cfg_set mqtt_username "$MQTT_USERNAME_ARG"
fi
if [ -n "$MQTT_PASSWORD_ARG" ]; then
	cfg_set mqtt_password "$MQTT_PASSWORD_ARG"
fi
if [ -n "$GRAFANA_USERNAME_ARG" ]; then
	cfg_set grafana_username "$GRAFANA_USERNAME_ARG"
fi
if [ -n "$GRAFANA_PASSWORD_ARG" ]; then
	cfg_set grafana_password "$GRAFANA_PASSWORD_ARG"
fi
if [ -n "$DYNDNS_UPDATE_URL_ARG" ]; then
	cfg_set dyndns_update_url "$DYNDNS_UPDATE_URL_ARG"
fi

if [ -n "$GOOGLE_DNS_PROJECT_ARG" ] || [ -n "$GOOGLE_DNS_ZONE_ARG" ]; then
	[ -n "$GOOGLE_DNS_PROJECT_ARG" ] || die "--google-dns-project is required when Google DNS mode is enabled"
	[ -n "$GOOGLE_DNS_ZONE_ARG" ] || die "--google-dns-zone is required when Google DNS mode is enabled"
	cfg_set google_dns_enabled "true"
	cfg_set google_dns_project "$GOOGLE_DNS_PROJECT_ARG"
	cfg_set google_dns_zone "$GOOGLE_DNS_ZONE_ARG"
	if [ -n "$GOOGLE_DNS_RECORD_ARG" ]; then
		cfg_set google_dns_record "$GOOGLE_DNS_RECORD_ARG"
	else
		cfg_set google_dns_record "$DYNDNS_HOST"
	fi
	if [ -n "$GOOGLE_DNS_TTL_ARG" ]; then
		cfg_set google_dns_ttl "$GOOGLE_DNS_TTL_ARG"
	fi
	if [ -n "$GOOGLE_DNS_TOKEN_ARG" ]; then
		export GOOGLE_DNS_TOKEN="$GOOGLE_DNS_TOKEN_ARG"
	elif [ -n "$ENV_GOOGLE_DNS_TOKEN" ]; then
		export GOOGLE_DNS_TOKEN="$ENV_GOOGLE_DNS_TOKEN"
	fi
fi

log "Running init"
bash "$PROVISION_DIR/00-init.sh"

log "Creating or reconciling server"
bash "$PROVISION_DIR/01-create-server.sh"

log "Deploying stack"
bash "$PROVISION_DIR/02-deploy-stack.sh"

ok "Automatic setup completed"
