<#
.SYNOPSIS
    Diagnostic payload for BigFix task "Rename Domain-Joined Windows Computer", Action 4
    ("Scheduled Task rename"). Renames a domain-joined Windows computer by having a
    SYSTEM-launched PowerShell process register and run a Scheduled Task under the supplied
    domain account, and doing the actual rename entirely inside that task's own logon session.

.DESCRIPTION
    Exists to test whether RPC error 1783 (RPC_X_BAD_STUB_DATA), seen with both BigFix's own
    'override runas=localuser / asadmin=true' and with Start-Process -Credential (Action 3),
    is specific to those two code paths or inherent to any credentialed logon on this endpoint.
    Task Scheduler uses neither BigFix's own token-creation code nor CreateProcessWithLogonW/
    the Secondary Logon service, so a different result here is meaningful.

    Unlike Action 3, a Scheduled Task registered with -RunLevel Highest gets a full, unfiltered
    admin token for a genuine local Administrator account (Task Scheduler's elevation does not
    go through the interactive UAC consent path that filters remote/non-interactive tokens), so
    this does not carry Action 3's "filtered token" caveat. AdminUser must still already be a
    local Administrator on this endpoint - there is no equivalent of asadmin=true's synthesis
    of local Administrator rights for a non-admin account.

    Security notes:
    - The account's password is only ever read from CredentialFile into memory (never passed
      as a command-line argument to any process), then handed in-process to
      Register-ScheduledTask, which stores it via Task Scheduler's own encrypted credential
      store (the same mechanism used for a Windows service's "Log on as" account). That stored
      copy persists until the task is deleted or its password changed, so the task is
      unregistered as soon as it finishes (in a finally block), with a second, unconditional
      `schtasks /Delete` in the actionscript as a safety net (that second delete needs no
      secret, so it is safe to run unconditionally).
    - The task's name/run time/result code remain in the
      Microsoft-Windows-TaskScheduler/Operational event log even after the task itself is
      deleted (event logs are independent of the task store) - no credential is ever logged
      there, but this is a visible trace that the task ran.
    - Registering a Scheduled Task uses a batch-type logon (SeBatchLogonRight), the same class
      of local logon right as BigFix's own runas=localuser; an account denied batch logon on
      this endpoint by policy will fail here for a reason unrelated to RPC 1783.

    Exit codes: 0/10/11/12/13 same meaning as Rename-DomainComputer.ps1's inner rename result.
      14 could not register or start the Scheduled Task
      15 timed out waiting for the Scheduled Task to finish

.NOTES
    2026-09-01 atlauren / Claude

    This file is the editable source of truth for Action 4's embedded script. The copy embedded
    in the .bes createfile block must have every { doubled to {{ (and every } left single).
    Keep in sync.
#>
#Requires -Version 5.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $NewName,

    [string] $AdminUser = '',

    # Path to a one-time file holding the domain account's password; read, then deleted.
    [string] $CredentialFile = '',

    # Set automatically when Task Scheduler invokes this script as AdminUser; do not pass by hand.
    [switch] $Inner,

    [string] $ActionId = 'manual',

    [string] $LogPath = (Join-Path ([Environment]::GetFolderPath('ProgramFilesX86')) 'BigFix Enterprise\BES Client\__BESData\__Global\Logs\rename-computer.log')
)

$ErrorActionPreference = 'Stop'

function Write-Log {
    param([string] $Message)
    $line = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss') + '  ' + $Message
    Write-Output $line
    Add-Content -LiteralPath $LogPath -Value $line -Encoding ASCII
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null

    if (-not $Inner) {
        # --- Outer phase: runs as SYSTEM. Registers and runs a Scheduled Task as AdminUser. ---
        Write-Log ('--- BigFix action ' + $ActionId + ' started (outer/SYSTEM) ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz') + ' ---')
        Write-Log ('Running as: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)

        if (-not $AdminUser -or -not $CredentialFile -or -not (Test-Path -LiteralPath $CredentialFile)) {
            Write-Log 'ERROR: no admin credential available to register the scheduled task.'
            exit 14
        }

        $self = $MyInvocation.MyCommand.Path
        $taskName = 'BigFixRenameComputer-' + $ActionId
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $innerArgs = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $self + '" -NewName "' + $NewName + '" -Inner -ActionId "' + $ActionId + '" -LogPath "' + $LogPath + '"'

        $exitCode = 14
        $registered = $false
        try {
            $secret = (Get-Content -LiteralPath $CredentialFile -Raw).TrimEnd("`r", "`n")
            $plainPassword = $secret
            $secret = $null

            $action = New-ScheduledTaskAction -Execute $psExe -Argument $innerArgs
            $settings = New-ScheduledTaskSettingsSet -Hidden -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -MultipleInstances IgnoreNew -ExecutionTimeLimit (New-TimeSpan -Minutes 5)

            Register-ScheduledTask -TaskName $taskName -Action $action -Settings $settings `
                -User $AdminUser -Password $plainPassword -RunLevel Highest -Force | Out-Null
            $plainPassword = $null
            $registered = $true
            Write-Log ('Scheduled task ' + $taskName + ' registered, starting it now.')

            Start-ScheduledTask -TaskName $taskName

            $deadline = (Get-Date).AddMinutes(4)
            $result = $null
            do {
                Start-Sleep -Milliseconds 500
                $state = (Get-ScheduledTask -TaskName $taskName -ErrorAction SilentlyContinue).State
            } while ($state -eq 'Running' -and (Get-Date) -lt $deadline)

            if ($state -eq 'Running') {
                Write-Log 'ERROR: timed out waiting for the scheduled task to finish.'
                $exitCode = 15
            }
            else {
                $info = Get-ScheduledTaskInfo -TaskName $taskName
                $exitCode = $info.LastTaskResult
                Write-Log ('Scheduled task LastTaskResult: ' + $exitCode)
            }
        }
        catch {
            Write-Log ('ERROR: could not register/run the scheduled task as ' + $AdminUser + ': ' + $_.Exception.Message)
        }
        finally {
            $plainPassword = $null
            Remove-Item -LiteralPath $CredentialFile -Force -ErrorAction SilentlyContinue
            if ($registered) {
                Unregister-ScheduledTask -TaskName $taskName -Confirm:$false -ErrorAction SilentlyContinue
            }
        }

        Write-Log ('Inner task exit code: ' + $exitCode)
        exit $exitCode
    }

    # --- Inner phase: runs as AdminUser, via the Scheduled Task registered above. ---
    Write-Log ('--- BigFix action ' + $ActionId + ' started (inner/' + [Security.Principal.WindowsIdentity]::GetCurrent().Name + ') ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz') + ' ---')
    Write-Log ('Rename requested: ' + $NewName)

    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Log ('Running as: ' + $me.Name)
    $isAdmin = [Security.Principal.WindowsPrincipal]::new($me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log ('Elevated: ' + $isAdmin)
    if (-not $isAdmin) {
        Write-Log 'ERROR: not running with an Administrators token (see UAC note in the script header).'
        exit 12
    }

    if ($NewName.Length -gt 15 -or $NewName -notmatch '^[A-Za-z0-9][A-Za-z0-9-]*$' -or $NewName -match '^[0-9]+$') {
        Write-Log ('ERROR: invalid NetBIOS computer name: ' + $NewName)
        exit 10
    }

    if ($env:COMPUTERNAME -eq $NewName) {
        Write-Log 'Computer already has the requested name. Nothing to do.'
        exit 0
    }

    $collision = $false
    try {
        $searcher = [DirectoryServices.DirectorySearcher]::new()
        $searcher.Filter = '(&(objectCategory=computer)(cn=' + $NewName + '))'
        if ($null -ne $searcher.FindOne()) {
            $collision = $true
        }
    }
    catch {
        Write-Log ('WARNING: AD pre-flight check skipped: ' + $_.Exception.Message)
    }
    if ($collision) {
        Write-Log ('ERROR: an AD computer object named ' + $NewName + ' already exists.')
        exit 11
    }

    Write-Log ('Renaming ' + $env:COMPUTERNAME + ' to ' + $NewName)
    $renamed = $false
    try {
        # Genuinely logged on as the domain account here, so ambient identity is used directly.
        Rename-Computer -NewName $NewName -Force -ErrorAction Stop
        $renamed = $true
        Write-Log 'Rename-Computer succeeded.'
    }
    catch {
        Write-Log ('Rename-Computer failed: HResult=' + $_.Exception.HResult + ' ' + $_.Exception.Message)
        $result = Invoke-CimMethod -ClassName Win32_ComputerSystem -MethodName Rename -Arguments @{ Name = $NewName }
        if ($result.ReturnValue -eq 0) {
            $renamed = $true
            Write-Log 'Win32_ComputerSystem.Rename succeeded.'
        }
        else {
            Write-Log ('Win32_ComputerSystem.Rename failed with return value ' + $result.ReturnValue)
        }
    }
    if (-not $renamed) {
        exit 12
    }

    $staged = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\ComputerName\ComputerName' -Name 'ComputerName').ComputerName
    Write-Log ('Staged name in registry: ' + $staged)
    if ($staged -ne $NewName) {
        Write-Log 'ERROR: post-rename verification failed.'
        exit 13
    }

    Write-Log 'Rename staged. Restart required to complete.'
    exit 0
}
catch {
    Write-Log ('UNHANDLED ERROR: ' + $_.Exception.Message)
    exit 12
}
