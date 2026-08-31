<#
.SYNOPSIS
    Renames a domain-joined Windows computer. Payload for the BigFix task
    "Rename Domain-Joined Windows Computer".

.DESCRIPTION
    BigFix launches this through 'override runas=localuser / asadmin=true /
    password=required', so the process already carries the domain account's Kerberos
    identity and an Administrators token. No credential material is passed to, stored
    by, or handled in this script.

    Exit codes:
      0  renamed successfully, or already correctly named
      10 invalid NetBIOS computer name
      11 an AD computer object with that name already exists
      12 rename failed / not elevated
      13 post-rename verification failed

.NOTES
    2026-08-20 atlauren / Claude

    This file is the editable source of truth. The copy embedded in the .bes
    createfile block must have every { and } doubled to {{ and }}, because BigFix
    performs relevance substitution on createfile bodies. Keep the two in sync.
#>
#Requires -Version 5.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $NewName,

    [string] $ActionId = 'manual',

    # BigFix passes the authoritative path; this default only covers manual invocation.
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
    Write-Log ('--- BigFix action ' + $ActionId + ' started ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz') + ' ---')
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
        Rename-Computer -NewName $NewName -Force -ErrorAction Stop
        $renamed = $true
        Write-Log 'Rename-Computer succeeded.'
    }
    catch {
        # Rename-Computer may reject a null credential; the CIM method uses the caller's token.
        Write-Log ('Rename-Computer failed: ' + $_.Exception.Message)
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
