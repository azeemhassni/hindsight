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
