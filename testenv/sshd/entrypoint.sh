#!/bin/bash
set -euo pipefail

if [[ -z "${HINDSIGHT_TEST_PUBKEY:-}" ]]; then
  echo "HINDSIGHT_TEST_PUBKEY is not set; run scripts/testenv.sh up" >&2
  exit 1
fi

for home in /root /home/hindsight; do
  install -d -m 700 "$home/.ssh"
  printf '%s\n' "$HINDSIGHT_TEST_PUBKEY" > "$home/.ssh/authorized_keys"
  chmod 600 "$home/.ssh/authorized_keys"
done
chown -R hindsight:hindsight /home/hindsight/.ssh

ssh-keygen -A

exec /usr/sbin/sshd -D -e
