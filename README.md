# Railway for macOS, 0.1.0-beta.1

A native Railway workspace for macOS, built from scratch in Swift, SwiftUI, AppKit and C. Explore service architecture, inspect deployments, work with agents and open SSH terminals in a desktop interface with native charts, glass surfaces and keyboard navigation. Requires macOS 14 or later. No third-party packages. The Railway CLI is needed for SSH connections.

The app runs directly on macOS, with platform UI and a real pseudoterminal. Keychain stores credentials, and project metadata is cached locally. This repository contains source, tests and docs only. Built-in system symbols and a graphite backdrop replace excluded artwork and icon files.

## Beta status and feedback

This source-only beta is open for testing and community feedback. It is not an official Railway app or a feature-parity release. Local builds use an ad hoc signature; Developer ID signing and notarization remain pending. See the [changelog and known limitations](CHANGELOG.md) and the [acceptance matrix](FEATURES.md) before testing.

`VERSION` defines the beta version shown in **Railway > About Railway**. Beta numbers increase for subsequent testing releases; `0.1.0` remains reserved for a release that passes its declared acceptance checks.

Report bugs and suggestions through this repository's Issues using the **Preview feedback** template. Include the app version or commit, macOS version, steps to reproduce, expected behavior and what happened. For access failures, state whether the app has viewer or member access. Remove tokens, variable values, private logs and account details from screenshots and reports. Use GitHub private vulnerability reporting for security issues when enabled; do not post sensitive vulnerability details in public Issues.

## Build

```sh
swift test
sh scripts/build-app.sh
open 'dist/Railway.app'
```

Local builds use an ad hoc signature and are not notarized. After rebuilding, macOS may ask for access to the app's existing Keychain items. Keychain operations run off the main UI thread, so that prompt does not freeze the interface.

## Authentication

Sign in through the system authentication browser. The app registers a native public OAuth client and uses PKCE, selective resource grants and refresh-token rotation. Viewer access is the default. In Account, enable **Allow service management** before signing in to request member access for the projects or workspaces selected on Railway's consent page. The app does not approve that consent page.

The verified viewer grant permits project discovery, deployment history, metrics, agent history, cloud-machine listing and staged-change reads. It was denied deployment logs, service variables, cloud-task history and notification delivery. Controls report those server errors. Account API tokens are an advanced alternative.

Credentials stay in Keychain. Project metadata is cached in Application Support. Logs, variable values, agent messages, storage credentials and object previews stay in memory unless the user explicitly copies or exports them. Session archive markers are stored locally and do not stop cloud execution. Disconnect clears credentials, cached projects, in-memory conversations and local SSH connections.

## Navigation

After session restoration, Railway opens the project selector rather than selecting a project automatically. The sidebar groups projects by workspace and supports search and favorites. Projects shared without workspace metadata appear under **Shared projects**.

The overview greets the connected account and links to unread alerts and notices. When Railway denies notification access, it shows the access error instead of zero counts. Selecting a service opens its deployment view; **Back to workspace** returns to Services, and **All projects** returns to the project selector.

## Workflows

- Private project creation with workspace selection and confirmation.
- Architecture canvas with source icons, service status, domains, volume attachments, cron details and connections derived from variable references. Configuration values used to derive connections are discarded.
- Deployment history, diagnosis, reviewed redeploy and rollback, and live log polling with search, error filtering and export.
- CPU, memory and network charts with time ranges. Masked variable values and reviewed saves that do not trigger deployments.
- Native Railway Agent conversations, history, streamed text, tool results and staged-change review. Applying a patch rechecks its identity and contents first. An ambiguous failure requires reconciliation, not an automatic retry.
- Cloud machines, creation, wake/sleep, sessions, task instructions, progress, interaction decisions and isolated HTTPS app previews beside chat. Archiving is explicitly local to this app.
- Notification inbox, read state, optional desktop alerts and menu-bar progress while the app runs, service deep links and diagnosis-to-agent handoff.
- Read-only bucket browsing with pagination and bounded text/image previews. S3 requests are signed in memory; redirects and unrecognized storage endpoints are refused.
- Embedded SSH terminal with a real pseudoterminal, control keys, colors, alternate screen, resize and bounded reconnect attempts. Persistent sessions use Railway CLI's tmux integration, which may install tmux in the service after the user confirms. Host verification is left to the CLI and SSH; it is not disabled.

## Validation and remaining work

See [FEATURES.md](FEATURES.md) for the acceptance matrix. Local tests cover response failures, OAuth validation, stream parsing, request scoping, variable handling, topology extraction, storage request validation, deep links, terminal screen behavior and a real local PTY process and an interactive Vim session. These tests do not establish successful cloud mutations.

OAuth login and restore, project discovery, service canvas reads, deployment history, metrics, agent history, cloud-machine reads and staged-change reads have passed authenticated checks. Member access has been authorized and variable reads have been observed in the app, but notification delivery remains denied by the current grant. Each workflow requires the corresponding resource permissions; live mutation acceptance also requires an explicitly selected disposable test environment. End-to-end SSH/TUI behavior, storage object access, cloud changes, remote notification delivery, OAuth expiry rotation and full feature parity remain unverified. The terminal implements a bounded VT-style subset; it is not certified as fully xterm-compatible. Geometry is capped at 200 rows and 400 columns, each cell retains at most 64 UTF-8 bytes, and scrollback retains at most 2,000 rows. Oversized combining sequences are truncated with a visible notice. Authentication detection retains an 8 KB byte window and checks each complete bounded PTY read before eviction. Regression tests cover combining floods, split Unicode, alternate screens, scrollback, reset and failure detection. Server-side session archiving and app-closed push delivery are not implemented.

See [BRANDING.md](BRANDING.md) for the visual asset boundary.

This project is not affiliated with or endorsed by Railway.
