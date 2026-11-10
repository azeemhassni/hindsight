# Hindsight

A Time Machine for VPSes: a native macOS app that backs up Linux servers over
SSH into incremental, deduplicated, encrypted, verifiable repositories on your
Mac, and restores them.

Backups are **pushed** by the server into a repository on the Mac, through a
reverse SSH tunnel to a bundled [rest-server] running in **append-only** mode.
A server that is compromised can add to its own history; it cannot rewrite or
delete it. Chunking, deduplication, compression and encryption are
[restic]'s — Hindsight invents no formats of its own, so a repository stays
readable with the `restic` binary alone and the password from your recovery
kit, with or without this app.

Databases are not copied as files: Postgres, MySQL, MariaDB, MongoDB and Redis
are found on the host and inside Docker containers, and each gets a logical
dump — `pg_dump`, `mysqldump` and their equivalents — run over SSH alongside
the filesystem backup, stored as its own snapshot with its own history.

## Status

Honest version, because this is backup software and the failure mode is
finding out later.

**Exercised against real servers.** Backing up, scheduling, retention,
pruning, integrity checks, database dumps, and browsing a snapshot's files.
These run nightly against production machines and have been for weeks.

**Built and unit-tested, but never run against a real machine.** Restoring onto
a different server, loading a database dump back into a live database, and the
replica seed image. The code paths are covered by tests, and the repository's
own rules keep automated tests away from anything but local containers — which
means nobody has yet watched these work on a real server. Treat them as
unproven and verify on something you can afford to lose.

**Unverified on a Mac without an Apple Developer account.** Whether a
self-built, ad-hoc signed app can register its background agent with
`SMAppService`. It builds and the signature verifies; what happens at
registration has only been seen with a Developer ID. If it refuses, the window
says so rather than failing silently — please open an issue with what it said.

## Requirements

- macOS 14 or later
- Xcode 16 or later (for the Swift 6 toolchain)
- [XcodeGen] — `brew install xcodegen`

No Apple Developer account is needed to build and run it yourself.

## Building

```bash
make vendor && make test && make app
```

- `make vendor` downloads restic and rest-server and verifies each against a
  digest pinned in `vendor/checksums.txt`. Nothing is taken on trust.
- `make test` runs the suite. The ones that need containers skip themselves
  when Docker is not up.
- `make app` generates the Xcode project and builds `Hindsight.app`.

Then copy it in and launch it:

```bash
cp -R ~/Library/Developer/Xcode/DerivedData/Hindsight-*/Build/Products/Release/Hindsight.app /Applications/
open /Applications/Hindsight.app
```

On first launch it registers its background agent with `SMAppService`. macOS
may ask you to allow it in Login Items, and the window says so until you do —
backups do not run before that.

### Signing

`make app` signs **ad hoc** by default. That is a real signature with no
certificate behind it: enough to run on the Mac that built it, and it needs no
Apple Developer account. Nothing in the source names a signing team — the XPC
requirement between app and agent is built from whatever identity signed the
running binary, so each build pins itself to itself.

To sign with a Developer ID instead, which you need only for a build that will
run on a Mac other than the one that built it:

```bash
make app HINDSIGHT_TEAM_ID=ABCDE12345
```

Switching between the two needs a clean build — Xcode keeps the previous
signature on nested bundles and the build then fails complaining that an
embedded binary does not match its parent:

```bash
rm -rf ~/Library/Developer/Xcode/DerivedData/Hindsight-*/Build
```

**Notarisation is not provided and not wanted.** This project does not
distribute binaries; you build it yourself, and an ad-hoc build on your own Mac
needs no notarisation. `make notarize` exists for anyone who wants to
distribute their own build under their own Developer ID, and needs their own
Apple account and notarytool profile. Nobody else's identity is in this
repository.

### What a local install means

- **The agent is the only process that reads a secret.** The app asks it to
  list a snapshot, extract a file or assemble a recovery kit, so the window
  holds no passwords at all.
- **Keychain items belong to the signature that created them.** One stored by a
  differently signed build is refused, and Hindsight says so: remove it from
  Keychain Access and let the agent store it again from the recovery kit. This
  bites when you switch between an ad-hoc and a Developer ID build.
- **Export the recovery kit, and keep it somewhere other than the repository.**
  It holds the password without which the backups are unreadable. The app will
  nag you until you have saved one.

## Testing

| Command | What it runs |
|---|---|
| `make test` | Everything that needs no server, plus the local Docker suites if the environment is up |
| `make test-integration` | Starts the Docker environment, runs the suite, tears it down |

`make test-integration` fails if its environment is not actually up, rather
than skipping every test and reporting success — a skipped test and a passing
one look identical in a summary line.

Restore and write tests only ever touch local targets. The guard is in the
code, not the convention: a destructive operation in a test requires both a
local address **and** the file `/etc/hindsight-test-target` on the target, and
there is a test that proves the guard refuses everything else.

## Documentation

- [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) — how it works and why
- [docs/DECISIONS.md](docs/DECISIONS.md) — decisions taken and the reasoning
- [docs/CHANGELOG.md](docs/CHANGELOG.md) — what changed, and what it cost
- [docs/PLAN.md](docs/PLAN.md) — the milestones it was built against
- [CONTRIBUTING.md](CONTRIBUTING.md) — how to work on it
- [SECURITY.md](SECURITY.md) — reporting a vulnerability

## Licence

Apache License 2.0 — see [LICENSE](LICENSE) and [NOTICE](NOTICE).

Hindsight bundles [restic] and [rest-server], both BSD-2-Clause, downloaded at
build time and verified against digests pinned in `vendor/checksums.txt`.

[restic]: https://restic.net
[rest-server]: https://github.com/restic/rest-server
[XcodeGen]: https://github.com/yonaskolb/XcodeGen
