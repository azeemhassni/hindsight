#!/bin/bash
# Provisions a local Coolify VM for the Coolify tests.
#
# Local by construction: an OrbStack machine on a private address, carrying
# /etc/hindsight-test-target so the destructive operation guard accepts it. No
# real server is ever involved.
#
#   scripts/coolify-testenv.sh up      create the VM and install Coolify
#   scripts/coolify-testenv.sh env     print the environment the tests read
#   scripts/coolify-testenv.sh down    delete the VM

set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
machine="coolify"
key="$root/testenv/.keys/id_ed25519"

vm() { orbctl run -m "$machine" sudo bash -lc "$1"; }

# OrbStack's own SSH endpoint on loopback, rather than the machine's private
# address. The address route drops when OrbStack's machine networking hiccups,
# and 127.0.0.1 is both stable and unambiguously local to the safety guard.
orb_ssh_port() {
  awk '/^Host orb$/ { found = 1 } found && /^[[:space:]]*Port/ { print $2; exit }' \
    "$HOME/.orbstack/ssh/config" 2>/dev/null
}

orb_ssh_key() {
  echo "$HOME/.orbstack/ssh/id_ed25519"
}

case "${1:-up}" in
  up)
    "$root/scripts/testenv.sh" env >/dev/null  # ensures the key pair exists
    if ! orbctl info "$machine" >/dev/null 2>&1; then
      orbctl create ubuntu "$machine"
      sleep 5
    fi

    vm 'touch /etc/hindsight-test-target
        apt-get update -qq >/dev/null 2>&1
        apt-get install -y -qq curl ca-certificates openssh-server jq >/dev/null 2>&1
        systemctl enable --now ssh >/dev/null 2>&1'

    # The tests open many short-lived connections; stock sshd starts refusing
    # them at ten, which looks like a Hindsight bug rather than a limit.
    #
    # Ubuntu 24.04 activates sshd through a systemd socket, where sshd_config's
    # MaxStartups is ignored and systemd's own connection limit applies instead.
    # Running sshd as a normal service is what makes the setting take effect.
    vm 'printf "MaxStartups 200:30:400\nMaxSessions 200\n" > /etc/ssh/sshd_config.d/hindsight.conf
        systemctl disable --now ssh.socket >/dev/null 2>&1 || true
        systemctl enable --now ssh.service >/dev/null 2>&1 || true
        systemctl restart ssh.service'

    vm "install -d -m 700 /root/.ssh
        printf '%s\n' '$(cat "$key.pub")' > /root/.ssh/authorized_keys
        chmod 600 /root/.ssh/authorized_keys"

    if ! vm 'test -d /data/coolify' 2>/dev/null; then
      echo "installing Coolify, which takes a few minutes"
      vm 'curl -fsSL https://cdn.coollabs.io/coolify/install.sh -o /root/install.sh && bash /root/install.sh' \
        | tail -5
    fi

    # The API is off by default on a fresh install, which the tests rely on
    # knowing; it is turned on here so both discovery paths can be compared.
    vm 'docker exec coolify php artisan tinker --execute="
      \$s = App\Models\InstanceSettings::first(); \$s->is_api_enabled = true; \$s->save();
    "' >/dev/null 2>&1 || true

    echo "Coolify ready"
    "$0" env
    ;;

  env)
    # Quoted: a Sanctum token contains a pipe, which an unquoted eval would
    # treat as a shell pipeline.
    #
    # The VM is reached through OrbStack's SSH endpoint on loopback. The user is
    # OrbStack's `<user>@<machine>` syntax, so this is a real ssh connection to
    # a real sshd, over an address the safety guard accepts without argument.
    echo "export HINDSIGHT_TEST_COOLIFY_HOST='127.0.0.1'"
    echo "export HINDSIGHT_TEST_COOLIFY_PORT='$(orb_ssh_port)'"
    echo "export HINDSIGHT_TEST_COOLIFY_USER='root@coolify'"
    echo "export HINDSIGHT_TEST_COOLIFY_KEY='$(orb_ssh_key)'"
    echo "export HINDSIGHT_TEST_SSH_KEY='$key'"
    if [[ -f "$root/testenv/.keys/coolify-token" ]]; then
      echo "export HINDSIGHT_TEST_COOLIFY_TOKEN='$(cat "$root/testenv/.keys/coolify-token")'"
    fi
    ;;

  token)
    # Mints a read/write token for the team that owns the installer's server.
    vm 'docker exec coolify-db psql -U coolify -d coolify -c "UPDATE servers SET team_id = 1 WHERE id = 0" >/dev/null
        docker exec coolify php artisan tinker --execute="
          \$plain = bin2hex(random_bytes(24));
          \$id = DB::table(\"personal_access_tokens\")->insertGetId([
            \"tokenable_type\" => \"App\\\\Models\\\\User\",
            \"tokenable_id\" => 1, \"team_id\" => 1, \"name\" => \"hindsight\",
            \"token\" => hash(\"sha256\", \$plain),
            \"abilities\" => json_encode([\"read\"]),
            \"created_at\" => now(), \"updated_at\" => now(),
          ]);
          echo \"TOKENIS {\$id}|{\$plain}\";
        "' | grep -o 'TOKENIS .*' | cut -d' ' -f2 > "$root/testenv/.keys/coolify-token"
    echo "token written to testenv/.keys/coolify-token"
    ;;

  down)
    orbctl delete "$machine"
    rm -f "$root/testenv/.keys/coolify-token"
    ;;

  *)
    echo "usage: coolify-testenv.sh [up|env|token|down]" >&2
    exit 1
    ;;
esac
