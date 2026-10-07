# Changelog

## Unreleased

- Added local compressed DMG packaging with an Applications shortcut and SHA-256 sidecar. Filenames identify the version and host architecture; existing DMGs are not overwritten.
- Added optional Developer ID Application signing for the app and DMG, with hardened runtime and secure timestamps for the app. Ad hoc signing remains the default.
- Verified Apple silicon packaging through signature, timestamp, runtime, checksum and read-only mount checks. Notarization remains pending. No binary release asset has been uploaded.

## 0.1.0-beta.1, 07/10/2026

First versioned source-only beta for community testing. No compiled app or third-party artwork is distributed.

### Included

- Native SwiftUI and AppKit workspace with project selection, service architecture, back navigation, account details and permission-aware notices.
- OAuth with PKCE and Keychain storage, deployment history, logs, metrics, reviewed variable changes, Railway Agent and Cloud Agent workflows, and read-only bucket previews.
- Embedded PTY terminal with bounded output, persistent-session support and capped reconnect attempts.
- Local regression coverage for OAuth refresh rotation and rejection, terminal retry stopping and reset, Unicode output limits and request validation. All 61 tests passed for this beta baseline.
- A single version file used by the app build and About panel.

### Known limitations

- Live OAuth expiry rotation, SSH reconnection after network interruption, terminal task cancellation and complete SSH/TUI behavior remain unverified. The terminal implements a bounded VT-style subset, not complete xterm compatibility.
- Cloud mutations, deployment recovery, storage object access and notification delivery still need authenticated acceptance checks. Viewer grants can deny logs, variables, cloud tasks and notifications; member access must be explicitly authorized for selected resources. Use a disposable environment for mutation testing.
- Session archiving is local only. Background progress and desktop alerts require the app to remain running; app-closed push delivery is not implemented.
- Builds are ad hoc signed and not notarized. Railway CLI is required for SSH. Source builds use system-symbol icons and a graphite background because third-party artwork is excluded.
- This independent beta does not claim full feature parity or production readiness. See [FEATURES.md](FEATURES.md) for workflow-level evidence and pending checks.

Report reproducible issues through the repository feedback template. Remove credentials, variable values, private logs and account details from reports.
