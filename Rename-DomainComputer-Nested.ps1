<#
.SYNOPSIS
    Diagnostic payload for BigFix task "Rename Domain-Joined Windows Computer", Action 3
    ("Nested Start-Process -Credential rename"). Renames a domain-joined Windows computer by
    having a SYSTEM-launched PowerShell process spawn a second, inner PowerShell process logged
    on as the supplied domain account (via Start-Process -Credential), and doing the actual
    rename entirely inside that inner process's own logon session.

.DESCRIPTION
    Exists to test whether RPC error 1783 (RPC_X_BAD_STUB_DATA), seen when renaming under
    BigFix's own 'override runas=localuser / asadmin=true', is specific to BigFix's token
    creation or inherent to any CreateProcessWithLogonW-style logon (Start-Process -Credential
    uses the same underlying Windows API, just via a different code path).

    IMPORTANT: unlike Action 1, this does NOT synthesize local Administrator rights.
    'asadmin=true' is a BigFix-specific capability with no PowerShell equivalent; under UAC,
    Start-Process -Credential normally hands the inner process the *filtered*, non-elevated
    token even for a genuine local admin. AdminUser must already be a local Administrator on
    this endpoint AND not subject to UAC filtering of non-interactive logons, or the inner
    process will fail the "Elevated" check below with exit 12.

    Exit codes: same as Rename-DomainComputer.ps1 (0/10/11/12/13).

.NOTES
    2026-09-01 atlauren / Claude

    This file is the editable source of truth for Action 3's embedded script. The copy embedded
    in the .bes createfile block must have every { and } doubled to {{ and }}. Keep in sync.
#>
#Requires -Version 5.0
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string] $NewName,

    [string] $AdminUser = '',

    # Path to a one-time file holding the domain account's password; read, then deleted.
    [string] $CredentialFile = '',

    # Set automatically when this script re-invokes itself as AdminUser; do not pass by hand.
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

function Get-AdminCredential {
    param([string] $UserName, [string] $Path)
    if (-not $UserName -or -not $Path -or -not (Test-Path -LiteralPath $Path)) {
        return $null
    }
    $secret = (Get-Content -LiteralPath $Path -Raw).TrimEnd("`r", "`n")
    $securePw = ConvertTo-SecureString -String $secret -AsPlainText -Force
    [PSCredential]::new($UserName, $securePw)
}

try {
    New-Item -ItemType Directory -Path (Split-Path -Parent $LogPath) -Force | Out-Null

    if (-not $Inner) {
        # --- Outer phase: runs as SYSTEM. Spawns the inner phase logged on as AdminUser. ---
        Write-Log ('--- BigFix action ' + $ActionId + ' started (outer/SYSTEM) ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz') + ' ---')
        Write-Log ('Running as: ' + [Security.Principal.WindowsIdentity]::GetCurrent().Name)

        $cred = Get-AdminCredential -UserName $AdminUser -Path $CredentialFile
        if (-not $cred) {
            Write-Log 'ERROR: no admin credential available to launch the inner process.'
            exit 12
        }

        $self = $MyInvocation.MyCommand.Path
        $workDir = Split-Path -Parent $self
        $stdoutFile = Join-Path $workDir 'inner-stdout.log'
        $stderrFile = Join-Path $workDir 'inner-stderr.log'
        Remove-Item -LiteralPath $stdoutFile, $stderrFile -Force -ErrorAction SilentlyContinue
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'

        $innerArgs = @(
            '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', $self,
            '-NewName', $NewName, '-AdminUser', $AdminUser, '-CredentialFile', $CredentialFile,
            '-Inner', '-ActionId', $ActionId, '-LogPath', $LogPath
        )

        $exitCode = 12
        try {
            $proc = Start-Process -FilePath $psExe -Credential $cred -ArgumentList $innerArgs `
                -WindowStyle Hidden -Wait -PassThru `
                -RedirectStandardOutput $stdoutFile -RedirectStandardError $stderrFile
            $exitCode = $proc.ExitCode
        }
        catch {
            Write-Log ('ERROR: could not start the inner process as ' + $AdminUser + ': ' + $_.Exception.Message)
        }
        finally {
            $cred = $null
            Remove-Item -LiteralPath $CredentialFile -Force -ErrorAction SilentlyContinue
        }

        foreach ($f in @($stdoutFile, $stderrFile)) {
            if (Test-Path -LiteralPath $f) {
                Get-Content -LiteralPath $f | Where-Object { $_ } | ForEach-Object { Write-Log ('[inner] ' + $_) }
                Remove-Item -LiteralPath $f -Force -ErrorAction SilentlyContinue
            }
        }

        Write-Log ('Inner process exit code: ' + $exitCode)
        exit $exitCode
    }

    # --- Inner phase: runs as AdminUser, via Start-Process -Credential above. ---
    Write-Log ('--- BigFix action ' + $ActionId + ' started (inner/' + $AdminUser + ') ' + (Get-Date).ToString('yyyy-MM-dd HH:mm:ss zzz') + ' ---')
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

    $cred = Get-AdminCredential -UserName $AdminUser -Path $CredentialFile
    Remove-Item -LiteralPath $CredentialFile -Force -ErrorAction SilentlyContinue

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
        if ($cred) {
            Rename-Computer -NewName $NewName -DomainCredential $cred -Force -ErrorAction Stop
        }
        else {
            Rename-Computer -NewName $NewName -Force -ErrorAction Stop
        }
        $renamed = $true
        Write-Log 'Rename-Computer succeeded.'
    }
    catch {
        Write-Log ('Rename-Computer failed: HResult=' + $_.Exception.HResult + ' ' + $_.Exception.Message)
        $cimArgs = @{ Name = $NewName }
        if ($cred) {
            $cimArgs['UserName'] = $cred.UserName
            $cimArgs['Password'] = $cred.GetNetworkCredential().Password
        }
        $result = Invoke-CimMethod -ClassName Win32_ComputerSystem -MethodName Rename -Arguments $cimArgs
        if ($result.ReturnValue -eq 0) {
            $renamed = $true
            Write-Log 'Win32_ComputerSystem.Rename succeeded.'
        }
        else {
            Write-Log ('Win32_ComputerSystem.Rename failed with return value ' + $result.ReturnValue)
        }
    }
    finally {
        $cred = $null
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
