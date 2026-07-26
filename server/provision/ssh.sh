#!/usr/bin/env bash
# Open a shell on the server, or run a single command there.
#
#   ./provision/ssh.sh
#   ./provision/ssh.sh 'cd /opt/tanniere-monitoring && docker compose logs -f telegraf'

. "$(dirname "$0")/lib.sh"

load_config
require_cmd hcloud ssh
require_server_ip

if [ $# -eq 0 ]; then
	# shellcheck disable=SC2046
	exec ssh -t $(ssh_opts) "${DEPLOY_USER}@${SERVER_IP}" "cd '$REMOTE_DIR' && exec bash -l"
fi

# shellcheck disable=SC2046
exec ssh -t $(ssh_opts) "${DEPLOY_USER}@${SERVER_IP}" "$@"
