# Hindsight — Architecture

Hindsight backs up Linux VPSes to a Mac over SSH and restores them. It is a
Time Machine for servers: a background agent runs scheduled jobs, a SwiftUI app
browses history and drives restores, and Coolify-managed servers get
per-resource backup and restore.

Status: implemented and corrected against reality. Where measurement
contradicted the original design, this document was updated and the reason
recorded in `docs/DECISIONS.md`. `docs/CHANGELOG.md` says what each milestone
delivered; §20 lists what is built but not yet connected to the interface.

---

## 1. Goals and non-goals

**Goals**

- Incremental, deduplicated, compressed, encrypted, verifiable backups.
- A compromised VPS cannot destroy backup history.
- Logically consistent database backups, not copies of live data files.
- Restores that can be previewed, undone, and honestly described.
- Coolify v4 as a first-class concept: project → environment → resource.
- Small, auditable VPS footprint: one cached binary plus a lock file per run.

**Non-goals**

- No new chunking, dedup, or crypto format. restic owns that.
- No agent installed permanently on the VPS. No daemon, no package, no systemd
  unit. Hindsight pushes a static binary and runs it for the duration of a job.
- Not a monitoring or configuration-management tool.
- Not sandboxed, therefore not a Mac App Store app (see §4).

---

## 2. System shape

```
  Mac (trusted)                                  VPS (semi-trusted)
  ┌──────────────────────────────────────┐        ┌───────────────────────────┐
  │ Hindsight.app (SwiftUI + menu bar)   │        │                           │
  │        │ XPC (code-sig pinned)       │        │  restic (cached, verified)│
  │        ▼                             │        │     │                     │
  │ hindsight-agent (LaunchAgent)        │        │     │ rest:http://        │
  │   scheduler · job runner · notifier  │        │     │ 127.0.0.1:<rport>   │
  │        │                 │           │        │     ▼                     │
  │        │                 └──► /usr/bin/ssh ───┼──► sshd  -R <rport>       │
  │        │                      ControlMaster   │                           │
  │        ▼                             │        └───────────────────────────┘
  │   rest-server --append-only          │   reverse tunnel carries only
  │   127.0.0.1:<lport>                  │   new chunks, both directions
  │        │                             │
  │        ▼                             │
  │   restic repository (one per server) │
  │   catalog.sqlite (GRDB)              │
  │   Keychain: repo password, keys, API │
  └──────────────────────────────────────┘
```

Backups are **pushed** by the VPS into a repository that lives on the Mac.
Maintenance (`forget`, `prune`, `check`, `copy`, `diff`) is **pulled** by the Mac
directly against the repository on local disk, with no VPS involvement.

---

## 3. Module layout

One root `Package.swift`. Library targets have no UI and no AppKit dependency so
they test headlessly under `swift test`.

| Module | Responsibility |
|---|---|
| `HindsightCore` | Domain model: `Server`, `Repository`, `Snapshot`, `Schedule`, `RetentionPolicy`, `BackupProfile`, `RestorePlan`. Pure value types, `Sendable`, no I/O. |
| `HindsightProcess` | Subprocess execution: argv/env separation, streaming stdout/stderr, cancellation, exit-status typing, redaction of secrets from captured output. |
| `HindsightSSH` | ssh config generation, `ControlMaster` lifecycle, TOFU host-key flow, `known_hosts` pinning, reverse-forward port allocation, remote fact probing (OS, arch, sudo, filesystems, containers). Includes the development loopback guard. |
| `HindsightRestic` | restic driver: argument construction, `--json` event decoding, repository init, snapshot listing, `diff`, `forget`/`prune`/`check`, `restore`, `--stdin` ingestion. Plus the rest-server supervisor. |
| `HindsightCatalog` | GRDB schema, migrations, query repositories, job and event history, change notifications. |
| `HindsightSchedule` | Cadence evaluation, cron parsing, wake/catch-up policy, AC-power policy, per-repository mutual exclusion, GFS retention math. |
| `HindsightCoolify` | API client, label parsing, read-only DB queries, resource-tree construction, per-resource capture planning. |
| `HindsightRestore` | Restore planning: scope resolution, diff computation, mode-availability analysis, safety-snapshot orchestration, exclusion enforcement. |
| `HindsightProtocol` | XPC protocol and DTOs shared by app and agent. |
| `HindsightAgent` | Agent executable: scheduler loop, job runner, XPC listener, notifications. |
| `HindsightTestSupport` | Docker/OrbStack harness, fixtures, seeded datasets, and the destructive-operation guard used by integration tests. |

`App/` holds the Xcode project for `Hindsight.app`, which depends on the local
package and embeds the agent. See §17 for how the project file is managed.

Concurrency: strict mode, `Sendable` domain types, actors for stateful
components (`RepositoryLockManager`, `JobRunner`, `ControlMasterPool`). Long
operations expose `AsyncThrowingStream` of typed events rather than callbacks.

---

## 4. Process and privilege model

**Three principals, one code signature.**

1. `Hindsight.app` — regular UI app, hardened runtime, Developer ID signed, not
   App Sandboxed. Sandboxing is incompatible with what this app must do: exec
   `/usr/bin/ssh`, write a repository to an arbitrary external volume, and
   supervise a bundled server binary. Consequence: distribution is direct
   download, notarized. Not Mac App Store.
2. `hindsight-agent` — a `LaunchAgent` in
   `Hindsight.app/Contents/Library/LaunchAgents/`, registered with
   `SMAppService.agent(plistName:)`. Runs in the user session, not as root: the
   repository lives in user-owned storage and no local privilege is required.
   Keeps running when the UI is closed. Owns scheduling and job execution.
3. `rest-server` — a short-lived child of the agent, one per backup session,
   bound to `127.0.0.1` on an ephemeral port, in append-only mode.

**UI ↔ agent.** `NSXPCListener` with a Mach service declared in the agent's
plist. Both sides pin the peer with
`NSXPCConnection.setCodeSigningRequirement(_:)` against the team identifier, so
an unsigned or foreign process cannot drive backups or ask for secrets. The
protocol is request/response plus a progress-listener endpoint the app registers
for live job events.

**Catalog ownership.** The agent is the single writer. The app opens the same
SQLite file through a read-only GRDB `DatabasePool` (WAL, so readers never block
the writer) for list and timeline views, and receives invalidation events over
XPC to refresh. This keeps SwiftUI reads fast without proxying every query, and
keeps writes serialized in one process.

**Secrets.** Keychain only, in a shared keychain access group so app and agent
both reach them under one signature. Items:

- `repo-password/<server-id>` — restic repository password, generated by
  Hindsight, 256 bits of entropy, `kSecAttrAccessibleAfterFirstUnlock` so the
  agent can run before the user logs in interactively.
- `rest-credential/<server-id>` — rest-server basic-auth username/password.
- `ssh-key/<server-id>` — private key material when Hindsight generates the key;
  existing user keys are referenced by path and never copied.
- `coolify-token/<server-id>` — API token, read scope only.

Nothing secret is ever passed on a command line. restic receives the repository
URL and password through the environment of the remote process
(`RESTIC_REPOSITORY`, `RESTIC_PASSWORD`), which on Linux is readable only by
root and the process owner, unlike `argv` which is world-readable via `ps`.
`HindsightProcess` redacts known secret values from any captured output before
it reaches logs, the catalog, or the UI.

**Notifications.** `UNUserNotificationCenter` from the agent, which inherits the
app bundle's notification identity because it is embedded in the bundle.
Failures, completed restores, and integrity problems are notified; routine
successes are not.

---

## 5. Transport: SSH

Shell out to the system `/usr/bin/ssh`. No embedded SSH library: the system
client is the best-audited one on the machine, and matching its config and
`known_hosts` semantics by hand is a liability.

**Managed config.** Hindsight owns
`~/Library/Application Support/Hindsight/ssh/config` and generates one stanza
per server. Jobs invoke `ssh -F <that config> hs-<server-id>`. Nothing in the
user's own `~/.ssh/config` is read or written. Key options:

```
Host hs-<id>
  HostName <host>
  Port <port>
  User <root|user>
  IdentitiesOnly yes
  IdentityFile <managed or user key>
  UserKnownHostsFile ~/Library/Application Support/Hindsight/ssh/known_hosts
  StrictHostKeyChecking yes
  ControlMaster auto
  ControlPath ~/Library/Caches/Hindsight/cm/%C
  ControlPersist 120
  ServerAliveInterval 30
  ServerAliveCountMax 6
  ExitOnForwardFailure yes
  BatchMode yes
```

`ControlPath` uses `%C` (a hash) rather than `%h-%p-%r` because the
`sockaddr_un` path limit is 104 bytes on Darwin and Application Support paths
are long. `ExitOnForwardFailure yes` matters: a backup must fail loudly rather
than run against a dead reverse tunnel.

**Host keys.** First connect is explicit TOFU: Hindsight fetches the key with
`ssh-keyscan`, shows the fingerprint and key type, and requires confirmation
before writing `known_hosts`. Afterwards `StrictHostKeyChecking yes` means any
change is a hard failure surfaced as a prominent server error — never
auto-accepted, never `accept-new`.

**Privilege on the VPS.** Backups need root to read `/etc/shadow`,
`/var/lib/docker/volumes`, and other resources. Two supported shapes:

- connect as `root`; or
- connect as an unprivileged user and prefix with `sudo -n`. Hindsight probes
  `sudo -n true` during onboarding and, when it fails, shows the minimal
  sudoers line to paste, scoped to the cached restic binary and the few helper
  commands, with `NOPASSWD`. The UI never asks for a sudo password and no
  password is stored.

**Development guard.** When built for development or tests, `HindsightSSH`
refuses to connect to anything that is not loopback or a Docker/OrbStack address
unless an explicit allowlist environment variable is set. This exists so that a
mistake during development cannot touch a real host. See §16.

---

## 6. Backup engine

### 6.1 Session setup

1. **Acquire the repository lock.** A per-repository actor plus an `flock` on a
   lock file inside the repository directory. Two jobs never touch one
   repository concurrently, including across the app and agent processes.
2. **Preflight.** Free-space check against a projected-growth estimate; repo
   exists or gets initialized; ssh reachable; host key matches; remote OS and
   architecture detected; sudo verified; restic binary present on the VPS with a
   matching SHA-256, otherwise uploaded.
3. **Start rest-server** as a child process:

   ```
   rest-server --listen 127.0.0.1:<lport> --path <repoRoot> \
               --append-only --private-repos --htpasswd-file <generated>
   ```

   `<repoRoot>` is the parent directory holding one subdirectory per server.
   `--private-repos` restricts a credential to the path matching its username,
   so the username is the server id: server A's credential cannot reach server
   B's repository even though one server process serves both. The `.htpasswd`
   file holds a bcrypt hash of a per-server random password and lives in a
   0600 file in a private directory for the session's lifetime.

   `--append-only` is what makes a compromised VPS survivable. See §7 for its
   exact, verified limits.

4. **Open the tunnel.** `ssh -R 0:127.0.0.1:<lport>` lets sshd pick a free
   remote port; Hindsight parses ssh's `Allocated port NNNNN for remote forward`
   line to learn it. Binding a fixed remote port would collide with whatever
   else the VPS runs.

### 6.2 Running the backup

The remote command is built as argv, never as a shell string, and wrapped with
`nice -n 19` and `ionice -c3` **when those binaries exist** (minimal images
often lack `ionice`; absence degrades to `nice` alone rather than failing).

```
RESTIC_REPOSITORY=rest:http://127.0.0.1:<rport>/<server-id>/
RESTIC_PASSWORD=<...>
RESTIC_PROGRESS_FPS=1
~/.cache/hindsight/restic-<ver> backup \
  --json --one-file-system --exclude-caches \
  --tag hindsight --tag profile:full \
  --limit-upload <KiB/s, optional> \
  --files-from-verbatim <uploaded include list> \
  --exclude-file <uploaded exclude list> \
  --retry-lock 5m
```

`--json` emits newline-delimited `status`, `error`, `verbose_status` and
`summary` objects. `HindsightRestic` decodes these into typed events that drive
the activity log (bytes scanned, bytes added, files changed, ETA) and end in a
`summary` whose `snapshot_id`, `data_added`, `total_bytes_processed` and timings
are written to the catalog. Unknown JSON fields are tolerated: the decoder is
additive, so a restic upgrade cannot break progress reporting.

### 6.3 Maintenance, always local

`forget`, `prune`, `check`, `diff`, `restore` staging and the Phase-2 `copy` run
on the Mac, with `RESTIC_REPOSITORY` pointing at the local path directly — not
through rest-server, so append-only does not block them. rest-server is never
running during a prune; the repository lock guarantees it.

### 6.4 Binary provisioning

restic **0.19.1** and rest-server **0.14.0** are pinned. A `make vendor` step
downloads `restic_0.19.1_{linux_amd64,linux_arm64,darwin_amd64,darwin_arm64}`
and the rest-server darwin builds, verifies each against checksums committed in
`vendor/checksums.txt` (cross-checked against the release `SHA256SUMS`), and
places them in the app's resources. The build fails on any mismatch.

darwin builds are needed because maintenance and restore staging run on the Mac.
Both Mac architectures ship; the right one is chosen at runtime.

On the VPS the binary lands at `~/.cache/hindsight/restic-0.19.1` and its
SHA-256 is verified **before every run**, not just on upload. A mismatch
re-uploads rather than executing. Uploaded content is the decompressed static
binary, chmod 0700.

---

## 7. Threat model

The design question is: what can an attacker who fully owns a VPS do to the
backups of that VPS and of others?

**Verified from rest-server source** (`repo/repo.go`, append-only enforcement):
`DELETE` is rejected for every object type **except `locks/`**, and config
deletion is rejected outright. The exemption is deliberate — restic must be able
to drop its own stale locks — and it bounds the claim honestly:

| Capability of a compromised VPS | Possible? |
|---|---|
| Add new snapshots | Yes, by design |
| Delete or modify existing snapshots, data, index, keys, config | No |
| Delete lock files | **Yes** — nuisance and denial of service, not data loss |
| Read the full history of **its own** repository | **Yes** — it holds the repo password during a run |
| Read or write **another server's** repository | No — separate repository, separate credential, `--private-repos` |
| Reach anything else on the Mac | No — only the single reverse-forwarded port is exposed, and it serves one repository path |

The confidentiality limit is inherent to restic: there is no append-only or
write-only key, so a host that can write a backup can also read its own history.
The UI must not imply otherwise. Mitigations in scope: one repository per
server, per-server credentials, and Phase-2 off-Mac copies that a VPS never
holds credentials for.

Stale-lock denial of service is detected (a lock older than the job timeout with
no live job) and cleared locally with `restic unlock`, which is why that
exemption is tolerable.

---

## 8. What gets backed up

**Default full-server profile, included paths:** `/etc`, `/root`, `/home`,
`/opt`, `/srv`, `/usr/local`, `/var/lib/docker/volumes`, `/var/spool/cron`, and
`/data` when present.

**Excluded:** `/proc`, `/sys`, `/dev`, `/run`, `/tmp`, `/var/tmp`, `/var/cache`,
`/var/lib/docker/overlay2`, `/var/lib/docker/{image,buildkit,tmp}`, swap files,
socket and device nodes, plus user-editable globs per server. Docker image
layers are re-pullable and their digests are recorded, so backing them up buys
nothing but bytes.

`--one-file-system` is on by default, with explicitly listed extra mounts, so a
stray network mount or bind cannot silently balloon a backup.

**Metadata snapshot.** Before the filesystem pass, Hindsight collects facts into
`/.hindsight/meta/` inside the snapshot (and indexes key ones in SQLite for the
UI):

- `packages.txt` — `dpkg --get-selections` or `rpm -qa`
- `systemd-units.txt` — `systemctl list-unit-files --state=enabled`
- `crontabs/` — per-user crontabs and `/etc/cron*`
- `docker-images.json` — image ids and `RepoDigests`
- `docker-ps.json`, `docker-inspect/<container>.json`
- `mounts.txt`, `lsblk.json`, `os-release`, kernel version
- `hindsight-manifest.json` — profile, includes, excludes, tool versions, so a
  snapshot is self-describing years later

These make a rebuild possible even where a bare-metal restore is not. They are
recorded, never executed, on restore.

---

## 9. Consistency

Copying a live database file is not a backup. Hindsight detects database engines
two ways — Docker containers by image and label, and host services by systemd
unit and listening port — and streams **logical dumps** into restic as separate,
tagged snapshots via `--stdin`:

| Engine | Command | Notes |
|---|---|---|
| PostgreSQL | `pg_dump -Fc` per database, plus `pg_dumpall --globals-only` | custom format restores selectively with `pg_restore`; globals need a superuser role |
| MySQL / MariaDB | `mysqldump --single-transaction --routines --triggers --events` | transactional only for InnoDB; MyISAM tables are flagged in the UI as not point-in-time |
| MongoDB | `mongodump --archive` | |
| Redis | `BGSAVE`, poll `rdb_bgsave_in_progress` until clear and `rdb_last_save` advances, then stream the RDB | AOF-only instances are detected and the AOF is streamed instead |

Each dump becomes its own snapshot: `--stdin-filename <db>.dump`,
`--tag db:<engine> --tag dbname:<name>`, and `--tag coolify:<uuid>` when it
belongs to a Coolify resource. Separate snapshots mean a database can be restored
without touching the filesystem, and its history is queryable alone. restic
dedups dump streams well in practice but not as well as files, so the UI shows
dump growth separately — a surprise should be visible.

The filesystem pass still captures database volumes. Those copies are
**crash-consistent, not transaction-consistent**; the catalog marks them as such
and the restore planner prefers the logical dump for any database scope. This is
deliberate redundancy: the volume copy preserves configuration and layout, the
dump preserves the data correctly.

**Filesystem snapshots.** When `/` or a data mount is LVM, btrfs, or ZFS,
Hindsight offers to create a temporary snapshot and back up from its mountpoint,
giving one consistent point in time across all files. Detection is from
`lsblk`/`findmnt`; creation and teardown are explicit and reverted on failure.
This is an offer, never a default, because snapshot creation needs free space in
the volume group or pool.

---

## 10. Catalog

SQLite via GRDB at `~/Library/Application Support/Hindsight/catalog.sqlite`, WAL
mode, versioned migrations in `HindsightCatalog`. It is an index and a history,
never the source of truth for backup data — a lost catalog is rebuildable from
the repositories.

```
servers(id, name, host, port, user, auth_mode, sudo_mode, os, arch,
        coolify_version, created_at, last_seen_at)
repositories(id, server_id, path, created_at, password_keychain_ref)
schedules(id, server_id, resource_id?, kind, spec, ac_only, next_fire_at)
retention_policies(id, server_id, resource_id?, scope, keep_within, daily,
                   weekly, monthly, yearly)
path_rules(id, server_id, kind{include,exclude}, glob, source{default,user})
snapshots(id, repo_id, restic_id, time, hostname, tree, parent, paths_json,
          size_bytes, data_added_bytes, kind{filesystem,dump,metadata})
snapshot_tags(snapshot_id, tag)
coolify_projects/environments/resources(uuid, name, kind, parent, ...)
resource_captures(resource_uuid, snapshot_id, captured_at, volumes_json,
                  config_paths_json, env_source)
jobs(id, kind, server_id, resource_id?, state, started_at, finished_at,
     bytes_processed, bytes_added, files_new, files_changed, error_code,
     error_text)
job_events(job_id, seq, at, level, message)   -- bounded, rotated
integrity_checks(id, repo_id, kind, subset, started_at, finished_at, result,
                 errors_json)
restores(id, snapshot_id, scope_json, target_json, mode, safety_snapshot_id,
         state, started_at, finished_at)
```

`restores` plus `safety_snapshot_id` is what makes every restore undoable: the
record points at the snapshot taken of whatever the restore overwrote.

---

## 11. Scheduling and retention

**Scheduler.** An actor in the agent with one coalescing timer rather than a
timer per server. Cadences: hourly, every N hours, daily at a time, weekly, or a
custom cron expression parsed by a small five-field parser in `HindsightSchedule`
(ranges, lists, steps; no dependency). Per-resource overrides sit alongside
per-server schedules and are evaluated identically.

**Wake and catch-up.** The agent observes `NSWorkspace.didWakeNotification` and
re-evaluates. A window missed while asleep runs **once**, immediately, then
realigns to the cadence — never N catch-up runs for N missed hours. Optional
"only on AC power" is checked through `IOPSCopyPowerSourcesInfo`; a job deferred
for power runs as soon as power returns.

**Mutual exclusion.** The repository lock from §6.1. A job that cannot take the
lock is queued, not dropped, and the UI shows it as waiting with the reason.

**Retention.** Grandfather-father-son, per server, editable. Defaults:
everything within 24h, 7 daily, 4 weekly, 12 monthly, 2 yearly. Execution is
`restic forget --keep-within 24h --keep-daily 7 --keep-weekly 4
--keep-monthly 12 --keep-yearly 2 --prune`.

Hindsight also implements the policy locally, for one reason: the UI must show
exactly which snapshots a policy change would delete, before anything is
deleted. That creates a correctness risk — two implementations that could
disagree — so the local engine is validated against `restic forget --dry-run
--json` in tests, and the preview shown to the user comes from restic's dry run
whenever the repository is reachable. The local engine is the predictive model;
it is never the authority.

Dump snapshots are forgotten under their own tag-scoped policy, so a
`--keep-daily 7` on files does not quietly delete a year of database dumps.

---

## 12. Data integrity and recovery

- `restic check` after every prune. Structural problems fail the job loudly.
- `restic check --read-data-subset=k/N` on a rotation, with `k` advancing each
  run so the whole repository is read and verified over a configurable window
  (default 4 weeks). Progress through the rotation is visible: "3 of 4 parts
  verified, repository fully verified 6 days ago".
- Check results are prominent, not buried in a log: a server's health dot
  reflects the last check, and an integrity failure raises a notification and a
  persistent banner.
- **Disk-space discipline.** Before any backup or prune, project the space
  needed and refuse rather than half-write. A prune is the dangerous one, so it
  requires a larger margin and is never started if the volume could cross its
  threshold mid-run. Low-space warnings arrive before the hard stop.
- **Recovery kit.** Onboarding refuses to finish without exporting one: a
  human-readable document plus machine-readable JSON containing the repository
  password, repository path and layout, restic version, and literal commands to
  restore **without Hindsight** using only stock restic. The warning is
  explicit: losing both the kit and the Keychain means the backups are
  unreadable forever. The kit is offered as a file to save and as a printable
  page; it is never uploaded anywhere.
- **Phase 2.** A second copy via `restic copy` to an external disk, S3/B2, or
  another restic repository, scheduled independently. Credentials for the second
  copy never reach a VPS.

---

## 13. Coolify support

Coolify v4 is detected by `/data/coolify`, by the `coolify`, `coolify-db`,
`coolify-proxy` containers, and confirmed by `GET /api/v1/version`.

### 13.1 Verified from source, release `v4.3.23`

Container labels, read from `bootstrap/helpers/docker.php` on `main` — discovery
can rely on these even with no API token:

```
coolify.managed            coolify.type              coolify.name
coolify.projectName        coolify.environmentName   coolify.resourceName
coolify.applicationId      coolify.applicationUuid
coolify.databaseUuid       coolify.database.subType
coolify.serviceName        coolify.service.subId     coolify.service.subType
coolify.service.subUuid    coolify.service.subName
coolify.pullRequestId      coolify.version
```

API: prefix `/api/v1`, Sanctum bearer token with `read` / `write` abilities.
Hindsight requires **read** only, and the onboarding text says so. Endpoints
that matter here, all `GET`: `/version`, `/projects`, `/projects/{uuid}`,
`/applications`, `/applications/{uuid}`, `/applications/{uuid}/envs`,
`/applications/{uuid}/storages`, `/databases`, `/databases/{uuid}`,
`/databases/{uuid}/envs`, `/databases/{uuid}/storages`, `/services`,
`/services/{uuid}`, `/services/{uuid}/databases`,
`/services/{uuid}/applications`, `/services/{uuid}/storages`, `/servers`,
`/servers/{uuid}/resources`, `/servers/{uuid}/proxy`.

`/{applications,databases,services}/{uuid}/storages` is the authoritative source
for a resource's persistent volumes and bind mounts, which is exactly what
per-resource capture needs.

Known from Coolify's own documentation: `APP_KEY` in Coolify's environment file
at `/data/coolify/source/` encrypts the credentials and private keys stored in
Coolify's database. Without it a restored `coolify-db` is useless. Hindsight
treats that file as the single most important object it captures and verifies its
presence in every Coolify snapshot.

### 13.2 To verify in the test VM before implementation (Milestone 10)

Marked explicitly unverified, because the brief's recollection and mine are not
evidence:

- exact layout of `/data/coolify/{applications,services,databases}/<uuid>` and
  which files there are authoritative versus regenerated;
- `/data/coolify/{ssh,proxy,backups,source,database}` contents, and which are
  state versus derived;
- `coolify-db` container name, Postgres role and database names, and whether
  `pg_dump` must run as a specific user;
- volume naming conventions, and whether volumes are always Docker named volumes
  or sometimes host binds;
- Coolify's own DB schema for the read-only fallback path, which is a private
  interface and must be treated as version-fragile;
- proxy flavor and label scheme (Traefik versus Caddy) and what Coolify does
  natively for rolling updates — this gates restore mode 1 (§14).

### 13.3 Per-resource capture

The tree is Project → Environment → Resource (application | service | database),
built from the API when a token exists, from labels otherwise, and from
read-only DB queries as a last resort. Each source is tried in that order and the
UI shows which one produced the tree, because a label-only tree is less complete.

Per resource: Docker volumes and bind mounts, config and compose files under
`/data/coolify/.../<uuid>`, env vars and settings, and a logical dump for
database resources. Every snapshot is tagged `coolify:<resource-uuid>` plus
`coolify-project:<name>` and `coolify-env:<name>`, so a resource's history is a
tag query and survives the resource being renamed or moved.

Coolify itself is a resource too: its environment file under
`/data/coolify/source/`, the `coolify-db` dump, `/data/coolify/ssh`, and
`/data/coolify/proxy`, with a dedicated "restore Coolify instance" flow.

---

## 14. Restore

### 14.1 Wizard

Snapshot → scope (full server | selected paths | Coolify resource) → target
(in place | alternate path | another server) → mode → **dry-run review** →
confirm by typing the hostname.

### 14.2 The diff problem, and the safety snapshot

restic can diff two snapshots but not a snapshot against a live filesystem. The
safety snapshot solves both problems at once:

1. Take a pre-restore snapshot of exactly the paths the restore would touch,
   tagged `safety` and `restore:<id>`.
2. `restic diff <safety-id> <source-id>` yields precisely the files that will be
   added, changed, and removed — a true preview, not an estimate.
3. Show it. Require confirmation.
4. Restore.
5. The safety snapshot remains as the undo path, exempt from retention until the
   user discards it.

For database scopes the dry run lists objects from the dump (`pg_restore -l`, or
the dump's own catalog) against the live database's catalog and names what will
be dropped or replaced. The UI is explicit that row-level differences are not
shown.

### 14.3 Mode availability

The planner computes availability from facts, and the UI states which modes are
possible **and why the others are not** — e.g. "Minimal downtime unavailable:
this resource uses a bind mount under `/data` on the same filesystem as the live
path, so an atomic rename is not possible."

1. **Zero-downtime (blue/green) — researched, and not offered.** Coolify's own
   `rolling_update()` is real blue/green, but it replaces the *container*, not
   the data: the new container is generated from the same compose file and
   mounts the same named volume as the old one, because the volume list comes
   from Coolify's database. Restoring data without interruption would mean
   repointing the resource at a new volume, and only Coolify's own database can
   do that — which Hindsight will not write to.

   So the mode is described in the UI and marked unavailable, with that reason,
   rather than hidden or faked. Overwriting a shared volume beneath a running
   application while calling it zero downtime would be exactly the dishonest
   case the brief rules out. Full reasoning and sources in `docs/COOLIFY.md`
   §9. If Coolify later exposes volume rewiring through its API, this becomes
   possible and should be revisited.
2. **Minimal downtime.** Stage restored data beside the live data on the same
   filesystem, then stop, swap with `rename(2)`, start. Downtime is the stop and
   start, shown as an estimate derived from the container's observed start time.
   Requires same-filesystem staging space.
3. **Standard.** Stop, restore, start. Always available.

Alongside the modes, the **clone** target restores into a new volume under a new
name. It touches nothing live, which makes it the honest answer to "I want to
look at this data without risking the running copy" — the need zero-downtime
restore was reached for.

### 14.4 Hard exclusions

Full-server in-place restores never write `/boot`, `/etc/fstab`, network
configuration (`/etc/netplan`, `/etc/NetworkManager`, `/etc/systemd/network`,
`/etc/network`), `/etc/ssh/ssh_host_*`, or the SSH user's `authorized_keys`,
unless the user explicitly opts in per category with a separate confirmation.
Beyond that, a final guard refuses any restore plan that would overwrite the
`authorized_keys` entry or sshd configuration Hindsight itself connects
through — locking Hindsight out of a server mid-restore is the one failure that
prevents its own repair.

---

## 15. UI

SwiftUI, `NavigationSplitView`, light and dark, SF Symbols, full keyboard
access, accessibility labels on every control and on the timeline. Calm by
default: color is reserved for states that need attention.

- **Sidebar** — servers with health dots derived from last-backup age and last
  check result; Coolify servers disclose into their resource tree.
- **Server view** — a scrubbable Time Machine-style snapshot timeline, a
  size-and-dedup-savings chart, schedule status, next run, recent activity.
- **Snapshot browser** — lazily loaded file tree, search, Quick Look for text
  and images, diff between any two snapshots, restore of a single file or folder.
- **Coolify tab** — Project → Environment → Resource tree with per-resource last
  backup, history, and per-resource backup and restore actions.
- **Settings** — connection, schedule, retention, include/exclude rules,
  bandwidth limit, repository location, Coolify token, integrity-check rotation.
- **Activity log** — live progress with bytes scanned, bytes new, ETA; errors
  are copyable in full, with the exact failing command, secrets redacted.
- **Onboarding** — add server, verify host key fingerprint, detect sudo, Coolify
  and OS, choose the repository location (external volumes first, free space
  shown), run the first backup, export the recovery kit. The kit step cannot be
  skipped.

Progress arrives as XPC events, so the UI never polls, and a closed window costs
nothing because the agent owns the work.

---

## 16. Testing

**Unit** (`swift test`, no containers): cron and cadence math, catch-up and
power policies, GFS retention math, catalog migrations and queries, restic
`--json` decoding against recorded fixtures, Coolify label and API parsing
against recorded fixtures, restore planning — scope resolution, mode
availability, exclusion enforcement, diff interpretation.

**Integration** (`make test-integration`, starts and stops its environment):

- `docker compose` with an Ubuntu container running sshd, a Postgres container,
  and a MySQL container, each seeded with a known dataset and carrying
  `/etc/hindsight-test-target`.
- An OrbStack VM running Coolify with a couple of sample resources, for the
  Coolify and blue/green tests. OrbStack is already present on this machine;
  Lima is the documented fallback.

Scenarios: full cycle (backup → mutate → incremental, asserting the second
backup adds only a small fraction of new data → restore in each mode →
checksum comparison against the original); corrupt a pack file in a throwaway
repository and assert `check` and `check --read-data-subset` detect it;
append-only enforcement (a delete through rest-server is refused, a lock delete
is permitted, matching §7); host-key change is a hard failure; stale-lock
recovery; disk-space refusal.

**The destructive-operation guard.** Every write or restore path takes a
`DestructiveOperationPolicy`. In the app the policy is "the user typed the
hostname". In tests the only policy available is `.localTestTargetOnly`, which
admits a target when **both** hold:

1. the address is `127.0.0.1`, `::1`, `localhost`, or within a Docker/OrbStack
   range; **and**
2. `test -f /etc/hindsight-test-target` succeeds on the target.

Integration tests additionally require `HINDSIGHT_ALLOW_DESTRUCTIVE_TESTS=1`,
and the restore suite fails — not skips — if the guard proves constructible for a
non-local host. Tests prove the guard rejects a public address, rejects a
loopback target missing the marker, and admits a marked local target. A separate
check asserts that no test can read the user's real `~/.ssh/config` or
Hindsight's production configuration.

`make test` runs unit tests. `make test-integration` brings the environment up,
runs the rest, and tears it down even on failure.

---

## 17. Build and distribution

- `Package.swift` at the root for all modules; `swift test` is the headless path.
- `App/project.yml` plus XcodeGen generates the app project, because a
  hand-maintained `project.pbxproj` is unreviewable in diffs and merge-hostile.
  XcodeGen is a build-time tool only, not a runtime dependency; the generated
  `project.pbxproj` is git-ignored.
- `make vendor` fetches and verifies the pinned binaries (§6.4).
- Signing: Developer ID Application, hardened runtime, notarized, with the agent
  embedded in `Contents/Library/LaunchAgents`. The app and agent share a team
  identifier and keychain access group; XPC peers are pinned to it.
- `make test`, `make test-integration`, `make lint`, `make app`.

---

## 18. Where this differs from the brief

Everything below is a deliberate deviation or a correction based on evidence,
not a preference.

1. **Append-only does not prevent lock deletion.** rest-server's enforcement
   exempts `locks/` (`repo/repo.go`: `if h.opt.AppendOnly && objectType !=
   "locks"`). A compromised VPS therefore cannot destroy snapshots but can
   delete locks, which is a denial of service. The brief's stronger claim needed
   narrowing, and §7 states the real boundary. Stale-lock detection and local
   `restic unlock` are in the design because of this.
2. **A compromised VPS can read its own backup history.** It holds the
   repository password while a job runs, and restic has no write-only key. The
   brief did not state this; the UI must not imply isolation it does not have.
3. **darwin restic binaries are bundled too.** The brief mentions only linux
   amd64/arm64. Maintenance, diffing, and restore staging run on the Mac, so
   `darwin_amd64` and `darwin_arm64` ship as well.
4. **`ionice` is optional.** It is absent from many minimal images. Its absence
   degrades to `nice` instead of failing the job.
5. **Retention is computed twice, with restic as the authority.** A local GFS
   engine is needed to preview deletions, but divergence between two
   implementations is a real risk, so the number shown to the user comes from
   `restic forget --dry-run --json` when the repository is reachable, and the
   local engine is validated against it in tests.
6. **Database volumes are still backed up, and labeled crash-consistent.** The
   brief implies logical dumps replace file copies. Keeping both costs little
   after dedup and preserves configuration; the restore planner prefers the dump
   for database scopes and the UI names the difference.
7. **Dump snapshots get their own retention scope.** A file-oriented policy
   would otherwise silently expire database dumps on a cadence users do not
   expect.
8. **The app cannot be sandboxed**, so it cannot ship on the Mac App Store.
   Direct notarized distribution is the consequence.
9. **The menu bar extra belongs to the app, not the agent.** A LaunchAgent is
   not a UI agent, so quitting the app removes its menu bar item while backups
   continue (decided in §19). The item means "the UI is running" and never
   implies anything about whether backups are scheduled.
10. **Coolify facts are now sourced, not remembered.** Labels and API surface
    were read from Coolify `v4.3.23` and are listed in §13.1. Everything about
    `/data/coolify` internals, container and role names, and the DB schema
    remains explicitly unverified until Milestone 10, and §13.2 lists exactly
    what will be checked.
11. **Pinned versions are current as of today**: restic 0.19.1 (2026-07-05),
    rest-server 0.14.0 (2025-05-31), checked against Coolify v4.3.23.

---

## 19. Decisions

Resolved, 2026-10-04.

1. **Xcode project generation** — XcodeGen from a checked-in `App/project.yml`.
   XcodeGen is a developer prerequisite (`brew install xcodegen`); `make app`
   fails with install instructions if it is missing. `project.pbxproj` is
   generated and git-ignored.
2. **Menu bar when the app is quit** — no menu bar item. Quitting the app
   removes it; the agent keeps running and backups continue. The menu bar item
   therefore means "the UI is running", and the agent's state is never inferred
   from its presence. Onboarding says this once, plainly.
3. **Repository location** — asked during onboarding, with external and
   network-capable volumes listed first, free space shown per volume, and
   `~/Library/Application Support/Hindsight/repos/` offered as the fallback.
   Changing it later moves existing repositories rather than orphaning them.
4. **Signing** — Developer ID Application, hardened runtime, notarized. `make
   app` signs with the identity from `HINDSIGHT_SIGNING_IDENTITY`, falling back
   to ad-hoc only for local unsigned test builds, which cannot register a
   LaunchAgent and say so.


---

## 20. What is built, and what is not yet wired

The engine is complete and verified against real servers. The app is a working
shell over it, and some of the wiring between the two is still missing. Stated
plainly here rather than left to be discovered.

**Working end to end, with tests against real targets**

- Backups: SSH transport, host-key pinning, append-only rest-server over a
  reverse tunnel, live progress, metadata snapshots, incremental verification.
- Retention and integrity: a policy engine that agrees with restic exactly,
  prune, check, the read-data rotation, corruption detection.
- Restore: planning, mode availability with reasons, safety snapshot, exact
  preview, byte-for-byte restore, undo, staged swap, hard exclusions.
- Database dumps: detection, logical dumps streamed into restic, failure
  reporting.
- Coolify: discovery from labels and from the API, agreeing on the same
  install; the instance plan checked against a live install.
- Second copy, scheduling, the catalog, the Keychain, and the agent's XPC
  surface.

**Built and tested, but not yet called from a running app**

| Piece | State |
|---|---|
| Database dumps in a scheduled backup | `DatabaseBackup` works and is tested; `BackupEngine.run` does not yet call it, so a scheduled backup captures files and metadata but not dumps. |
| Maintenance scheduling | `MaintenanceEngine` works; the agent answers `runMaintenance` and `checkIntegrity` with "not available yet" rather than pretending. |
| Restore from the interface | The planner, executor and wizard all exist and are tested; there is no XPC request that runs a restore, so restores are not yet reachable from the app. |
| Per-resource Coolify backup | Discovery and tagging work; no job yet backs up a single resource. |
| Snapshot browser in the app | The tree, search and diff logic are tested; the app does not yet feed them from `restic ls`. |
| Settings persistence | The settings form is built; its bindings are not yet written to the catalog. |
| Onboarding actions | The state machine is tested; the app does not yet implement the per-step actions behind it. |
| Notifications | Not implemented. |
| Recovery kit export from the UI | The kit is generated and tested; the save dialog is not wired. |

None of this is hidden behind a stub that reports success. Where a path is not
implemented, it says so.
