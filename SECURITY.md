# Security

Hindsight holds the credentials to people's servers and the only copy of their
backups. Please treat findings accordingly.

## Reporting a vulnerability

Report privately through GitHub's **Report a vulnerability** button on the
Security tab, which opens a private advisory. Please do not open a public
issue for anything exploitable.

Include what you did, what happened, and what you expected. A proof of concept
against a local container is welcome; please do not test against anybody
else's server.

Expect an acknowledgement within a week. This is a small project with no
security team and no bounty — what it can offer is that reports are taken
seriously and credited in the advisory unless you would rather not be.

## What is in scope

Anything that could lose, corrupt, expose or silently fail to make a backup,
and anything that could let a backed-up server reach beyond what it should:

- A path by which a compromised server could read or destroy repository
  history, rather than only append to it
- Recovering repository contents without the repository password
- A secret reaching a log, a file, `argv`, or the app process
- A restore writing somewhere other than where it was confirmed to write
- The XPC surface accepting a peer it should refuse
- A backup reported as successful that did not capture what it claims

## Design decisions that are deliberate

These are known and intentional. Please read `docs/ARCHITECTURE.md` before
reporting one, though an argument that a decision is wrong is still welcome as
a normal issue.

- **The app is not sandboxed.** It executes `/usr/bin/ssh`, writes
  repositories to volumes the user chooses, and supervises a bundled server
  binary.
- **Bundled binaries are verified by the bundle's signature, not by a pinned
  digest.** Signing rewrites a Mach-O, so the upstream digest cannot match the
  copy that ships. Outside a signed bundle — including every binary that
  travels to a server — the digest pin stands.
- **An ad-hoc build pins no XPC peer.** It has no team identifier to pin to.
  A build signed with a Developer ID pins the app and agent to each other.
- **`rest-server` runs bound to `127.0.0.1` in append-only mode**, reachable by
  the server only through a reverse SSH tunnel, for the duration of a run.
- **Restores require two independent things**: the target's hostname typed out,
  checked in the agent rather than the app, and a single-use token the agent
  issues only after the person has authenticated with Touch ID.
