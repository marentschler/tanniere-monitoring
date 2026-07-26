#!/usr/bin/env bash
# Update one Google Cloud DNS A record to the supplied IPv4.
#
# Required args:
#   --project <gcp-project-id>
#   --zone <managed-zone-name>
#   --record <fqdn>
#   --ip <ipv4>
#
# Optional args:
#   --ttl <seconds>      (default: 60)
#   --token <oauth2 token>
#
# If --token is omitted, the script tries GOOGLE_DNS_TOKEN, then
# `gcloud auth print-access-token`.

set -euo pipefail

PROJECT=""
ZONE=""
RECORD=""
IPV4=""
TTL="60"
TOKEN=""

die() { printf 'error %s\n' "$*" >&2; exit 1; }
log() { printf '==> %s\n' "$*"; }
ok() { printf '  ok %s\n' "$*"; }

require_cmd() {
	for cmd in "$@"; do
		command -v "$cmd" >/dev/null 2>&1 || die "Required command not found: $cmd"
	done
}

while [ "$#" -gt 0 ]; do
	case "$1" in
		--project) PROJECT="${2:-}"; shift 2 ;;
		--zone) ZONE="${2:-}"; shift 2 ;;
		--record) RECORD="${2:-}"; shift 2 ;;
		--ip) IPV4="${2:-}"; shift 2 ;;
		--ttl) TTL="${2:-}"; shift 2 ;;
		--token) TOKEN="${2:-}"; shift 2 ;;
		*) die "Unknown argument: $1" ;;
	esac
done

[ -n "$PROJECT" ] || die "--project is required"
[ -n "$ZONE" ] || die "--zone is required"
[ -n "$RECORD" ] || die "--record is required"
[ -n "$IPV4" ] || die "--ip is required"
case "$TTL" in ''|*[!0-9]*) die "--ttl must be an integer" ;; esac

require_cmd curl jq

if [ -z "$TOKEN" ] && [ -n "${GOOGLE_DNS_TOKEN:-}" ]; then
	TOKEN="$GOOGLE_DNS_TOKEN"
fi
if [ -z "$TOKEN" ] && command -v gcloud >/dev/null 2>&1; then
	TOKEN="$(gcloud auth print-access-token 2>/dev/null || true)"
fi
[ -n "$TOKEN" ] || die "No Google token found. Use --token, GOOGLE_DNS_TOKEN, or install gcloud and run 'gcloud auth login'."

FQDN="$RECORD"
case "$FQDN" in
	*.) ;;
	*) FQDN="${FQDN}." ;;
esac

BASE_URL="https://dns.googleapis.com/dns/v1/projects/${PROJECT}/managedZones/${ZONE}"

existing_json="$(curl -fsS --get \
	-H "Authorization: Bearer ${TOKEN}" \
	-H 'Accept: application/json' \
	--data-urlencode "name=${FQDN}" \
	--data-urlencode 'type=A' \
	"${BASE_URL}/rrsets" || true)"

if [ -z "$existing_json" ]; then
	existing_json='{"rrsets":[]}'
fi

existing_has_record="$(printf '%s' "$existing_json" | jq -r 'if (.rrsets | length) > 0 then "yes" else "no" end')"
existing_ip="$(printf '%s' "$existing_json" | jq -r '.rrsets[0].rrdatas[0] // empty')"
existing_ttl="$(printf '%s' "$existing_json" | jq -r '.rrsets[0].ttl // empty')"

if [ "$existing_has_record" = "yes" ] && [ "$existing_ip" = "$IPV4" ] && [ "$existing_ttl" = "$TTL" ]; then
	ok "Google DNS record already up to date (${FQDN} -> ${IPV4})"
	exit 0
fi

tmp_body="$(mktemp)"
trap 'rm -f "$tmp_body"' EXIT

if [ "$existing_has_record" = "yes" ]; then
	cat >"$tmp_body" <<EOF
{
  "additions": [
    {
      "name": "${FQDN}",
      "type": "A",
      "ttl": ${TTL},
      "rrdatas": ["${IPV4}"]
    }
  ],
  "deletions": [
    {
      "name": "${FQDN}",
      "type": "A",
      "ttl": ${existing_ttl},
      "rrdatas": ["${existing_ip}"]
    }
  ]
}
EOF
else
	cat >"$tmp_body" <<EOF
{
  "additions": [
    {
      "name": "${FQDN}",
      "type": "A",
      "ttl": ${TTL},
      "rrdatas": ["${IPV4}"]
    }
  ]
}
EOF
fi

log "Updating Google DNS: ${FQDN} -> ${IPV4}"
curl -fsS -X POST \
	-H "Authorization: Bearer ${TOKEN}" \
	-H 'Content-Type: application/json' \
	"${BASE_URL}/changes" \
	-d @"$tmp_body" >/dev/null

ok "Google DNS updated"
