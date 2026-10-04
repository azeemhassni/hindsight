# Changelog

## M0 — Foundations

- Swift 6 package with `HindsightCore` and `HindsightProcess`, macOS 14 minimum.
- Domain model: validated identifiers, servers, schedules, retention policies,
  backup profiles, snapshots and their tag convention, job kinds, secrets.
- Subprocess layer: line-oriented streaming, cancellation that kills the child,
  an environment allowlist instead of inheritance, and secret redaction across
  output and errors.

## M1 — Pinned binary provisioning

- `scripts/vendor.sh` downloads, verifies, and extracts restic 0.19.1 (linux
  amd64/arm64, darwin amd64/arm64) and rest-server 0.14.0 (darwin amd64/arm64),
  checking each artifact twice: the archive against the upstream `SHA256SUMS`,
  and the extracted executable against a digest pinned in git.
- `BinaryStore` verifies a binary before it is used, locally or remotely, and
  fails closed on a mismatch.
- The pinned table is generated from `vendor/checksums.txt` so the digests the
  app enforces cannot drift from the ones the vendoring script enforces.

## M2 — SSH transport

- Managed ssh configuration, `known_hosts` pinning with explicit first-connect
  confirmation, and a hard failure on any later key change. The user's own
  `~/.ssh` is never read or written.
- Connection sharing with short control tokens, recovery from a stale control
  socket, and reverse port forwards whose remote port the server chooses.
- Remote commands that carry secrets over stdin rather than in `argv`, with
  quoting verified against a real shell.
- One-round-trip fact probe: OS, architecture, sudo, `nice`/`ionice`, Docker,
  Coolify, mounts, listening ports, and the test marker.
- Pinned restic installed and verified on the server before every run.
- The destructive-operation guard: a local address **and** the marker file.
- A local Docker environment (`scripts/testenv.sh`) with sshd, Postgres, and
  MySQL, and integration tests that only ever talk to 127.0.0.1.
- Process layer: timeouts, and event-driven reads in place of blocking ones.

## M3 — Catalog

- GRDB schema and migrations for servers, repositories, schedules, retention
  policies, path rules, snapshots and their tags, jobs and events, integrity
  checks, Coolify resources and captures, and restores.
- Single writer, many readers: WAL, foreign keys on, and a busy timeout so a
  routine overlap never fails a backup.
- Refuses to open a catalog written by a newer build rather than guessing at
  an unknown schema.
- Resource history by tag, pruned-snapshot reconciliation, bounded job event
  history, and retention that falls back to the documented defaults so a
  missing row can never read as "keep nothing".

## M4 — First real backup, end to end

- rest-server supervised per session: loopback, append-only, private repos, a
  kernel-chosen port, and `{SHA}` credentials generated per run.
- Reverse-tunnelled backups with live progress, a metadata snapshot of each
  server, include paths filtered to what actually exists, and restic's
  "finished but incomplete" exit status surfaced as a warning rather than a
  success.
- Repository locking in two layers, an actor and `flock`, so the app and the
  agent cannot collide.
- Verified against the local container: stock restic reads the result, a repeat
  run adds under 1% of the first, progress arrives during the run, append-only
  refuses to delete data while permitting lock removal, concurrent backups take
  turns, and an interrupted backup leaves nothing behind.

## M5 — Retention, maintenance, integrity

- Grandfather-father-son retention that agrees with restic snapshot for
  snapshot, checked against `forget --dry-run --json` on a generated two-year
  repository across ten policies.
- `forget`, `prune`, `diff`, and a `check --read-data-subset` rotation that
  reaches the whole repository over a configurable window.
- A prune is always followed by a check, and refuses to start without headroom.
- Verified locally: a corrupted pack is caught by reading data, a full rotation
  finds damage anywhere in the repository, and pruning leaves a healthy
  repository that is smaller than before.

## M6 — Scheduling, agent, and the XPC surface

- Five-field cron parser, written rather than borrowed, including the rule that
  a restricted day-of-month and day-of-week combine as "or".
- Cadence evaluation that survives both clock changes and leap days, keeps
  "every N hours" aligned to midnight across restarts, and turns a long sleep
  into exactly one catch-up run rather than a backlog.
- An AC-power policy that defers rather than skips.
- A scheduler actor with one coalescing timer, and a job queue that serialises
  per repository while saying which job is waiting and why.
- The Keychain store, with `kSecAttrAccessibleAfterFirstUnlock` so scheduled
  backups work on a locked Mac, and an in-memory store for tests.
- A small XPC surface carrying JSON, with the peer pinned to the team's code
  signature, and the `hindsight-agent` executable that owns the schedule, the
  jobs, and the catalog.

## M9 — Database consistency

- Detection of database containers by image, of host services by listening
  port, and of network-reachable instances, with sidecars and exporters
  deliberately ignored.
- Logical dumps streamed straight into restic with no temporary file on the
  server: Postgres in custom format with globals captured separately,
  MySQL/MariaDB inside a transaction, MongoDB as an archive, and Redis via a
  `BGSAVE` whose completion is confirmed by the save timestamp.
- Each dump is its own tagged snapshot, so a database's history is queryable
  on its own and retained under its own policy.
- A failing dump is reported as a failure rather than stored as an empty
  success — the shell is chosen from the server's own facts so that a failure
  in the producing half of the pipe is actually detected.
- Consistency is stated honestly per engine: MySQL covers InnoDB only, and
  Redis is a point-in-time copy rather than a transaction.

## M10 — Coolify, verified first

- `docs/COOLIFY.md`: every path, label, container, API shape and schema detail
  read off a live v4.3.23 install, with the corrections it forced.
- Discovery from container labels (always available), from the API (which is
  **off** on a fresh install), and the tree assembled the same way by both —
  proven equal on the same install, resource for resource and volume for
  volume.
- Resource identity comes from the Docker Compose project label, because
  Coolify writes no uuid label at all; the numeric ids it does write are not
  stable across a restore.
- Coolify's own containers are excluded: they carry `coolify.managed=true` but
  no `coolify.type`.
- An instance plan that captures `APP_KEY`, `acme.json`, the ssh keys, the ssl
  certificate and the per-resource directories, excludes churning metrics, and
  dumps `coolify-db` as its own user — each path checked against the live VM.
- Proxy flavour is detected from the `coolify-proxy` image rather than assumed.
- `scripts/coolify-testenv.sh` provisions the VM reproducibly; `make
  test-coolify` runs the suite deliberately, since the VM and the Docker
  environment contend when run together.
