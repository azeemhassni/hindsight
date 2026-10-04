# Decisions

Running list. Resolved items stay for the record; open items are what I need
from you, batched for the end of the project rather than blocking progress.

## Open — for you

| # | Topic | What I need | What I am doing meanwhile |
|---|---|---|---|
| 1 | Signing identity | Your Developer ID team identifier, and the bundle identifier you want. Both the keychain access group and the XPC code-signing requirement embed the team id, so they cannot be finished without it. | Bundle id `app.hindsight`, team read from `HINDSIGHT_TEAM_ID`, unsigned local builds. An unsigned build cannot register the LaunchAgent, and says so. |
| 2 | Zero-downtime restore | Whether to revisit it if Coolify ever exposes volume rewiring through its API. Today it would require writing to Coolify's private database, which I have refused. | The mode is shown as unavailable with the reason; `clone` covers the underlying need. |
| 3 | Coolify coverage | Only a **database** resource was deployed in the test VM. Application and service labels are inferred from that plus Coolify's source, not observed. Closing it needs Coolify's **web onboarding** completed in the VM first: the `localhost` server has no private key without it, and deployment fails inside Coolify. | Documented as unverified in `docs/COOLIFY.md` §10, with the exact reason and the steps to finish it. I did not create the key row by hand — its column is encrypted with `APP_KEY`, and writing Coolify's private schema is what Hindsight refuses to do elsewhere. |
| 4 | Restoring a Coolify instance | Not yet exercised end to end into a fresh VM. It is the flow that matters most if a Coolify server is lost. | The plan's paths are verified individually against a live install. |
| 5 | Notifications | Whether failures should also mail or push somewhere, or stay local notifications only. | Not implemented yet. |
| 6 | ~~Wiring order~~ | Done. Everything in §20 is wired; what remains unproven is listed there. | — |

## Resolved

| # | Topic | Decision | Date |
|---|---|---|---|
| R1 | Backup engine | restic over a reverse SSH tunnel into a local append-only rest-server. | brief |
| R2 | Xcode project | XcodeGen from a checked-in `App/project.yml`; generated `project.pbxproj` is ignored. | 2026-10-04 |
| R3 | Menu bar when the app is quit | No menu bar item. The agent keeps running; the item means "the UI is running". | 2026-10-04 |
| R4 | Repository location | Asked during onboarding, external volumes first with free space shown. | 2026-10-04 |
| R5 | Signing | Developer ID, hardened runtime, notarized. | 2026-10-04 |
| R6 | Module graph | Targets are added as the milestone that fills them begins, not as empty placeholders. | 2026-10-04 |
| R7 | Executable paths | `Command` stores the executable as a string and requires an absolute path, so a binary is never resolved through `PATH` or the working directory. | 2026-10-04 |
| R8 | Connection-sharing socket name | Our own 10-character token instead of OpenSSH's `%C`, which is 64 characters and overruns the 104-byte socket path limit inside an Application Support path. Falls back to a private `/tmp` directory if the path is still too long. | 2026-10-04 |
| R9 | Secrets to the server | A leading `read` in the remote shell script, with values sent on stdin ahead of any payload. `env VAR=value` would expose them in `ps`, and a temporary file would put them on disk. | 2026-10-04 |
| R10 | Process reads | Event-driven (`DispatchSource`) rather than a thread per stream. Blocking reads deadlock once enough processes run at once, which a background agent will do. | 2026-10-04 |
| R12 | Live progress needs a terminal | Backups run over `ssh -tt`. Verified against restic 0.19.1: with `--json` and no terminal it emits only a final summary, whatever `RESTIC_PROGRESS_FPS` says. The brief assumed `--json` alone was enough. | 2026-10-04 |
| R13 | Line splitting | Breaks on `\r` as well as `\n`, because restic separates progress objects with carriage returns when writing to a terminal. | 2026-10-04 |
| R14 | rest-server credentials | `{SHA}` entries rather than bcrypt: macOS ships no `htpasswd`, and the password is 256 bits of fresh randomness per session, so there is nothing to brute force. | 2026-10-04 |
| R15 | Metadata snapshots | Collected to a tmpfs path and stored as their own tagged snapshot, so nothing lands on the server's disk and the metadata history is queryable on its own. | 2026-10-04 |
| R16 | Stale restic locks | Cleared with `unlock --remove-all` while Hindsight's own file lock is held, which proves no other Hindsight operation is using the repository. Without this an interrupted backup would block the next one for restic's full lock timeout. | 2026-10-04 |
| R17 | Retention semantics | Modelled on restic's own algorithm, read from `internal/data/snapshot_policy.go` at v0.19.1 after two of my assumptions proved wrong: the `keep-within` window is measured from the newest non-future snapshot with an **exclusive** boundary, and restic **also keeps the oldest snapshot** while any bucket still has capacity. Both were caught by the agreement test, not by reading. | 2026-10-04 |
| R18 | Retention grouping | Policies apply per restic group (host plus paths). Database dumps therefore keep their own history per database, which is what you would want, and the engine mirrors the grouping so its preview matches. | 2026-10-04 |
| R19 | Dump pipelines need bash | `set -o pipefail` is how a failing dump piped into restic is caught, and `sh` on most Linux systems is dash, where that command not only fails but exits the shell. The shell is chosen from the server's probed facts, with a status-file fallback where bash is absent. | 2026-10-04 |
| R20 | Redaction can collide with data | Secrets are redacted from output by substring, so a password that is also a substring of legitimate data corrupts what Hindsight parses. Accepted: redaction is the second line of defence for logs, and the first is that secrets travel in environments and never in arguments. Test fixtures use distinctive passwords for this reason. | 2026-10-04 |
| R21 | Coolify resource identity | The Docker Compose project label, falling back to the container name. Coolify writes no uuid among its `coolify.*` labels — the brief and Coolify's own source both suggested `coolify.databaseUuid`, but a deployed resource carries `coolify.databaseId`, a numeric primary key that is not stable across a Coolify restore. | 2026-10-04 |
| R22 | Coolify discovery order | Labels first, API as an enhancement. The API is disabled on a fresh install and answers every request with HTTP 200 and `success: true`, so treating it as the primary path would make an instance look empty. | 2026-10-04 |
| R30 | The Coolify VM is reached over loopback | `127.0.0.1:32222` through OrbStack's own ssh endpoint, with its `<user>@<machine>` user syntax, rather than the machine's private address. The address route dropped mid-session while sshd was healthy inside the VM, and loopback is both stable and unambiguously local to the safety guard. Still a real ssh connection to a real sshd. | 2026-10-04 |
| R23 | Coolify tests run separately | `make test-coolify`. The VM and the Docker environment share one hypervisor, and running both at once makes connections to the VM fail in ways that say nothing about Hindsight. The suite also shares one ssh connection for the same reason. | 2026-10-04 |
| R24 | restic refuses includes and excludes together | Verified against 0.19.1: "exclude and include patterns are mutually exclusive". A whole-server restore therefore uses excludes, a selection uses includes, and a selection that *contains* something excluded is refused with an explanation rather than silently restoring it. Selecting `/etc` or `/root` hits this. | 2026-10-04 |
| R25 | No `--delete` on restore | restic would remove anything in the target that is not in the snapshot. For a selection that is a far wider blast radius than asked for, so files the snapshot does not contain are reported as removals in the preview and left in place. | 2026-10-04 |
| R26 | Minimal downtime is two renames, not one atomic swap | Linux has no atomic directory exchange available through coreutils. The service is stopped around the renames instead, so nothing can observe a half-swapped directory; the transfer still happens while the service is up, which is where the time goes. | 2026-10-04 |
| R27 | Zero-downtime restore is not offered | Coolify's rolling update swaps containers while both mount the same volume, so a data restore cannot avoid changing data under a running application. Repointing a resource at a new volume needs a write to Coolify's own database, which Hindsight refuses. The mode is shown as unavailable with the reason; `clone` covers the real need. | 2026-10-04 |
| R28 | Views live in a package module | `HindsightUI` is an SPM target, so the interface is compiled and unit-tested by `swift test`. An app-only UI would be verified by nothing but opening Xcode. | 2026-10-04 |
| R29 | Agent runtime is a library | `HindsightAgentKit`, with three-line entry points for both the SwiftPM executable and the copy embedded in the app bundle. Two copies of the agent would drift. | 2026-10-04 |
| R31 | The app falls back to the catalog | When the agent is unreachable the window shows the history the catalog holds, with a banner explaining the connection, rather than an empty window. History is in the catalog anyway; only live state needs the agent. | 2026-10-04 |
| R32 | SwiftUI layout constraints, learned by running it | `ContentUnavailableView` may not be a `List` row; `safeAreaInset` may not be attached to a `NavigationSplitView`; a `NavigationSplitView` may not be nested in a stack. Each crashes or collapses the window on macOS 14. Recorded because they are invisible to the compiler and to unit tests. | 2026-10-04 |
| R33 | The agent re-checks the restore confirmation | The typed hostname travels with the restore command and is verified in the agent, not only in the app. The app is a client; a client's checks are a convenience, and the process that writes to a server is the one that must be sure. | 2026-10-04 |
| R34 | Settings save sparsely | An update carries only changed fields. A form that sent everything it displayed would reset whatever had been changed elsewhere since it opened. | 2026-10-04 |
| R35 | Derived server ids are made unique | Normalising a name to something safe as a path and username can collapse two names onto one id, and the catalog upserts by primary key — so the second server would overwrite the first. A suffix is added instead. | 2026-10-04 |
| R11 | Host-key-change test | Pins a deliberately wrong key rather than rotating the container's. Same code path, no shared-state damage to other tests. | 2026-10-04 |
