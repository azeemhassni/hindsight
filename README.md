# Hindsight

A Time Machine for VPSes: a native macOS app that backs up Linux servers over
SSH into incremental, deduplicated, encrypted, verifiable repositories on your
Mac, and restores them.

Backups are **pushed** by the server into a repository on the Mac, through a
reverse SSH tunnel to a bundled [rest-server] running in **append-only** mode.
A server that is compromised can add to its own history; it cannot rewrite or
delete it. Chunking, deduplication, compression and encryption are
[restic]'s — Hindsight invents no formats of its own.

Servers running [Coolify] get first-class treatment: the project → environment
→ resource tree, per-resource backup and restore, and an instance backup that
captures the pieces a Coolify rebuild cannot do without.

## State

Working engine and interface, with 443 tests — most of them against real
servers in Docker and a real Coolify install in a local VM rather than against
mocks. Onboarding a server, backing up a Coolify application or database,
reading a run's log and restoring are all done from the window. See
`docs/PLAN.md` for what each milestone delivered and `docs/CHANGELOG.md` for
the running log.

## Getting started

```sh
make vendor     # fetch and verify the pinned restic and rest-server binaries
make test       # unit tests and local integration tests
make app        # generate the Xcode project and build Hindsight.app
```

`make app` needs [XcodeGen] (`brew install xcodegen`). Set
`HINDSIGHT_SIGNING_IDENTITY` to sign with your Developer ID; without it the
build is unsigned and cannot register the background agent.

### Running it before it is signed

The app talks to the agent over XPC, and the agent is normally registered as a
`SMAppService` LaunchAgent — which needs a signed bundle. To drive the real
interface against a real agent before then, run the agent as a development
LaunchAgent:

```sh
swift build -c release --product hindsight-agent
mkdir -p ~/Library/Application\ Support/Hindsight-dev
cat > ~/Library/Application\ Support/Hindsight-dev/agent.json <<JSON
{
  "binaryDirectory": "file://$PWD/vendor/bin/",
  "catalogURL": "file://$HOME/Library/Application%20Support/Hindsight-dev/catalog.sqlite",
  "repositoryRoot": "file://$HOME/Library/Application%20Support/Hindsight-dev/repos/",
  "sshConfigurationDirectory": "file://$HOME/Library/Application%20Support/Hindsight-dev/ssh/"
}
JSON
```

Then a `~/Library/LaunchAgents/app.hindsight.agent.plist` whose `Program` is
`$PWD/.build/release/hindsight-agent`, with `MachServices` →
`app.hindsight.agent`, and these environment variables:

| Variable | Why |
|---|---|
| `HINDSIGHT_AGENT_CONFIG` | points the agent at the scratch configuration above, leaving an installed one alone |
| `HINDSIGHT_SSH_LOCAL_ONLY=1` | pins the policy to local targets, so a catalog of example servers cannot reach for them |

`launchctl bootstrap gui/$UID ~/Library/LaunchAgents/app.hindsight.agent.plist`
registers it, and `launchctl bootout gui/$UID/app.hindsight.agent` removes it.
Launch the app with `HINDSIGHT_CATALOG_PATH` set to the same catalog.

One thing to expect: an unsigned build has no keychain access group, so every
repository password read raises a system access prompt. Backups, restores and
the recovery kit wait on it. Nothing freezes — that work is deliberately off
the main actor and off the agent's actor — but the operation does not finish
until you answer. A signed build with the shared access group does not prompt.

## Testing

| Command | What it runs |
|---|---|
| `make test` | Everything that needs no server, plus the local Docker suites if the environment is up |
| `make test-integration` | Starts the Docker environment, runs the suite, tears it down |
| `make test-coolify` | Provisions a Coolify VM and runs the Coolify suite |

`make test-integration` and `make test-coolify` fail if their environment is
not actually up, rather than skipping every test and reporting success — a
skipped test and a passing one look identical in a summary line.

Restore and write tests only ever touch local targets. The guard is in the
code, not the convention: a destructive operation in a test requires both a
local address **and** the file `/etc/hindsight-test-target` on the target, and
there is a test that proves the guard refuses everything else.

## Documentation

- `docs/ARCHITECTURE.md` — how it works and why
- `docs/PLAN.md` — milestones and their acceptance criteria
- `docs/COOLIFY.md` — Coolify's internals as measured, not as documented
- `docs/DECISIONS.md` — decisions taken, and the open questions
- `docs/CHANGELOG.md` — what each milestone added
- `CLAUDE.md` — the working rules for this repository

## Licences

Hindsight bundles [restic] 0.19.1 and [rest-server] 0.14.0, both BSD-2-Clause,
downloaded at build time and verified against digests pinned in
`vendor/checksums.txt`.

[restic]: https://restic.net
[rest-server]: https://github.com/restic/rest-server
[Coolify]: https://coolify.io
[XcodeGen]: https://github.com/yonaskolb/XcodeGen
