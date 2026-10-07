# Beta validation status

The beta is open for feedback. Full feature parity is not established. This table records what is implemented, what has been tested locally or against Railway, and what still needs testing. A successful build or local test does not verify the corresponding server operation.

| Workflow | Implementation | Validation |
| --- | --- | --- |
| OAuth login, PKCE, selective grants, Keychain | Implemented | Live login and restore passed; local refresh, token rotation and rejection tests passed; live expiry rotation pending |
| Optional member access | Implemented, consent remains user-controlled | Member consent completed by user; variables and account profile observed live |
| Private project creation | Native workspace selector and explicit confirmation implemented | Live creation pending |
| Workspace overview, sidebar selection and back navigation | Project selector on startup, workspace filtering, account greeting and notification access errors | Sidebar project selection, project-card entry and return from service details observed live; denied notification state observed |
| Projects, environments, service status, icons, volumes | Implemented; system-symbol fallbacks replace excluded icon assets | Live reads and prior UI checks passed |
| Variable-reference topology | Implemented, values discarded after extraction | Parser tested; authenticated configuration shape checked; updated canvas pending |
| Metrics, service comparison and time ranges | Implemented with native Charts | Four metric series returned live; chart UI pending with restored auth |
| Variable reads and reviewed writes | Implemented, values masked by default | Request and denial tests passed; member read observed in the app |
| Deployment history, diagnosis, redeploy, rollback | Implemented | History passed live; mutations and diagnosis pending |
| Logs, search, export, live polling | Implemented | Local log workflow passed; viewer grant denied live logs |
| Cron service status and next run | Implemented | State fixtures passed; live cron service pending |
| Railway Agent chat, history and tool results | Implemented | Live history passed; streaming parser tested; live send pending |
| Staged infrastructure review and apply | Exact reviewed patch, submitted-ID readback, background status and failed-patch restaging | Read and failure-diagnosis contracts tested; live write recovery not independently observed |
| Cloud-agent creation and lifecycle | Implemented | Machine read passed live; mutation pending |
| Cloud task chat, decisions and progress | Implemented | Scoped/idempotent request tests passed; viewer grant denied task read |
| Session grouping and archiving | Grouped by machine/session; local archive and restore implemented | Server-side archival is not implemented |
| Cloud app previews | Side-by-side HTTPS WebKit preview with isolated data store | Live preview pending |
| SSH terminal, keys, resize and alternate screen | Native PTY and VT-style renderer implemented | Real local PTY, interactive Vim, combining-flood and bounded-history regressions passed; live service/cloud SSH pending |
| Automatic terminal reconnection | Bounded retries retain frozen remote session settings; manual cancellation stops pending retries | Policy tests passed; network interruption not independently observed |
| Notification inbox and read state | Implemented | Viewer grant denied live delivery query; member validation pending |
| Actionable desktop alerts and service links | Implemented while the app runs | Route tests passed; OS permission and delivery pending |
| Agent deep links | Native routes for Railway threads and cloud machines with environment membership checks | Route tests passed; live open pending |
| Background agent status | Polls while the app runs; menu-bar status and native status links | Member validation pending; app-closed push is not implemented |
| Bucket browsing and previews | Read-only S3 listing and bounded image/text previews | Signing/endpoint guards tested; live storage validation pending |
| Offline, role-denied and ambiguous failures | Explicit error states, metadata cache, no automatic mutation retries | Local cases tested; full authenticated recovery pending |
| Distribution | Local app and compressed DMG builds; ad hoc default or optional Developer ID signing | Apple silicon app and DMG signatures, hardened runtime, timestamp, checksum and mounted contents verified; notarization and complete release acceptance pending; binaries and third-party artwork are not published |

## Mutation acceptance environment

Live mutation checks must use an explicitly selected disposable project/environment. They must verify returned server state for variable saves, deployment changes, staged apply, cloud-agent creation, task dispatch, decisions, sleep/wake and notification read state. A failed or timed-out request must be reconciled before retrying. No production mutation has been executed as part of implementation validation.

## Terminal limits

The renderer supports ANSI colors, cursor addressing, erase/insert/delete, scroll regions, alternate screens, line drawing, bracketed paste and common control/function keys. It does not claim complete xterm compatibility. Mouse-reporting applications, complex composed emoji, IME composition, and extended terminal protocols need further acceptance work.

The screen is limited to 200 rows by 400 columns, 64 UTF-8 bytes per cell and 2,000 scrollback rows. Excess combining scalars are dropped without preventing subsequent printable text or control sequences. The truncation notice survives a remote terminal reset and clears on a new connection. Authentication output retains at most 8,192 bytes; each bounded PTY read is checked before eviction so failure messages early in a large read remain detectable.
