#!/bin/bash
# Brings the local integration environment up and down.
#
# Everything here is local by construction: ports bind to 127.0.0.1 only, and
# the sshd container carries /etc/hindsight-test-target so the destructive
# operation guard will accept it. No real server is ever involved.

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
compose="$root/testenv/docker-compose.yml"
keys="$root/testenv/.keys"
key="$keys/id_ed25519"

ensure_key() {
  mkdir -p "$keys"
  chmod 700 "$keys"
  if [[ ! -f "$key" ]]; then
    ssh-keygen -q -t ed25519 -N '' -C 'hindsight-testenv' -f "$key"
  fi
  export HINDSIGHT_TEST_PUBKEY="$(cat "$key.pub")"
}

environment_exports() {
  echo "export HINDSIGHT_TEST_SSH_HOST=127.0.0.1"
  echo "export HINDSIGHT_TEST_SSH_PORT=2222"
  echo "export HINDSIGHT_TEST_SSH_KEY=$key"
  echo "export HINDSIGHT_TEST_POSTGRES_PORT=55432"
  echo "export HINDSIGHT_TEST_MYSQL_PORT=53306"
}

case "${1:-up}" in
  up)
    ensure_key
    docker compose -f "$compose" up -d --build --wait
    echo "test environment ready:"
    environment_exports
    ;;
  down)
    ensure_key
    docker compose -f "$compose" down -v --remove-orphans
    ;;
  status)
    ensure_key
    docker compose -f "$compose" ps
    ;;
  env)
    ensure_key
    environment_exports
    ;;
  rotate-host-key)
    # Used by the test that proves a changed host key is a hard failure.
    ensure_key
    docker compose -f "$compose" exec -T sshd sh -c 'rm -f /etc/ssh/ssh_host_* && ssh-keygen -A'
    docker compose -f "$compose" restart sshd
    docker compose -f "$compose" exec -T sshd sh -c 'until ss -ltn | grep -q ":22"; do sleep 0.2; done'
    ;;
  *)
    echo "usage: testenv.sh [up|down|status|env|rotate-host-key]" >&2
    exit 1
    ;;
esac
