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
