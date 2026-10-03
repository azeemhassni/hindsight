# Hindsight — Plan

Milestones are ordered so that each one ends with something demonstrable and
tested. Nothing in a later milestone is required to make an earlier one useful.

Every milestone delivers: working code, passing tests, one changelog line, and a
note on anything that turned out differently from `docs/ARCHITECTURE.md` or the
original brief.

Legend: **AC** = acceptance criteria, all of which must pass before the
milestone is called done.

---

## M0 — Foundations

Repository skeleton and the test loop everything else relies on.

- `Package.swift` with every module from Architecture §3, Swift 6 strict
  concurrency, macOS 14 minimum.
- `Makefile`: `test`, `test-integration`, `lint`, `vendor`, `app`.
- `HindsightCore` domain types: `Server`, `Repository`, `Snapshot`, `Schedule`,
  `RetentionPolicy`, `BackupProfile`, `JobKind`, error taxonomy.
- `HindsightProcess`: argv/env subprocess runner with streaming output,
  cancellation, typed exit handling, and secret redaction.
- `.gitignore`, `.swiftformat`/`.swiftlint.yml`, `docs/CHANGELOG.md`.

**AC**

- `swift build` and `make test` are green with zero concurrency warnings under
  `-strict-concurrency=complete`.
- A test proves `HindsightProcess` streams incrementally (does not buffer to
  completion), propagates cancellation by killing the child, and redacts a
  registered secret from captured stdout, stderr, and error descriptions.
- Every module compiles independently; no library target imports AppKit.

---

## M1 — Pinned binary provisioning

The supply chain, before anything depends on it.

- `scripts/vendor.sh`: download restic 0.19.1 (`linux_amd64`, `linux_arm64`,
  `darwin_amd64`, `darwin_arm64`) and rest-server 0.14.0 darwin builds.
- `vendor/checksums.txt` with SHA-256 for each artifact, cross-checked against
  the upstream `SHA256SUMS`.
- `BinaryStore` in `HindsightRestic`: locate the right binary for a platform,
  verify a SHA-256, decompress, and report a typed mismatch.

**AC**

- `make vendor` is reproducible: a second run with no network changes produces
  identical files and reports all checksums verified.
- A corrupted artifact fails the build loudly, naming the file and both digests.
- Unit test on the verifier covers match, mismatch, and missing-file.
- No binary is committed to git; `vendor/` artifacts are ignored, checksums are
  not.

---

## M2 — SSH transport

- Managed ssh config and `known_hosts` generation under
  `~/Library/Application Support/Hindsight/ssh/`.
- `ControlMaster` pool with `%C` control paths, lifecycle, and teardown.
- TOFU host-key flow: `ssh-keyscan`, fingerprint presentation, explicit
  confirmation, pin; hard failure on any later change.
- Remote fact probe: OS/distro, kernel, architecture, `sudo -n` availability,
  filesystem types and mounts, container runtime, listening DB ports.
- Reverse-forward allocation via `-R 0:` with port parsing.
- Binary upload to `~/.cache/hindsight/`, with pre-run SHA-256 verification.
- The development loopback guard (Architecture §5, §16).

**AC**

- Integration tests against a local sshd container: connect, probe facts, upload
  and verify the binary, open a reverse forward and prove it carries traffic.
- Changing the container's host key makes the next connection fail with a
  distinct, user-presentable error — not a prompt, not an auto-accept.
- A test proves the dev guard refuses a non-loopback host, and that the refusal
  happens before any network I/O.
- A test proves Hindsight never reads the user's `~/.ssh/config` or
  `~/.ssh/known_hosts`.
- `ControlPath` stays within the 104-byte `sockaddr_un` limit for a long server
  id (property test).

---

## M3 — Catalog

- GRDB schema and migrations for every table in Architecture §10.
- Query repositories for servers, snapshots, jobs, events, checks.
- Single-writer/multi-reader setup: writer pool for the agent, read-only pool
  for the app, WAL, change notifications.
- `job_events` rotation so history cannot grow unbounded.

**AC**

- Migration tests: fresh install reaches head; every migration is applied
  exactly once; a downgrade attempt is refused rather than corrupting data.
- Round-trip tests for each entity, including tag queries
  (`coolify:<uuid>` lookups return the right snapshots).
- A concurrency test with a writer and several readers shows no reader blocking
  and no `SQLITE_BUSY` under load.
- Event rotation keeps a bounded row count under a synthetic flood.

---

## M4 — First real backup, end to end

The core of the product.

- rest-server supervisor: ephemeral port, `--append-only`, `--private-repos`,
  generated `.htpasswd`, lifecycle tied to the job, hard kill on cleanup.
- Repository lock: actor plus `flock`, honored across processes.
- Repository init, restic driver, argv/env construction, `--json` event decoder.
- Backup job: preflight → tunnel → remote restic → progress → catalog write.
- Default include/exclude profile and the metadata snapshot (§8).

**AC**

- Integration test backs up the seeded Ubuntu container into a fresh repository;
  the snapshot is listed by stock `restic snapshots` and recorded in the
  catalog with matching id, time, and byte counts.
- Second backup with no changes adds **under 1%** of the first run's
  `data_added`; after mutating a known 10 MB file, the increment is bounded near
  that change, not the dataset.
- Progress events arrive during the run, not only at the end (asserted by event
  timestamps spread across the run).
- Append-only is enforced end to end: a `DELETE` of a data object through the
  tunnel is refused, and a `DELETE` of a lock object succeeds — matching
  Architecture §7 exactly.
- Two concurrent backup jobs against one repository serialize; the second
  reports waiting and then succeeds.
- Killing the ssh process mid-backup leaves no orphan rest-server and no
  permanent lock; the next run recovers automatically.
- The metadata snapshot contains every file listed in §8 and
  `hindsight-manifest.json` round-trips.

---

## M5 — Retention, maintenance, integrity

- GFS engine in `HindsightSchedule` with the documented defaults.
- `forget --prune`, `check`, and `check --read-data-subset=k/N` rotation with
  persisted rotation state.
- Disk-space projection and refusal thresholds.
- Stale-lock detection and local `restic unlock`.

**AC**

- The local GFS engine agrees with `restic forget --dry-run --json` on a
  generated corpus spanning two years of synthetic snapshots across several
  policies — an exact set match, not a count match.
- Dump-tagged snapshots are retained under their own policy and are not expired
  by the filesystem policy (explicit test).
- A corrupted pack file in a throwaway repository is detected by
  `check --read-data-subset`, the failure is recorded in `integrity_checks`, and
  the server's health reflects it.
- The subset rotation covers 100% of packs across N runs, with no gaps and no
  repeats, proven by accumulating the subsets.
- A simulated low-disk condition refuses a prune **before** starting it; a
  refusal never leaves a half-written repository.

---

## M6 — Agent, scheduler, XPC, menu bar

- `hindsight-agent` executable; `SMAppService` registration and deregistration.
- Scheduler actor: cadences, cron parser, next-fire computation, wake catch-up,
  AC-power policy, queueing.
- XPC protocol and both endpoints, with code-signing requirements pinned.
- Menu bar extra: status, last backup, next backup, "Back up now".
- User notifications for failures, completed restores, integrity problems.

**AC**

- A scheduled job runs to completion with the app not running, and the result is
  visible when the app is next opened.
- Cron and cadence unit tests, including DST transitions in both directions,
  leap days, and "every N hours" alignment across a reboot.
- A window missed during sleep produces exactly one catch-up run, not one per
  missed window (simulated clock test).
- AC-only jobs defer on battery and start on reconnect.
- An XPC client that does not satisfy the code-signing requirement is rejected.
- Menu bar strings match the catalog state, including the "waiting on lock" and
  "deferred on battery" cases.

---

## M7 — UI shell and onboarding

- `NavigationSplitView` shell, sidebar with health dots, server view with
  timeline, size/dedup chart, schedule status, activity log.
- Settings for connection, schedule, retention, rules, bandwidth, repo location,
  integrity rotation.
- Onboarding: add server → verify host key → detect sudo/Coolify/OS → first
  backup → recovery kit export.
- Recovery kit generator: human-readable plus JSON, with stock-restic commands.

**AC**

- Onboarding completes against the local sshd container and ends with a kit on
  disk; the kit's commands, pasted into a shell with stock restic, list and
  restore from the repository with Hindsight not running (verified in the test).
- Onboarding cannot be finished without exporting the kit.
- Light and dark both pass a contrast check; every control has an accessibility
  label; the timeline is keyboard-navigable and announces positions.
- Activity-log errors are copyable in full and contain no secret material
  (asserted against a run with known secrets registered).

---

## M8 — Snapshot browser

- Lazy file tree over `restic ls`, search, Quick Look for text and images.
- Diff between any two snapshots.
- Restore of a single file or folder to an alternate path.

**AC**

- A tree of 1M files opens and scrolls without loading it all (bounded memory
  and request count asserted).
- Diff output matches `restic diff` for a generated change set covering adds,
  removes, content changes, and mode/ownership changes.
- Single-file restore to an alternate path produces a byte-identical file,
  verified by checksum, with the guard satisfied.

---

## M9 — Consistency: database dumps and filesystem snapshots

- Detection of DB containers and host services.
- Postgres, MySQL/MariaDB, MongoDB, Redis dump streaming into `restic --stdin`
  with the documented tags.
- LVM/btrfs/ZFS snapshot offer, creation, and teardown.
- Crash-consistent labeling of DB volume copies.

**AC**

- Postgres and MySQL containers are detected, dumped, and the dumps restore into
  a scratch instance with row counts and checksums matching the source.
- A dump is stored as its own tagged snapshot and is queryable alone.
- Redis `BGSAVE` completion is detected correctly (test includes a slow save),
  and an AOF-only instance takes the AOF path.
- A failed snapshot creation leaves no leftover LVM/btrfs/ZFS snapshot.
- Restoring a database scope prefers the logical dump over the volume copy, and
  the UI says why.

---

## M10 — Coolify: verify, then discover

**This milestone starts with verification, not code.** A Coolify install runs in
an OrbStack VM and every item in Architecture §13.2 is checked against it. The
findings land in `docs/COOLIFY.md` with the commands and outputs that produced
them, and anything that contradicts the brief or §13 is called out.

Then: API client, label parsing, read-only DB fallback, resource-tree
construction, per-resource capture planning, `coolify:<uuid>` tagging, the
Coolify tab, and the Coolify-instance backup flow.

Also researched and reported here before M12 begins: what Coolify supports
natively for rolling updates and proxy routing switches, and whether blue/green
restore can use it rather than manipulating the proxy directly.

**AC**

- `docs/COOLIFY.md` exists, is sourced from the live VM, and resolves every
  open item in §13.2 with evidence.
- Discovery produces an identical resource tree from the API and from labels
  alone on the same install; differences, if any, are enumerated and explained.
- Per-resource capture backs up a sample application and a sample database
  resource; both are restorable in M11, and each resource's history is
  retrievable by tag alone.
- The Coolify-instance backup includes the environment file holding `APP_KEY`,
  the `coolify-db` dump, `ssh`, and `proxy`; a test fails the job if the
  environment file is missing from the snapshot.
- Discovery degrades cleanly with no token, and the UI shows which source
  produced the tree.
- A written report on native rolling-update support, with a recommendation for
  M12.

---

## M11 — Restore engine and wizard

- Restore planning: scope resolution, target resolution, exclusion enforcement,
  mode-availability analysis with reasons.
- Safety snapshot, then `restic diff` as the dry-run preview.
- Standard and minimal-downtime modes.
- Wizard UI, hostname-typed confirmation, undo via the safety snapshot.
- The `DestructiveOperationPolicy` guard, wired through production and test
  paths.

**AC**

- Guard tests: rejects a public address; rejects loopback without
  `/etc/hindsight-test-target`; admits a marked local target; the restore suite
  **fails** rather than skips if the guard is constructible for a non-local
  host. Integration restores additionally require
  `HINDSIGHT_ALLOW_DESTRUCTIVE_TESTS=1`.
- Full cycle per mode, against local containers only: backup → mutate →
  incremental → restore → checksum comparison against the original dataset,
  byte-identical including ownership and modes.
- Minimal-downtime mode's measured downtime is within the estimate shown, and
  the swap is atomic (a reader during the swap sees old or new, never partial).
- The dry-run diff exactly matches what the restore then changes (asserted by
  re-diffing afterwards).
- Undo: restoring the safety snapshot returns the target to its pre-restore
  state, checksum-verified.
- Hard exclusions hold: a full-server in-place plan excludes `/boot`,
  `/etc/fstab`, network config, host keys, and `authorized_keys` by default, and
  any plan that would cut off Hindsight's own access is refused outright —
  tested, not asserted in prose.
- Mode availability reasons are generated from facts, and a test covers the
  "unavailable because…" string for each reason.

---

## M12 — Zero-downtime restore and per-resource Coolify restore

Gated on the M10 research report.

- Blue/green: restore to new volumes, start a parallel container, health-check,
  switch routing (natively through Coolify where supported, at the proxy
  otherwise), retire the old container.
- Database blue/green: restore into a new instance, swap the connection.
- Per-resource restore in place, as a clone for inspection, and to another
  Coolify server (migration).

**AC**

- A sample application resource is restored with no failed requests, proven by a
  continuous request loop running across the switch in the test.
- The UI states, prominently and before confirmation, that writes between the
  snapshot and the switch are lost — asserted in a UI test.
- Clone restore produces an inspectable copy with no effect on the live
  resource, verified by checksums on both.
- Cross-server migration between two Coolify VMs reproduces the resource,
  including env vars and volumes; the source is untouched.
- Rollback: if the health check fails, the old container keeps serving and the
  restored artifacts are cleaned up.
- Where zero downtime is not achievable for a selection, it is not offered, and
  the reason is shown.

---

## M13 — Phase 2: second copy

- `restic copy` to an external disk, S3/B2, or another restic repository, on an
  independent schedule, with credentials that never reach a VPS.

**AC**

- A copy to a second local repository reproduces every snapshot; stock restic
  restores from the copy without Hindsight.
- Independent scheduling and retention for the copy target.
- Copy failures do not affect primary backups and are surfaced separately.
- Credentials for the copy target are Keychain-only and provably absent from
  anything a VPS can observe.

---

## Cross-milestone invariants

Checked at every milestone, not just the one that introduces them:

- No SSH to any non-local host in any test or development path.
- No secret in `argv`, logs, the catalog, `UserDefaults`, or the UI.
- `make test` green; no new concurrency warnings.
- No AI attribution anywhere in commits, code, or docs.
- Every claim the UI makes about downtime, consistency, or safety is either
  tested or softened until it is true.
