#!/bin/bash
# Creates a deterministic dataset so an incremental backup and a restore can be
# compared byte for byte. Generated rather than committed: reproducible, and no
# binary blobs in git.
set -euo pipefail

root=/srv/hindsight-dataset
mkdir -p "$root"/{config,logs,uploads,nested/deep/deeper}

for i in $(seq 1 40); do
  # Deterministic pseudo-random content, distinct per file.
  head -c $((i * 4096)) /dev/zero | tr '\0' "$(printf '\\%03o' $((65 + i % 26)))" \
    > "$root/uploads/file-$i.bin"
done

printf 'listen_addresses = %s\nmax_connections = 100\n' "'*'" > "$root/config/service.conf"
printf 'alpha\nbeta\ngamma\n' > "$root/config/list.txt"
printf 'nested payload\n' > "$root/nested/deep/deeper/leaf.txt"
head -c 1048576 /dev/zero | tr '\0' 'L' > "$root/logs/service.log"

ln -sf ../config/list.txt "$root/nested/link-to-list.txt"
mkdir -p "$root/empty-directory"

install -d -m 700 "$root/private"
printf 'secret-ish\n' > "$root/private/credentials.txt"
chmod 600 "$root/private/credentials.txt"

# A manifest the tests compare against after a restore.
cd "$root"
find . -type f -print0 | sort -z | xargs -0 sha256sum > /srv/hindsight-dataset.sha256
