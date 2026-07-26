# Server

Everything needed to stand up the cloud side on a Hetzner VPS:

- Caddy reverse proxy (HTTPS via Let's Encrypt)
- Mosquitto MQTT broker (password auth, TLS on 8883)
- Telegraf MQTT consumer
- InfluxDB 2.x
- Grafana with pre-provisioned datasource and dashboard

Provisioning is script driven end to end, and everything you have to fill in
lives in a single file: [config.example.yaml](config.example.yaml).

## Prerequisites

- The [`hcloud` CLI](https://github.com/hetznercloud/cli/releases) on `PATH`
  (`winget install Hetzner.hcloud`, or `brew install hcloud`)
- A Hetzner Cloud API token with **Read & Write** scope
- An SSH keypair (`ssh-keygen -t ed25519` if you don't have one)
- Either a domain you control, or `auto_domain: true` in `config.yaml`
- Bash. On Windows, run these from Git Bash.

> This repo was set up on Windows, where git does not track the executable bit
> (`core.filemode=false`). On a fresh clone elsewhere, run
> `chmod +x provision/*.sh scripts/*.sh` once, or invoke them as `bash <script>`.

## Setup

Run everything from this `server/` directory.

### One-command setup (DDNS host)

If you already have a DDNS hostname (for example DuckDNS, No-IP, Dynu), you can
run the whole flow in one command:

```bash
HCLOUD_TOKEN=<your-token> \
./provision/10-auto-setup.sh --dyndns-host <your-ddns-host>
```

This supports "auth outside the CLI": export `HCLOUD_TOKEN` (and optionally
`GOOGLE_DNS_TOKEN`) in your shell, and no interactive login is needed.

Optional overrides:

```bash
./provision/10-auto-setup.sh \
  --dyndns-host <your-ddns-host> \
  --mqtt-username victron \
  --mqtt-password '<choose-password>' \
  --grafana-username admin \
  --grafana-password '<choose-password>'
```

Google Cloud DNS mode (auto-update A record after server IP is known):

```bash
HCLOUD_TOKEN=<your-token> GOOGLE_DNS_TOKEN=<oauth-token> \
./provision/10-auto-setup.sh \
  --dyndns-host monitor.example.com \
  --google-dns-project <gcp-project-id> \
  --google-dns-zone <managed-zone-name>
```

If `GOOGLE_DNS_TOKEN` is omitted, the script tries
`gcloud auth print-access-token`.

If your DDNS provider supports an HTTP update URL, add `dyndns_update_url` in
`config.yaml` (with `{ip}` and optional `{domain}` placeholders). The script
invokes it automatically after server creation.

### Step-by-step setup

```bash
# 1. Creates config.yaml from the template.
./provision/00-init.sh

# 2. Fill in the required values: hcloud_token, acme_email,
#    and either domain OR auto_domain: true.
${EDITOR:-notepad} config.yaml

# 3. Validates the config, generates the passwords, prints the credentials.
./provision/00-init.sh

# 4. Create the server, firewall, and harden the OS. Prints the public IP.
./provision/01-create-server.sh

# 5. If you set domain manually: point DNS at that IP.
#    If auto_domain: true, this step is skipped.
./provision/02-deploy-stack.sh
```

When `auto_domain: true` and `domain` is empty, `01-create-server.sh`
auto-generates `<server-ip>.sslip.io`, writes it into `config.yaml`, and no
manual DNS A record is needed.

If you set your own domain, ACME validation only succeeds once its A record
resolves to the server. `02-deploy-stack.sh` warns and continues if DNS isn't
ready; Caddy keeps retrying, and once it has the certificate the
`mqtt-cert-sync` timer hands it to Mosquitto.

## Configuration

`config.yaml` is the only file you edit. It holds the Hetzner token, the server
size and location, firewall sources, and every application secret. Passwords and
tokens left empty are generated on first run and written back into the file, so
you never have to invent one.

`server/.env` is **generated** from `config.yaml` on every deploy — don't edit
it, your changes would be overwritten. `config.yaml` is gitignored and is never
uploaded to the server (it contains the Hetzner API token, which the server has
no use for); only the rendered `.env` is.

After changing anything in `config.yaml`:

```bash
./provision/01-create-server.sh   # only if you changed firewall sources
./provision/02-deploy-stack.sh    # anything else
```

Back `config.yaml` up somewhere safe. The InfluxDB admin token exists nowhere
else.

## Day-to-day

| Command | Purpose |
| --- | --- |
| `./provision/status.sh` | Containers, disk, TLS, and whether data is landing in InfluxDB |
| `./provision/ssh.sh` | Shell in the stack directory on the server |
| `./provision/ssh.sh 'cd /opt/tanniere-monitoring && docker compose logs -f'` | Follow all logs |
| `./provision/tunnel.sh` | Forward the InfluxDB UI to `localhost:8086` |
| `./provision/03-add-mqtt-user.sh <name>` | Add another MQTT user, printing a generated password |
| `./provision/02-deploy-stack.sh` | Redeploy after any config change |
| `./provision/destroy.sh` | Delete the server and firewall |

## Connecting the client

`00-init.sh` prints these values. In `client/.env`:

```bash
MQTT_HOST=<your-domain>
MQTT_PORT=8883
MQTT_TLS=true
MQTT_USERNAME=victron
MQTT_PASSWORD=<mqtt_password from config.yaml>
```

The bridge validates the broker certificate against the system CA store, so no
certificate has to be copied to the client.

## Security model

The public surface is deliberately small:

| Port | Exposure | Notes |
| --- | --- | --- |
| 22 | `ssh_allowed_ips` | Key auth only; root login and passwords disabled; fail2ban active |
| 80 | world | ACME challenge and redirect to HTTPS |
| 443 | world | Grafana behind Caddy |
| 8883 | `mqtt_allowed_ips` | MQTT over TLS, password required |

InfluxDB (8086) and Grafana (3000) are bound to loopback on the server and are
only reachable through `provision/tunnel.sh`. Mosquitto's plaintext 1883
listener is never published — only Telegraf reaches it, over the compose
network.

Narrow `ssh_allowed_ips` and `mqtt_allowed_ips` in `config.yaml` if your
addresses are static; re-running `01-create-server.sh` reconciles the firewall
without touching the server.

One caveat worth knowing: **ufw on the host does not filter Docker-published
ports.** Docker inserts its DNAT rules ahead of ufw's chains, so the Hetzner
cloud firewall — which sits outside the host — is the real gate for 80, 443 and
8883. ufw is there for host-level services such as SSH.

## Certificate handling

Caddy owns the certificate lifecycle. Mosquitto cannot talk ACME, so
[scripts/sync-mqtt-certs.sh](scripts/sync-mqtt-certs.sh) copies the issued cert
and key out of Caddy's data directory into `mosquitto/certs/`, `chown`s them to
uid 1883, and restarts Mosquitto when they change. A systemd timer runs it twice
a day; Caddy renews around 30 days before expiry, so the margin is wide.

To force a sync:

```bash
./provision/ssh.sh 'sudo systemctl start mqtt-cert-sync.service'
```

Mosquitto restart-loops while `mosquitto/certs/` is empty. That is intentional —
it keeps port 8883 from ever serving plaintext — and resolves itself as soon as
Caddy gets the certificate.

## Running the stack by hand

The compose file has no Hetzner dependency, so it also runs locally. You need a
`.env` (run `./provision/00-init.sh`) and a Mosquitto password file:

```bash
docker run --rm -u 0 -v "$PWD/mosquitto:/work" eclipse-mosquitto:2.0 \
  mosquitto_passwd -c -b /work/passwd victron 'some-password'
docker compose up -d
```

Without a certificate in `mosquitto/certs/`, Mosquitto restart-loops — harmless
for local testing, which only uses the internal 1883 listener.

## Layout

```
config.example.yaml        the one file you fill in
Caddyfile                  reverse proxy + TLS config
docker-compose.yml         the stack
provision/                 runs on your machine: create, deploy, operate
  cloud-init.yaml          first-boot OS hardening and Docker install
scripts/                   runs on the server: bootstrap, certs, MQTT users
systemd/                   certificate sync timer
mosquitto/ telegraf/ grafana/    service configs
```

## Data path

`client bridge -> MQTT victron/vedirect/<device_id> (TLS 8883) -> Telegraf -> InfluxDB -> Grafana`
