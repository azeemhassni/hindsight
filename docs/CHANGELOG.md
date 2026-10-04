# Changelog

## M0 — Foundations

- Swift 6 package with `HindsightCore` and `HindsightProcess`, macOS 14 minimum.
- Domain model: validated identifiers, servers, schedules, retention policies,
  backup profiles, snapshots and their tag convention, job kinds, secrets.
- Subprocess layer: line-oriented streaming, cancellation that kills the child,
  an environment allowlist instead of inheritance, and secret redaction across
  output and errors.
