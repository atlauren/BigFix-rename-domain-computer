<#
.SYNOPSIS
    Renames a domain-joined Windows computer from the BigFix agent's own SYSTEM context,
    using an explicit -DomainCredential for the Active Directory side of the rename.
    Payload for the BigFix task "Rename Domain-Joined Windows Computer (SYSTEM +
    DomainCredential, Secure Parameters)".

.DESCRIPTION
    No local logon token is created for the supplied account. The process stays as
    NT AUTHORITY\SYSTEM, which is already fully elevated locally, and the domain account is
    used only as network credentials for the AD computer-object update. That deliberately
    avoids every local-logon path that has failed on this endpoint: BigFix's own
    'override runas=localuser' (RPC 1783), Start-Process -Credential (session 0 window
    station, access denied), and Task Scheduler's batch logon.

    Because SYSTEM supplies the local privileges, the domain account does NOT need to be a
    local Administrator on the endpoint - only to hold rights on the computer's AD object.

    The password is read from a one-time file written by the action script into an ACL'd
    folder, then deleted. It is never placed on a command line.

    Exit codes:
      0  renamed successfully, or already correctly named
      10 invalid NetBIOS computer name
      11 an AD computer object with that name already exists
      12 rename failed / not elevated
      13 post-rename verification failed
      14 no usable domain credential

.NOTES
    2026-09-02 atlauren / Claude

    This file is the editable source of truth. The copy embedded in the .bes createfile
    block must have every literal { doubled to {{ (closing } stay single), because BigFix
    performs relevance substitution on createfile bodies. Keep the two in sync.
#>
#Requires -Version 5.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $NewName,

    [string] $AdminUser = '',

    # Path to a one-time file holding the domain account's password; read, then deleted.
    [string] $CredentialFile = '',

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

function Get-AdminCredential {
    param([string] $UserName, [string] $Path)
    if (-not $UserName -or -not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $secret = (Get-Content -LiteralPath $Path -Raw).TrimEnd("`r", "`n")
    if (-not $secret) {
        return $null
    }
    $securePw = ConvertTo-SecureString -String $secret -AsPlainText -Force
    [PSCredential]::new($UserName, $securePw)
}

$cred = $null
try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null
    Write-Log ('--- BigFix action ' + $ActionId + ' started (SYSTEM + DomainCredential) ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz') + ' ---')
    Write-Log ('Rename requested: ' + $NewName)

    $me = [Security.Principal.WindowsIdentity]::GetCurrent()
    Write-Log ('Running as: ' + $me.Name)
    $isAdmin = [Security.Principal.WindowsPrincipal]::new($me).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    Write-Log ('Elevated: ' + $isAdmin)
    if (-not $isAdmin) {
        Write-Log 'ERROR: not running with an Administrators token.'
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

    $cred = Get-AdminCredential -UserName $AdminUser -Path $CredentialFile
    if (-not $cred) {
        Write-Log 'ERROR: no domain credential available; SYSTEM authenticates to AD as COMPUTER$ and cannot rewrite its own object.'
        exit 14
    }
    Write-Log ('Domain credential built for: ' + $cred.UserName)

    # SYSTEM reads AD as COMPUTER$, which is enough for this lookup.
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
        Rename-Computer -NewName $NewName -DomainCredential $cred -Force -ErrorAction Stop
        $renamed = $true
        Write-Log 'Rename-Computer succeeded.'
    }
    catch {
        Write-Log ('Rename-Computer failed: HResult=' + $_.Exception.HResult + ' ' + $_.Exception.Message)
        $cimArgs = @{
            Name     = $NewName
            UserName = $cred.UserName
            Password = $cred.GetNetworkCredential().Password
        }
        $result = Invoke-CimMethod -ClassName Win32_ComputerSystem -MethodName Rename -Arguments $cimArgs
        $cimArgs = $null
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
finally {
    # Runs even on 'exit', so the secret never outlives the script regardless of which path ran.
    $cred = $null
    if ($CredentialFile) {
        Remove-Item -LiteralPath $CredentialFile -Force -ErrorAction SilentlyContinue
    }
}
