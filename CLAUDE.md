# Hindsight — working rules

Time Machine for VPSes: a native macOS app that backs up servers over SSH with
restic, and restores them.

## Safety (non-negotiable)

- **Never run a restore, or any write or destructive command, against a real
  server.** Do not SSH into any host from the user's config, and do not SSH into
  any non-local host, during development or testing.
- All restore and write testing happens against local Docker containers, or a
  local OrbStack/Lima VM when Docker cannot do the job (Coolify).
- This is enforced in code, not just by convention. Restore integration tests
  refuse to run unless **both** hold:
  1. the target address is `127.0.0.1`, `localhost`, or a Docker/OrbStack
     network address; and
  2. the file `/etc/hindsight-test-target` exists on the target.
  A test asserts that this guard rejects a non-local target, and rejects a local
  target without the marker file.
- A restore must never remove Hindsight's own access to a server. Full-server
  in-place restores exclude `/boot`, `/etc/fstab`, network configuration,
  `/etc/ssh` host keys, and the SSH user's `authorized_keys` unless the user
  explicitly opts in.
- Never claim zero downtime where it is not true.

## Commits

- Short, imperative, one line. e.g. `add restic tunnel transport`.
- No commit bodies unless genuinely necessary.
- **Never** add Claude as a co-author. No `Co-Authored-By:` trailers, no
  "Generated with Claude Code" lines, no AI attribution anywhere in commits,
  PR descriptions, code, or docs.

## Code style

- No verbose comments. Comment only non-obvious **why**, never **what**.
- Swift 6, strict concurrency, macOS 14+. SwiftUI for the app.
- Core logic lives in Swift Package modules so it is testable without the app.
- Secrets (repo passwords, SSH keys, Coolify API tokens) live in the Keychain
  only — never in plain files, never in `UserDefaults`, never in logs.
- Persist catalog, metadata, and job history in SQLite via GRDB.

## Engine

- Do not invent chunking, dedup, or encryption formats. Use pinned restic and
  rest-server (both BSD-2).
- Pruning, forgetting, and integrity checks run locally on the Mac against the
  repository, never from the VPS.
- rest-server runs bound to `127.0.0.1` in append-only mode for backup sessions.

## Verification

- Verify every external claim — Coolify paths, labels, API shapes, schemas —
  against a real install in the local test VM before relying on it. Do not
  trust memory, the user's or your own.
- Report anything that turned out differently from what was specified.

## Deliverables per milestone

Working code, passing tests, a changelog line, and a note on anything verified
differently from the spec.
