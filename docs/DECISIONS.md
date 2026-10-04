# Decisions

Running list. Resolved items stay for the record; open items are what I need
from you, batched for the end of the project rather than blocking progress.

## Open

| # | Topic | What I need | What I am doing meanwhile |
|---|---|---|---|
| 1 | Signing identity | The Developer ID team identifier and the bundle identifier you want. The keychain access group and the XPC code-signing requirement both embed the team id. | Placeholders in `App/project.yml`: bundle id `app.hindsight.Hindsight`, team read from `HINDSIGHT_TEAM_ID`. Local builds sign ad-hoc. |

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
| R11 | Host-key-change test | Pins a deliberately wrong key rather than rotating the container's. Same code path, no shared-state damage to other tests. | 2026-10-04 |
