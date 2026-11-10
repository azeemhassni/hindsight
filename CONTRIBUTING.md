# Contributing

Thanks for looking. A few things about this repository that are not obvious
from the outside.

## The rules this code is held to

`CLAUDE.md` is the working agreement for the project and applies to everyone,
not only to the assistant it is addressed to. The ones that will get a patch
sent back:

- **Never run a restore, or any write or destructive command, against a real
  server.** Not yours, not a staging box you own. Restore and write testing
  happens against local Docker containers, or a local VM where Docker cannot
  do the job. This is enforced in code: a destructive operation in a test
  needs both a local address and the file `/etc/hindsight-test-target` on the
  target, and a test proves the guard refuses everything else.
- **Do not invent chunking, dedup or encryption formats.** restic owns the
  repository format. A repository must stay readable by the `restic` binary
  alone, so that losing this app is not losing the backups.
- **Never claim a guarantee the code cannot keep.** No "zero downtime" where
  there is downtime, no reporting a backup as succeeded when it wrote nothing.
  Most of the bugs in `docs/CHANGELOG.md` are variations on this.
- **Secrets live in the Keychain.** Never in files, never in `UserDefaults`,
  never in logs, never in a process's `argv`.

## Getting set up

```bash
make vendor    # pinned restic and rest-server, verified against their digests
make test      # the suite
make app       # the app, signed ad hoc
```

`make test` runs everything that needs no server. The container suites skip
themselves when Docker is not running; `make test-integration` starts the
environment, runs them and tears it down, and fails rather than skipping if
the environment is not actually up.

## Shape of the code

Core logic lives in Swift package modules so it is testable without the app —
`swift test` covers the engine, the catalog, the SSH layer and the interface
model. `App/` is the thin SwiftUI shell plus the agent executable, generated
with XcodeGen from `App/project.yml`.

The split that matters: **the agent owns the secrets and the catalog, the app
is a client.** Closing the window must not stop a backup, and two processes
writing one SQLite file is a bug waiting to happen. If a change has the app
reading a repository password, it is going the wrong way.

`docs/ARCHITECTURE.md` is the long version and is kept current.

## Tests

Prefer a test against something real — a container, a repository on disk, the
actual `restic` binary — over a mock. Several of the worst bugs in this project
passed their unit tests: a dump that reported success while writing nothing, a
retention policy that silently shared one history across six databases. Both
were found by measuring the real thing.

When you fix a bug, the test should fail without the fix for the original
reason, not an adjacent one.

## Commits

Short, imperative, one line: `add restic tunnel transport`. No bodies unless
genuinely necessary. Explain in the pull request instead.

Comments explain non-obvious **why**, never **what**. If a line needs a comment
to say what it does, rename something instead.

## Pull requests

Say what you changed, how you verified it, and what you did not verify. The
last part is the useful one — this is backup software, and "I did not test the
restore path on a real machine" is information, not an admission.
