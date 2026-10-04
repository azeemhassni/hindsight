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

## M11 — Restore

- A planner that decides which modes are possible from facts, and explains
  every mode whether or not it is available — naming the actual obstacle, not
  a generic refusal. Only zero downtime ever carries a data-loss caveat.
- The pre-restore safety snapshot, which is both the preview's baseline (restic
  can diff two snapshots but not a snapshot against a live filesystem) and the
  way back. Proven: restoring it returns exactly what the restore overwrote.
- Hard exclusions by category with per-category opt-in, plus one rule with no
  opt-in at all: a restore may never overwrite the key Hindsight logs in with.
- Verified against the local container: a restore returns changed and deleted
  files byte for byte with permissions intact, the staged swap completes in
  well under a second, an alternate-path restore leaves the live copy alone,
  and a plan that would cut off access is refused before anything is written.

## M12 — The blue/green research, and what it changed

- Read Coolify's `rolling_update()`: it is real blue/green for applications,
  but it replaces the container, not the data — the new container mounts the
  same named volume, because the volume list comes from Coolify's database.
- Zero-downtime **data** restore would therefore require writing to Coolify's
  private database. Hindsight will not, so the mode is not offered. It stays
  visible in the UI, marked unavailable, with that reason given.
- A test now sweeps every scope and target combination to prove nothing is ever
  reported as zero downtime, and the `clone` target gives the honest answer to
  the need behind it: a parallel copy that touches nothing live.

## M7 / M8 — Interface, onboarding, and the snapshot browser

- The interface lives in a `HindsightUI` package module rather than only in the
  app, so every view compiles under `swift test` instead of only inside Xcode.
  The app target is a thin shell: window, menu bar item, XPC connection.
- Sidebar with health carried by symbol, label and spoken description as well
  as colour; server view with a scrubbable history whose bars track what each
  snapshot added; activity log whose errors are selectable and copyable in full.
- Snapshot browser that loads one directory at a time, searches by name, and
  knows which files are worth a Quick Look.
- Restore wizard that shows every mode including the unavailable ones with
  their reasons, previews the exact changes, and needs the hostname typed.
- Onboarding as a tested state machine. The recovery kit step cannot be
  skipped, and the kit itself carries literal commands that work with stock
  restic and no Hindsight at all.
- `make app` generates the Xcode project with XcodeGen, verifies the pinned
  binary digests, and embeds the agent, its job description and all six
  binaries in the bundle.

## M13 — Second copy

- `restic copy` into another disk, S3, Backblaze B2, or another rest-server,
  initialised with `--copy-chunker-params` so the copy deduplicates against the
  original instead of re-chunking it.
- The copy keeps its own password: losing the Mac should not hand over the
  second copy along with the first. Proven — the source password does not open
  the copy.
- Credentials travel in the environment and never reach a server, so a
  compromised machine cannot touch the copy that outlives it.
- Verified locally: every snapshot arrives, the copy passes its own integrity
  check, and copying again adds nothing.

## Running the app for the first time

Launching the real app found four bugs that no test had caught, because none of
them appear until SwiftUI actually lays out a window on macOS 14:

- `ContentUnavailableView` as a row inside a `List` crashes the layout. It is
  the empty state the sidebar shows before any data arrives, so the app crashed
  every launch.
- `safeAreaInset` attached to a `NavigationSplitView` crashes it too; the
  connection banner now sits at the top of the detail column.
- Wrapping a `NavigationSplitView` in a `VStack` collapses it to the sidebar's
  width — a window that opens but shows nothing.
- The XPC error handler was formed in a `@MainActor` context, so Swift 6's
  isolation check trapped when XPC invoked it on its own queue. Before the
  handler existed at all, a request to an absent agent leaked its continuation
  and hung the caller forever instead.

The app also now falls back to the catalog when the agent cannot be reached, so
a window shows the history it knows rather than nothing, and
`HINDSIGHT_CATALOG_PATH` lets the interface be run against a catalog other than
the installed one. `hindsight-demo-catalog` writes a catalog with plausible
history for exactly that.

## Wiring it all together

Everything the engine could do is now reachable:

- Scheduled backups dump every database they find, each into its own tagged
  snapshot, and a dump that fails becomes a warning on an otherwise good
  backup rather than a silent omission.
- Maintenance runs on its own half-hourly sweep: retention and pruning daily,
  one slice of the read-data rotation weekly, with the rotation advancing only
  on success so a failed slice is retried rather than skipped.
- Restore is reachable from the window. The preview takes the safety snapshot
  and is fetched under the server's real hostname, the confirm button needs the
  hostname typed, and the **agent** re-checks it rather than trusting the app.
- Per-resource Coolify backup captures volumes at their real location on disk,
  the generated compose file, and a logical dump for database resources.
- Settings save as a sparse update, so opening the form cannot reset a field
  somebody set elsewhere, and a stored Coolify token is never read back into a
  text field just to display it.
- Onboarding, the snapshot browser, notifications and the recovery kit are all
  connected.

Two bugs the wiring exposed: a server id derived from a name could collide with
an existing one and overwrite that server, and making the tunnel's session body
`@Sendable` revealed mutable state being shared across an isolation boundary in
the backup engine.

The slow tests were trimmed as promised: the retention corpus is built once per
suite rather than per test, and the progress fixture is 200 MB instead of 600.
The retention suite went from 128 seconds to 67.

## The window, finished

Everything the brief asks for can now be done from the app: onboard a server,
onboard or back up a single Coolify application or database, read a run's log
in full, and restore — a whole snapshot, one path out of it, or one Coolify
resource.

- The server's view is five parts: Overview, Snapshots, Coolify, Logs,
  Settings, with `⌘1`–`⌘5` to move between them.
- **Adding a server** is a sheet over the window, wired to the agent step by
  step: the host key's fingerprint to compare, an access check with the
  sudoers line to paste, what the probe found, where the repository goes, the
  first backup, and the recovery kit. The kit cannot be stepped over, closing
  the sheet before saving it asks again, and a server without one keeps a
  banner in its own view.
- **Coolify** resources are discovered by the agent over ssh, cached in the
  catalog, and shown with where the list came from — so a label-only list says
  plainly that it cannot see stopped resources. Each resource can be backed up
  on its own; the resource list is read off the server again first, because a
  redeploy moves volumes.
- **Logs** show every run with its state, duration and bytes, and the chosen
  run's log in full, copyable, filterable by level.
- **Settings** are read back from the agent before the form opens, so saving
  cannot overwrite what is in force with defaults. The bandwidth limit the form
  offered now actually reaches restic.
- **Snapshots** lists every snapshot and browses the chosen one a directory at
  a time, with Quick Look and single-path restore.

Four bugs found by running it rather than by reading it:

- A Keychain read on the main actor froze the window — it disappeared from the
  accessibility tree while the process sat there alive. The same call on the
  agent's actor stopped the agent answering anything at all, so the window sat
  on "Connecting…" while every subsystem underneath was healthy. Both now run
  off their actors, with a test that blocks a secret store on purpose.
- The window's closures capture the `App` struct as it was when `body` ran, so
  a `@State` value set afterwards is invisible to them: the snapshot list came
  up empty with the catalog open. The catalog lives in an object now.
- Jobs left `running` by a stopped agent stayed that way for ever.
- Embedded panes were setting the window's title and search field; one of them
  renamed the window to "Activity".

`HINDSIGHT_SSH_LOCAL_ONLY=1` pins a release build to local targets, which is
what a development agent needs: a catalog of example servers must not be able
to reach for them.

## Signed, installed, and the faults that only showed then

Signed with the Developer ID for team `SM26HBBKRL`, hardened runtime, installed
in `/Applications`. The app registers the agent with `SMAppService`, launchd
keeps it alive, each end pins the other by code signature, and a backup of the
local test container lands in the repository chosen during onboarding. That was
the last item in the architecture's "unproven" list.

Two structural changes made it work:

- **Only the agent touches secrets.** The app no longer links the Keychain
  module; it asks the agent to list a snapshot's files, extract one for Quick
  Look, or assemble a recovery kit. Sharing Keychain items between processes
  needs an entitlement, a provisioning profile and an App ID capability — one
  process needs none of them, and a window that holds no passwords is a better
  thing to have anyway.
- **The agent is a nested background app bundle.** `UNUserNotificationCenter`
  asserts in a process without one, and launchd restarted the agent in a loop
  until it had a bundle of its own.

Six faults a real install exposed, each now covered by a test:

- The managed ssh config did not quote its values, and the install path
  contains a space — so ssh read `/Users/you/Library/Application`, found no
  `known_hosts`, and called every host key unknown. Test directories now
  contain spaces for this reason.
- A failed access probe recorded "passwordless sudo is not available" — a claim
  about sudo it had learned nothing about — and never asked again, because the
  retry button only appeared for non-root users.
- Backups were written under Application Support while prune, check and restore
  used the location chosen during onboarding. The plan takes the repository
  from the catalog now.
- A server added after onboarding had no ssh config stanza, so every job for it
  failed with "could not resolve hostname". The config is written before every
  job.
- A failure before the backup engine started left the job saying "running" for
  ever; every path now records its outcome.
- launchd kept running the old agent out of a replaced bundle. The app compares
  code hashes and asks a stale agent to exit.

Also: ssh's "host key verification failed" is now read as three different
things — a changed key, a key that was never recorded, and a refusal with no
evidence either way — rather than warning about interception when nothing had
been recorded. And a Keychain refusal explains that the item belongs to a
differently signed build instead of printing a status code.

## Tooltips on every button

Every button in the window now says what it does on hover, and the ones worth
having most are on the disabled ones: `Continue` in the add-a-server sheet
carries whatever is still missing, `Review changes` says "Choose a snapshot
first", `Restore` says "Type the server's hostname to confirm", and `Save` in
settings carries the reason it cannot be saved. Unavailable restore modes
explain on hover why they are unavailable rather than only in the row.

`scripts/tooltip-audit.swift` walks the running app's accessibility tree and
reports any button without one, so this does not quietly rot. Menu items and
alert buttons are not listed: macOS never shows a tooltip for either, and their
titles are already visible.

## The window resizes like a window

It did not: it opened 2151 points tall on a 1072-point screen and refused every
vertical resize — asking for 200 points or 3000 both left it at 2151.

The cause took measuring to find, and it was not where it looked. Every banner
and caption used `.fixedSize(horizontal: false, vertical: true)`, which means
"never truncate this text vertically". When SwiftUI works out a view's
*minimum* size it proposes a near-zero width, and at that width those strings
wrapped into a column one word wide — about two thousand points tall. The
window scene turned that into the window's minimum height, so the window was
born taller than the screen and could never shrink.

Each of those texts now has a line limit, and the window:

- opens at 1040 × 700,
- shrinks to 647 × 286 and grows to fill the screen,
- lays its content out at exactly the window's size.

`windowResizability` is `.contentMinSize`, so there is a floor and no ceiling.
`WindowFloor` sets the minimum and clamps to the screen in AppKit rather than
with a SwiftUI frame — a frame on the `NavigationSplitView` breaks its layout
outright, leaving a toolbar above an empty rectangle. `WindowGeometryParsing`
throws away remembered geometry that no longer fits the screen, because macOS
restores a split view's saved frames and a window saved at 2109 points would
otherwise open that way for ever.

Two tabs — Snapshots and Logs — still ask for about 1000 points of width before
they will shrink further, because of what their split panes hold; the window
grows to meet them when you switch to one while very small.

## An icon, and a notarised build

The icon is a rear-view mirror: the name is the picture, and inside the glass
three racks recede toward a vanishing point with the nearest one lit. The first
attempt was a circular arrow around a server rack, which is what every other
backup app ships. It is drawn by `scripts/make-icon.swift` rather than stored
as artwork, so it can be changed in one place and re-rendered at every size —
and it simplifies below 64 points, where three bars and their status lights
turn into a grey smudge.

The app is **notarised and stapled**. Gatekeeper now reports
`source=Notarized Developer ID` where it used to say `Unnotarized`. Two things
had to be fixed before Apple would take it:

- The signature carried no secure timestamp, which notarisation refuses.
- The vendored `restic` and `rest-server` binaries inside the bundle were not
  signed. Every Mach-O in an app has to carry its own signature with the
  hardened runtime; the Linux binaries are data here and are left alone.

Signing those rewrites them, so their pinned upstream digests can no longer
match — and the runtime check that compares them had to change. Inside a sealed
bundle a binary is now trusted on the bundle's signature, which macOS checks
before the code runs. Everywhere else, including every binary that travels to a
server, the digest pin stands exactly as it did; there are tests for each case.

`make notarize` builds, verifies, submits, waits, staples and asks Gatekeeper
for its verdict. It reuses any notarytool keychain profile on the machine, so
the password is not asked for again.
