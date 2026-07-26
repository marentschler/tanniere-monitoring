# tanniere-monitoring

End-to-end Victron VE.Direct monitoring stack with MQTT transport, InfluxDB storage, and Grafana dashboards.

Project layout:

- `client/`: Edge service that reads VE.Direct serial data and publishes it to MQTT.
- `server/`: Cloud/server stack (MQTT broker + Telegraf + InfluxDB + Grafana).

Set the server up first — it generates the MQTT credentials the client needs.

## 1) Server setup (Hetzner, script driven)

From `server/`:

```bash
./provision/00-init.sh            # creates config.yaml
${EDITOR:-notepad} config.yaml    # fill in hcloud_token, domain, acme_email
./provision/00-init.sh            # validate, generate every secret
./provision/01-create-server.sh   # create and harden the VPS
# point a DNS A record at the printed IP, then:
./provision/02-deploy-stack.sh    # deploy the stack
```

`server/config.yaml` is the single place anything is configured — server size,
firewall sources, domain, and every credential. Passwords left blank are
generated for you.

Grafana then lives at `https://<your-domain>` over HTTPS, and MQTT accepts TLS
connections on port 8883. See [server/README.md](server/README.md) for the
security model, day-to-day commands, and certificate handling.

## 2) Client setup (VE.Direct -> MQTT)

1. Go to `client/`.
2. Copy `.env.example` to `.env`. Use the MQTT host, username and password that
   `00-init.sh` printed, with `MQTT_PORT=8883` and `MQTT_TLS=true`.
3. Install dependencies:

	```bash
	pip install -r requirements.txt
	```

4. Start bridge:

	```bash
	python src/vedirect_mqtt_bridge.py
	```

## Data flow

`Victron VE.Direct device -> client bridge -> MQTT topic victron/vedirect/<device_id> (TLS) -> Telegraf -> InfluxDB -> Grafana`

`Victron SmartShunt -> Bluetooth -> client bridge -> MQTT topic victron/smartshunt/<device_id> (TLS) -> Telegraf -> InfluxDB -> Grafana`

The SmartShunt is the only Bluetooth device read. Its advertisements are decoded
on the Pi by `victron-ble`, so only decoded telemetry crosses the link.
