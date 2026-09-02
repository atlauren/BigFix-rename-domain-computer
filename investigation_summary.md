Updated todo list

Read memory 

## RPC 1783 investigation — summary

**Confirmed root location:** 1783 occurs entirely inside BigFix's own `override runas=localuser`/`asadmin=true` logon mechanism (and separately, inside `Start-Process -Credential`'s `CreateProcessWithLogonW` path) — never inside the actual rename logic. Proven conclusively by Action2 (zero PowerShell, zero rename logic, one bare `override` block) still failing with 1783.

### Suspected causes ruled out, in order tested
| # | Hypothesis | How tested | Result |
|---|---|---|---|
| 1 | Secondary Logon (`seclogon`) service disabled/stopped | `sc query seclogon` appended to log | **Ruled out** — `STATE: 4 RUNNING` |
| 2 | Broken machine secure channel / AD trust relationship | `nltest /sc_query:AD`, `Test-ComputerSecureChannel -Verbose` | **Ruled out** — `NERR_Success`, returned `True` |
| 3 | Oversized Kerberos/Netlogon token (PAC) from too many AD group memberships | `tokenGroups` count via `DirectorySearcher` (Base scope) | **Ruled out** — only 41 groups, nowhere near problematic |
| 4 | `~REDACTED~` in `Protected Users` (hard NTLM block at KDC) | `MemberOf -match 'Protected Users'` | **Ruled out** — not a member |
| 5 | UAC flags (smartcard-required, DES-only, disabled) | `UserAccountControl` = 1049088 → `NORMAL_ACCOUNT + NOT_DELEGATED` only | **Ruled out** — just standard "sensitive, no delegation" flag, and `NOT_DELEGATED` doesn't even apply to plain NTLM/Netlogon pass-through (no delegation involved) |
| 6 | NTLM disabled by generic GPO hardening | Reasoned from the NTSTATUS itself | **Ruled out** — `0xC003000C` = `STATUS_RPC_NT_BAD_STUB_DATA`, a data-marshaling defect, not an auth-decision code (an NTLM block would look like a logon-failure code, not "bad stub data") |
| 7 | Account/endpoint fundamentally broken (rights, environment) | Action4 (Scheduled Task) actually renamed the computer successfully | **Ruled out** — `~REDACTED~` has all necessary rights; the endpoint works fine via a different code path |

### What's confirmed (not ruled out — this *is* the cause)
1783 is inside the BES Client's own `runas=localuser`/`asadmin=true` implementation itself — a client-side/BigFix-internal issue, not anything in this repo's scripts, not the account, not the endpoint's AD/security posture, and not a fundamental Windows RPC problem (proven by Action4 succeeding via a completely different logon mechanism).

### What's left (not yet done)
1. **Differential test never run**: retry `override runas=localuser` (Action1 or Action2) with a *different* domain account on the same endpoint — would confirm whether it's specific to `~REDACTED~` (unlikely at this point, given how much has been ruled out) or universal to this endpoint's BES Client.
2. Check the BES Client version/build on `OIT-DSS-D-023` against HCL's known-issues list for `RPC_X_BAD_STUB_DATA`.
3. If both come back inconclusive: file a support ticket with HCL BigFix — you already have a clean minimal repro (Action2 alone).

### Practical outcome
Action4 (Scheduled Task) works and is the recommended path forward for actual renames on affected endpoints; Action1/2 (BigFix's own mechanism) and Action3 (`Start-Process -Credential`) remain broken for reasons outside this repo's control.