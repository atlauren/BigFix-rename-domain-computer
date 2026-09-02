# BigFix-rename-domain-computer

This collection of BigFix action files and PowerShell scripts are explorative attempts to rename a domain computer, using BigFix and provided elevated credentials.  

The raw lift was "vibe coded" with Claude/Sonnet5, with heavy hand-tuning by me.

As of this writing, only the Scheduled Task item actually accomplishes the goal. 
* Attempts using BigFix `override / runas=localuser` fail with exit code `1783`.
* The Action3 PowerShell attempt fails with a vague "Access is denied.

The files are:

## **Rename-DomainComputer.bes** 
the main BigFix Task, with four actions:
  1. **DefaultAction** — the production rename, elevating via BigFix's own `override runas=localuser`/`asadmin=true`/`password=required` (masked password entry). Embeds `Rename-DomainComputer.ps1`.
  2. **Action2** — a diagnostic that exercises the same `runas=localuser` elevation with no rename logic at all, to isolate elevation failures from rename-logic failures.
  3. **Action3** — a diagnostic rename that elevates via a SYSTEM-launched PowerShell spawning an inner `Start-Process -Credential` session instead of BigFix's own elevation. Embeds `Rename-DomainComputer-Nested.ps1`. Requires the account to already be a local Administrator; gets a UAC-filtered token even then.
  4. **Action4** — a diagnostic rename that elevates via a SYSTEM-registered Scheduled Task (`Register-ScheduledTask`, LogonType Password, RunLevel Highest) instead of BigFix's own elevation or `Start-Process -Credential`. Embeds `Rename-DomainComputer-ScheduledTask.ps1`. Requires the account to already be a local Administrator, but (unlike Action3) gets a full, unfiltered admin token. Password entry for Action3/Action4 uses a plain, unmasked action parameter prompt.

## **Rename-DomainComputer.ps1**
the editable source of truth for the DefaultAction's embedded rename script (renames via ambient/`-DomainCredential` identity, verifies the result, and requests a restart).

## **Rename-DomainComputer-Nested.ps1** 
the editable source of truth for Action3's embedded script (outer/SYSTEM phase spawns an inner phase logged on as the supplied account via `Start-Process -Credential`, which performs the actual rename).

## **Rename-DomainComputer-ScheduledTask.ps1** 
the editable source of truth for Action4's embedded script (outer/SYSTEM phase registers and runs a Scheduled Task as the supplied account, which performs the actual rename); also reused as-is by `Rename-DomainComputer-ScheduledTask.bes` below.

## **Rename-DomainComputer-ScheduledTask.bes**
a standalone, single-action BigFix Task forking Action4's exact rename mechanism, but collecting the new computer name and credentials via a custom HTML form (`document.body.ontakeaction` + `TakeSecureFixletAction`) instead of a plain action parameter query, so the account's password is masked on entry rather than shown in cleartext as typed.

## **Rename-DomainComputer-SystemCredential.ps1**
the editable source of truth for `Rename-DomainComputer-SystemCredential.bes`'s embedded script. It performs no local logon at all: the payload stays in the agent's own `NT AUTHORITY\SYSTEM` context (already fully elevated locally) and passes the supplied account to `Rename-Computer` as `-DomainCredential`, i.e. as network credentials for the AD computer-object update only. The account therefore does not need to be a local Administrator on the endpoint, and no "deny logon" policy applies.

## **Rename-DomainComputer-SystemCredential.bes**
a standalone, single-action BigFix Task wrapping the above, using the same masked HTML/Secure Parameter form as `Rename-DomainComputer-ScheduledTask.bes`. This is the one variant that avoids every local-logon mechanism that has failed on this endpoint — `override runas=localuser` (RPC 1783), `Start-Process -Credential` (Session 0 window station, access denied) and Task Scheduler's batch logon.

