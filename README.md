# Railway for macOS, 0.1.0-beta.1

A native Railway client built in Swift, SwiftUI, AppKit and C. It includes service architecture, deployments, agent workflows and an SSH terminal, with native charts, translucent surfaces and keyboard navigation. Requires macOS 14 or later and Railway CLI for SSH connections. The Swift package has no third-party dependencies.

Keychain stores credentials, and project metadata is cached locally. The terminal uses a native pseudoterminal. This repository contains source, tests and docs only. System symbols and a graphite background replace artwork and icon files that are not distributed here.

## Beta status and feedback

This independent, source-only beta is open for testing and feedback. Full feature parity is not established. Local builds default to an ad hoc signature; optional Developer ID signing has passed local checks. Apple notarization remains pending. Read the [changelog and known limitations](CHANGELOG.md) and [workflow validation status](FEATURES.md) before testing.

`VERSION` defines the beta version shown in **Railway > About Railway**. Beta numbers increase for subsequent testing releases; `0.1.0` remains reserved for a release that passes its declared acceptance checks.

Report bugs and suggestions in this repository's Issues using the **Beta feedback** template. Include the app version or commit, macOS version, steps to reproduce, expected behavior and what happened. For access failures, state whether the app has viewer or member access. Remove tokens, variable values, private logs and account details from screenshots and reports. Use GitHub private vulnerability reporting for security issues when enabled; do not post sensitive vulnerability details in public Issues.

## Build

```sh
swift test
sh scripts/build-app.sh
open 'dist/Railway.app'
```

To create a local compressed DMG with the app and an Applications shortcut:

```sh
sh scripts/build-dmg.sh
```

The DMG and SHA-256 sidecar are written to `dist/`, with the version and host architecture in the filename. Builds target the host architecture, not a universal binary. The script refuses to overwrite an existing DMG. No DMG is uploaded by this command.

Set `CODE_SIGN_IDENTITY` to your Developer ID Application certificate identity to sign the app with hardened runtime and a secure timestamp, and sign the DMG. Signed DMGs use a `-signed` filename suffix. Signing does not notarize the app; Apple notarization remains a separate distribution step.

```sh
CODE_SIGN_IDENTITY='Developer ID Application: Your Name (TEAMID)' sh scripts/build-dmg.sh
```

Replace the example identity with your certificate name from `security find-identity -v -p codesigning`. The Apple silicon DMG passed checks for app and image signatures, secure timestamps, hardened runtime, checksums, and mounted contents. These checks cover packaging; notarization and full application testing remain pending. GitHub releases contain source only; no DMG has been published.

Local builds are not notarized. After rebuilding or changing the signing identity, macOS may ask for access to the app's existing Keychain items. Keychain operations run off the main UI thread, so that prompt does not freeze the interface.

## Authentication

Sign in through the system authentication browser. The app registers a native public OAuth client and uses PKCE, selective resource grants and refresh-token rotation. Viewer access is the default. In Account, enable **Allow service management** before signing in to request member access for the projects or workspaces selected on Railway's consent page. The app does not approve that consent page.

The tested viewer grant allowed project discovery, deployment history, metrics, agent history, cloud-machine listing and staged-change reads. Railway denied deployment logs, service variables, cloud-task history and notification delivery for that grant. The app displays those errors. Account API tokens are also supported.

Credentials stay in Keychain. Project metadata is cached in Application Support. Logs, variable values, agent messages, storage credentials and object previews stay in memory unless the user explicitly copies or exports them. Session archive markers are stored locally and do not stop cloud execution. Disconnect closes local SSH connections and clears conversations, then removes stored credentials and cached projects. A failure during storage cleanup is reported, but project details and logs can remain visible until cleanup succeeds.

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

See [FEATURES.md](FEATURES.md) for workflow validation status. Local tests cover response failures, OAuth validation, stream parsing, request scoping, variable handling, topology extraction, storage request validation, deep links and terminal screen behavior. They also run a local pseudoterminal (PTY) process and an interactive Vim session. Cloud changes still require authenticated testing.

OAuth login and restore, project discovery, service canvas reads, deployment history, metrics, agent history, cloud-machine reads and staged-change reads have passed authenticated checks. Variable reads were observed with member access. Notification delivery was denied in the tested session. Each workflow requires the corresponding resource permissions; live mutation tests also require an explicitly selected disposable environment.

End-to-end SSH and terminal application behavior, storage object access, cloud changes, remote notification delivery and OAuth expiry rotation remain unverified. Server-side session archiving and push delivery while the app is closed are not implemented.

The terminal supports a bounded subset of VT-style behavior and is not fully xterm-compatible. It allows up to 200 rows and 400 columns, 64 UTF-8 bytes per cell and 2,000 scrollback rows. Oversized combining sequences are truncated with a visible notice. Authentication detection retains an 8,192-byte window and checks each complete bounded PTY read before discarding older output. Regression tests cover combining floods, split Unicode, alternate screens, scrollback, reset and failure detection.

See [BRANDING.md](BRANDING.md) for the artwork and icon policy.

This project is not affiliated with or endorsed by Railway.
