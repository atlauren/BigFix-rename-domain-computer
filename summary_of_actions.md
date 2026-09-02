Updated todo list

## The four actions in `Rename-DomainComputer.bes`

| | **Action1 (Default)** | **Action2** | **Action3** | **Action4** |
|---|---|---|---|---|
| **Purpose** | Actual rename (production) | Diagnostic only — no rename | Diagnostic rename (alt. mechanism) | Diagnostic rename (alt. mechanism) |
| **Elevation mechanism** | BigFix `override runas=localuser`/`asadmin=true`/`password=required` | Same `override` mechanism, no PowerShell at all | SYSTEM PowerShell → `Start-Process -Credential` → inner PowerShell | SYSTEM PowerShell → `Register-ScheduledTask` (LogonType Password, RunLevel Highest) → task runs as user |
| **Password entry** | Masked, native (`password=required` → SecureParameter, console-native) | Masked, native (same) | Plain `action parameter query` — **unmasked** | Plain `action parameter query` — **unmasked** |
| **Local admin synthesis?** | Yes — `asadmin=true` grants a synthetic admin token even to a non-admin domain account | N/A (no rename) | No — needs a *real* local admin, and gets a UAC-**filtered** token even then | No — needs a *real* local admin, but gets a **full, unfiltered** token (Task Scheduler bypasses UAC filtering) |
| **Depends on `seclogon`?** | Yes | Yes (added mid-investigation) | Yes (`CreateProcessWithLogonW`) | No — Task Scheduler has its own logon path |
| **Status (this endpoint)** | ❌ Fails with 1783 (BigFix's own logon mechanism) | ❌ Fails with 1783 (proved it's not the script) | ❌ Fails with `Access is denied` (Session-0/window-station limitation, different bug) | ✅ **Succeeded** — actual rename completed |
| **Script file** | `Rename-DomainComputer.ps1` | none (inline `.bat`) | `Rename-DomainComputer-Nested.ps1` | `Rename-DomainComputer-ScheduledTask.ps1` |
| **Exit codes** | 0/10/11/12/13 | n/a | 0/10/11/12/13 | 0/10/11/12/13 + 14 (couldn't register/start task), 15 (timed out) |

**Diagnostic logic, in order**: Action1 is the real task; Action2 isolates BigFix's elevation from the rename logic entirely; Action3 tests whether the failure is specific to BigFix's token creation by using a different Windows API for the same kind of credentialed logon; Action4 tests whether it's specific to *any* credentialed logon at all by using a mechanism (Task Scheduler) that shares neither BigFix's code nor `CreateProcessWithLogonW`. Action4 succeeding is what proved 1783 is confined to BigFix's own mechanism and Action3's specific API, not the account or endpoint.

**Related but separate file**: `Rename-DomainComputer-ScheduledTask.bes` is a forked, single-action Task that reimplements Action4's exact same mechanism but with masked password entry via a custom HTML form + `TakeSecureFixletAction` instead of the unmasked `action parameter query` — kept separate rather than merged into the 4-action Task because of unconfirmed multi-action interaction risk with the `document.body.ontakeaction` hook.
