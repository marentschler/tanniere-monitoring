#!/usr/bin/env bash
# Create (or adopt) the Hetzner server and its cloud firewall, then wait until
# the first-boot bootstrap has finished. Safe to re-run: existing resources are
# reused and firewall rules are reconciled to match config.yaml.

. "$(dirname "$0")/lib.sh"

load_config
validate_config
require_cmd hcloud ssh sed

PUBKEY_PATH="${SSH_KEY_PATH}.pub"
[ -f "$SSH_KEY_PATH" ] || die "SSH private key not found: $SSH_KEY_PATH (create one with: ssh-keygen -t ed25519)"
[ -f "$PUBKEY_PATH" ]  || die "SSH public key not found: $PUBKEY_PATH"

# The stack needs .env on the server, so make sure secrets exist before deploying.
ensure_secrets
render_env

# ---------------------------------------------------------------- ssh key ----
if hcloud ssh-key describe "$SSH_KEY_NAME" >/dev/null 2>&1; then
	ok "SSH key '$SSH_KEY_NAME' already registered in the Hetzner project"
else
	log "Uploading SSH key '$SSH_KEY_NAME'"
  PUBKEY_CONTENT="$(tr -d '\r\n' <"$PUBKEY_PATH")"
  hcloud ssh-key create --name "$SSH_KEY_NAME" --public-key "$PUBKEY_CONTENT"
	ok "SSH key uploaded"
fi

# ---------------------------------------------------------------- firewall ----
RULES_FILE="$(mktemp)"
USER_DATA="$(mktemp)"
trap 'rm -f "$RULES_FILE" "$USER_DATA"' EXIT

cat >"$RULES_FILE" <<EOF
[
  {
    "description": "SSH",
    "direction": "in",
    "protocol": "tcp",
    "port": "22",
    "source_ips": $(ips_to_json "$SSH_ALLOWED_IPS")
  },
  {
    "description": "HTTP (ACME challenge + redirect to HTTPS)",
    "direction": "in",
    "protocol": "tcp",
    "port": "80",
    "source_ips": ["0.0.0.0/0", "::/0"]
  },
  {
    "description": "HTTPS (Grafana via Caddy)",
    "direction": "in",
    "protocol": "tcp",
    "port": "443",
    "source_ips": ["0.0.0.0/0", "::/0"]
  },
  {
    "description": "HTTP/3 (Grafana via Caddy)",
    "direction": "in",
    "protocol": "udp",
    "port": "443",
    "source_ips": ["0.0.0.0/0", "::/0"]
  },
  {
    "description": "MQTT over TLS",
    "direction": "in",
    "protocol": "tcp",
    "port": "8883",
    "source_ips": $(ips_to_json "$MQTT_ALLOWED_IPS")
  },
  {
    "description": "ICMP",
    "direction": "in",
    "protocol": "icmp",
    "source_ips": ["0.0.0.0/0", "::/0"]
  }
]
EOF

if hcloud firewall describe "$FIREWALL_NAME" >/dev/null 2>&1; then
	log "Reconciling firewall '$FIREWALL_NAME'"
else
	log "Creating firewall '$FIREWALL_NAME'"
	hcloud firewall create --name "$FIREWALL_NAME" --label "project=tanniere-monitoring"
fi
hcloud firewall replace-rules "$FIREWALL_NAME" --rules-file "$RULES_FILE"
ok "Firewall applied (SSH from: $SSH_ALLOWED_IPS | MQTT from: $MQTT_ALLOWED_IPS)"

# ------------------------------------------------------------------ server ----
if server_exists; then
	ok "Server '$SERVER_NAME' already exists, skipping creation"
	hcloud firewall apply-to-resource "$FIREWALL_NAME" \
		--type server --server "$SERVER_NAME" >/dev/null 2>&1 || true
else
	PUBKEY="$(tr -d '\r\n' <"$PUBKEY_PATH")"

	sed -e "s|__HOSTNAME__|${SERVER_NAME}|g" \
		-e "s|__TIMEZONE__|${TIMEZONE}|g" \
		-e "s|__DEPLOY_USER__|${DEPLOY_USER}|g" \
		-e "s|__REMOTE_DIR__|${REMOTE_DIR}|g" \
		-e "s|__SSH_PUBKEY__|${PUBKEY}|g" \
		"$PROVISION_DIR/cloud-init.yaml" >"$USER_DATA"

	BACKUP_FLAG=()
	is_true "$ENABLE_BACKUPS" && BACKUP_FLAG=(--enable-backup)

	log "Creating server '$SERVER_NAME' ($SERVER_TYPE, $SERVER_IMAGE, $SERVER_LOCATION)"
	hcloud server create \
		--name "$SERVER_NAME" \
		--type "$SERVER_TYPE" \
		--image "$SERVER_IMAGE" \
		--location "$SERVER_LOCATION" \
		--ssh-key "$SSH_KEY_NAME" \
		--firewall "$FIREWALL_NAME" \
		--user-data-from-file "$USER_DATA" \
		--label "project=tanniere-monitoring" \
		${BACKUP_FLAG[@]+"${BACKUP_FLAG[@]}"}
	ok "Server created"
fi

require_server_ip
wait_for_ssh
wait_for_cloud_init

DOMAIN_WAS_EMPTY=0
if [ -z "$DOMAIN" ] && is_true "$AUTO_DOMAIN"; then
  DOMAIN_WAS_EMPTY=1
  AUTO_SUFFIX="${AUTO_DOMAIN_SUFFIX#.}"
  AUTO_SUFFIX="${AUTO_SUFFIX%.}"
  [ -n "$AUTO_SUFFIX" ] || die "auto_domain_suffix is empty in $CONFIG_FILE"
  DOMAIN="${SERVER_IP}.${AUTO_SUFFIX}"
  cfg_set domain "$DOMAIN"
  ok "Auto-generated domain '$DOMAIN' and saved it to config.yaml"
fi

if is_true "$GOOGLE_DNS_ENABLED"; then
  RECORD_NAME="$GOOGLE_DNS_RECORD"
  [ -n "$RECORD_NAME" ] || RECORD_NAME="$DOMAIN"
  log "Updating Google Cloud DNS record '$RECORD_NAME'"
  GOOGLE_TOKEN_ARGS=()
  if [ -n "$GOOGLE_DNS_TOKEN" ]; then
    GOOGLE_TOKEN_ARGS=(--token "$GOOGLE_DNS_TOKEN")
  fi
  bash "$PROVISION_DIR/google-dns-update.sh" \
    --project "$GOOGLE_DNS_PROJECT" \
    --zone "$GOOGLE_DNS_ZONE" \
    --record "$RECORD_NAME" \
    --ip "$SERVER_IP" \
    --ttl "$GOOGLE_DNS_TTL" \
    ${GOOGLE_TOKEN_ARGS[@]+"${GOOGLE_TOKEN_ARGS[@]}"}
  if [ "$RECORD_NAME" != "$GOOGLE_DNS_RECORD" ]; then
    cfg_set google_dns_record "$RECORD_NAME"
  fi
  ok "Google Cloud DNS record updated"
fi

if [ -n "$DYNDNS_UPDATE_URL" ]; then
  require_cmd curl
  UPDATE_URL="${DYNDNS_UPDATE_URL//\{ip\}/$SERVER_IP}"
  UPDATE_URL="${UPDATE_URL//\{domain\}/$DOMAIN}"
  log "Updating DDNS record via configured update URL"
  if curl -fsS --max-time 20 "$UPDATE_URL" >/dev/null; then
    ok "DDNS update request succeeded"
  else
    warn "DDNS update request failed. Check dyndns_update_url in config.yaml."
  fi
fi

if [ -z "$ACME_EMAIL" ] && [ -n "$DOMAIN" ]; then
  ACME_EMAIL="admin@${DOMAIN}"
  cfg_set acme_email "$ACME_EMAIL"
  ok "acme_email was empty; defaulted to '$ACME_EMAIL'"
fi

render_env

echo
ok "Server '$SERVER_NAME' is ready at ${SERVER_IP}"
if [ "$DOMAIN_WAS_EMPTY" -eq 1 ]; then
cat <<EOF

Next steps
  1. Deploy the stack (no manual DNS step needed):

       ./provision/02-deploy-stack.sh

  Auto-generated domain:
       ${DOMAIN}

  Shell access: ./provision/ssh.sh
EOF
else
cat <<EOF

Next steps
  1. Point DNS at the server:

       ${DOMAIN}.  A  ${SERVER_IP}

     Verify with: nslookup ${DOMAIN}

  2. Deploy the stack:

       ./provision/02-deploy-stack.sh

  Shell access: ./provision/ssh.sh
EOF
fi
