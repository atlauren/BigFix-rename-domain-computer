# BigFix-rename-domain-computer

This collection of BigFix action files and PowerShell scripts are explorative attempts to rename a domain computer, using BigFix and provided elevated credentials.  

The raw lift was "vibe coded" with Claude/Sonnet5, with heavy hand-tuning by me.

As of this writing, only the Scheduled Task item actually accomplishes the goal. 
* Attempts using BigFix `override / runas=localuser` fail with exit code `1783`.
* The Action3 PowerShell attempt fails with a vague "Access is denied.

The files are:

## **Rename-DomainComputer.bes** 
the main BigFix Task, with four actions:
  1. **DefaultAction** — the production rename, elevating via BigFix's own `override runas=localuser`/`asadmin=true`/`password=required`. Embeds `Rename-DomainComputer.ps1`.
  
     *Password handling:* `password=required` makes the Console prompt for it with a **masked** field and ship it to the agent as a SecureParameter. The agent consumes it directly in its own process-creation call, so it never reaches the action script, the embedded PowerShell, the disk, or the client logs. This is the cleanest handling of the four, but the SecureParameter is only usable by the `override` block itself — it cannot be pulled into `{parameter "..." of action}` for use anywhere else, which is why the other actions cannot reuse it.

  2. **Action2** — a diagnostic that exercises the same `runas=localuser` elevation with no rename logic at all, to isolate elevation failures from rename-logic failures.
  
     *Password handling:* identical to DefaultAction — masked SecureParameter via `password=required`, consumed only by the `override` block.
     
  3. **Action3** — a diagnostic rename that elevates via a SYSTEM-launched PowerShell spawning an inner `Start-Process -Credential` session instead of BigFix's own elevation. Embeds `Rename-DomainComputer-Nested.ps1`. Requires the account to already be a local Administrator; gets a UAC-filtered token even then.
  
     *Password handling:* collected by a plain `action parameter query`, which is **unmasked** — shown in cleartext as typed and remembered as a default. The action script then writes it with `createfile` (no shell is involved, so metacharacters in the password can't be interpreted) to `%ProgramData%\BigFix\RenameComputer\admin-nested.cred`, in a folder ACL'd to SYSTEM and Administrators only. Only the *path* is passed on a command line. The script reads it into a `PSCredential`, deletes the file immediately, and the action script deletes it again unconditionally as a safety net. 
     
  4. **Action4** — a diagnostic rename that elevates via a SYSTEM-registered Scheduled Task (`Register-ScheduledTask`, LogonType Password, RunLevel Highest) instead of BigFix's own elevation or `Start-Process -Credential`. Embeds `Rename-DomainComputer-ScheduledTask.ps1`. Requires the account to already be a local Administrator, but (unlike Action3) gets a full, unfiltered admin token.
  
     *Password handling:* same **unmasked** `action parameter query` and same ACL'd `createfile` credential-file transport as Action3, using `admin-schtask.cred`. From there it is passed to `Register-ScheduledTask` in-process, never via `schtasks.exe /RP`, so it never appears on any command line or in 4688/Sysmon process auditing. Task Scheduler holds it in its own encrypted credential store until the task is unregistered, which the script does in a `finally` block, with a `schtasks /Delete` safety net in the action script.

## **Rename-DomainComputer.ps1**
the editable source of truth for the DefaultAction's embedded rename script (renames via the ambient identity supplied by the `override` block, verifies the result, and requests a restart).

*Password handling:* none. The script has no password parameter and no credential file — it never sees, stores, or handles credential material at all, because BigFix has already applied the credential when creating the process.

## **Rename-DomainComputer-Nested.ps1** 
the editable source of truth for Action3's embedded script (outer/SYSTEM phase spawns an inner phase logged on as the supplied account via `Start-Process -Credential`, which performs the actual rename).

*Password handling:* takes a `-CredentialFile` **path**, never the password itself. Both phases read the file into a `PSCredential` and delete it right away (the outer phase in a `finally`, so it is removed even if launching the inner process throws). The credential is only ever used in-process — `Start-Process -Credential`, `Rename-Computer -DomainCredential`, and, in the CIM fallback, `GetNetworkCredential().Password` handed to `Invoke-CimMethod` — so it never reaches a command line. `$cred` is nulled after use.

## **Rename-DomainComputer-ScheduledTask.ps1** 
the editable source of truth for Action4's embedded script (outer/SYSTEM phase registers and runs a Scheduled Task as the supplied account, which performs the actual rename); also reused as-is by `Rename-DomainComputer-ScheduledTask.bes` below.

*Password handling:* same `-CredentialFile` path-only pattern as above. The password goes straight from memory into `Register-ScheduledTask` (rather than `schtasks.exe /RP`, which would expose it on a command line), after which Task Scheduler stores it encrypted until the task is unregistered in the script's `finally` block. The inner phase needs no credential at all — it runs under a genuine logon for the account, so the rename uses its ambient identity.

## **Rename-DomainComputer-ScheduledTask.bes**
a standalone, single-action BigFix Task forking Action4's exact rename mechanism, but collecting the new computer name and credentials via a custom HTML form (`document.body.ontakeaction` + `TakeSecureFixletAction`) instead of a plain action parameter query.

*Password handling:* this is the only difference from Action4. Entry is **masked** and delivered as a true Secure Parameter, so it is not shown in cleartext as typed and is not remembered as a default the way a queried parameter is. Everything downstream is unchanged from Action4: ACL'd `createfile` credential file, path-only on the command line, in-process `Register-ScheduledTask`, deletion in a `finally` plus an unconditional safety-net delete. Caveat: the masking has been reported to fall back to cleartext when a task is deployed through the BigFix **WebUI** rather than the classic Console — verify in whichever tool you actually deploy with.

## **Rename-DomainComputer-SystemCredential.ps1**
the editable source of truth for `Rename-DomainComputer-SystemCredential.bes`'s embedded script. It performs no local logon at all: the payload stays in the agent's own `NT AUTHORITY\SYSTEM` context (already fully elevated locally) and passes the supplied account to `Rename-Computer` as `-DomainCredential`, i.e. as network credentials for the AD computer-object update only. The account therefore does not need to be a local Administrator on the endpoint, and no "deny logon" policy applies.

*Password handling:* same `-CredentialFile` path-only pattern as the other two scripts, with one improvement — the file is deleted in the script's **top-level `finally`**, which PowerShell runs even on `exit`, so no early-return path (invalid name, already correctly named, AD collision) can leave the credential on disk. The credential is used in-process only, for `-DomainCredential` and the CIM fallback, and is never used to log anyone on to the endpoint.

## **Rename-DomainComputer-SystemCredential.bes**
a standalone, single-action BigFix Task wrapping the above, using the same masked HTML/Secure Parameter form as `Rename-DomainComputer-ScheduledTask.bes`. This is the one variant that avoids every local-logon mechanism that has failed on this endpoint — `override runas=localuser` (RPC 1783), `Start-Process -Credential` (Session 0 window station, access denied) and Task Scheduler's batch logon.

*Password handling:* **masked** Secure Parameter entry via the HTML form, then written with `createfile` to `admin-syscred.cred` in the SYSTEM/Administrators-only folder, with only the path on the command line and an unconditional delete in the action script on top of the script's own `finally`. The same WebUI masking caveat noted above applies. Note the trade-off: because the account is used as a *network* credential rather than to create a local logon token, the password is sent to a domain controller for the AD update but is never used to log the account on to the endpoint itself.

