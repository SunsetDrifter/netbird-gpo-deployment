#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    GPO computer-startup script: writes NetBird MDM policy, then silently
    installs the NetBird client MSI.

.DESCRIPTION
    Single-pass deployment for Windows domain clients. Runs as SYSTEM via a
    GPO computer-startup script (also works from Intune, RMM, or SCCM in
    SYSTEM context).

    Order of operations:
      1. Write managed policy to HKLM\Software\Policies\NetBird, either by
         importing a .reg profile (-PolicyFile) or from direct parameters
         (-ManagementURL plus lockdown switches). Writing policy triggers no
         connection attempt; the daemon overlays it at config load.
      2. Skip install if NetBird is already present (idempotent re-runs;
         policy is still refreshed).
      3. Download the MSI from pkgs.netbird.io, or use a UNC/local path.
      4. Verify the Authenticode signature before executing anything.
      5. Silent install: msiexec /i /qn /norestart with a verbose MSI log.

    No console output. All activity is logged to
    %ProgramData%\NetBird\netbird-deploy.log for admin review.

    Requires NetBird client v0.73.0 or later for MDM policy support.

.PARAMETER MsiSource
    Where to get the MSI. Either an https URL (default:
    https://pkgs.netbird.io/windows/msi/x64) or a UNC/local path to a
    pre-staged MSI, e.g. \\fileserver\software\netbird.msi.

.PARAMETER PolicyFile
    Path (UNC or local) to a .reg policy profile to import before install.
    See the policy\profiles\ directory in this repo. Mutually exclusive
    with the direct policy parameters below.

.PARAMETER ManagementURL
    Management URL to write as managed policy, including the explicit port,
    e.g. https://api.example.com:443. Omit for NetBird Cloud.

.PARAMETER BlockInbound
    Write BlockInbound=1: the peer accepts no inbound connections.

.PARAMETER DisableServerRoutes
    Write DisableServerRoutes=1: the peer cannot act as a routing peer.

.PARAMETER DisableClientRoutes
    Write DisableClientRoutes=1: the peer does not install routes to
    network resources.

.PARAMETER DisableAutoConnect
    Write DisableAutoConnect=1: the client does not connect automatically
    at service start; the user connects explicitly.

.PARAMETER DisableProfiles
    Write DisableProfiles=1: the user cannot switch NetBird profiles
    (accounts).

.PARAMETER DisableUpdateSettings
    Write DisableUpdateSettings=1: GUI settings are read-only for the user.

.PARAMETER MinimumVersion
    Version floor, e.g. 0.75.0. Without it, the script is install-once:
    any existing NetBird install is left at its version. With it, an
    installed version below the floor triggers an in-place MSI upgrade
    (user data and peer identity survive; the service restarts). Raise
    the floor in the GPO script parameters when you decide the fleet
    should move. The script refuses to run msiexec if the MSI at
    MsiSource is not actually newer than the installed version, so a
    stale share cannot cause an install loop.

.PARAMETER NoAutostart
    Install with AUTOSTART=0: the MSI then skips its machine-wide Run
    entry (HKLM\...\CurrentVersion\Run), so the tray UI does not launch
    at user login. Note this is the installer's autostart, separate from
    the DisableAutostart MDM policy, which only governs the GUI's own
    launch-on-login setting and does not remove the installer's Run key.

.NOTES
    Run as SYSTEM or Administrator. PowerShell 5.1 compatible.
    Reference: https://docs.netbird.io/client/mdm-integration
    Reference: https://docs.netbird.io/get-started/install/windows

.EXAMPLE
    Deploy-NetBird.ps1 -PolicyFile '\\domain.example.com\SYSVOL\domain.example.com\scripts\hardened-workstation.reg'

.EXAMPLE
    Deploy-NetBird.ps1 -ManagementURL 'https://api.example.com:443' -BlockInbound -DisableServerRoutes -DisableUpdateSettings

.EXAMPLE
    Deploy-NetBird.ps1 -MsiSource '\\fileserver\software\netbird.msi' -PolicyFile '\\fileserver\software\standard-workstation.reg'
#>

[CmdletBinding()]
param(
    [string]$MsiSource     = 'https://pkgs.netbird.io/windows/msi/x64',
    [string]$PolicyFile,
    [string]$ManagementURL,
    [switch]$BlockInbound,
    [switch]$DisableServerRoutes,
    [switch]$DisableClientRoutes,
    [switch]$DisableAutoConnect,
    [switch]$DisableProfiles,
    [switch]$DisableUpdateSettings,
    [version]$MinimumVersion,
    [switch]$NoAutostart,
    [string]$DownloadPath  = "$env:TEMP\netbird-installer.msi",
    [string]$MsiLogPath    = "$env:ProgramData\NetBird\netbird-install.log",
    [string]$ScriptLogPath = "$env:ProgramData\NetBird\netbird-deploy.log"
)

$ErrorActionPreference = 'Stop'
$PolicyKeyPath = 'HKLM:\SOFTWARE\Policies\NetBird'

# ---------------------------------------------------------------------------
# Logging setup (file only, no console)
# ---------------------------------------------------------------------------
$logDir = Split-Path $ScriptLogPath -Parent
if (-not (Test-Path $logDir)) {
    New-Item -ItemType Directory -Path $logDir -Force | Out-Null
}

function Write-Log {
    param(
        [Parameter(Mandatory)] [string]$Message,
        [ValidateSet('INFO','WARN','ERROR')] [string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    "$ts [$Level] $Message" | Out-File -FilePath $ScriptLogPath -Append -Encoding UTF8
}

# Force TLS 1.2 (older PS hosts default to TLS 1.0/1.1)
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

Write-Log "===== NetBird GPO deployment starting ====="

# ---------------------------------------------------------------------------
# 1. Write managed policy BEFORE install
#    Values land in HKLM\Software\Policies\NetBird. The daemon reads them at
#    config load; writing them triggers no connection attempt.
# ---------------------------------------------------------------------------
$directPolicyParams = @('ManagementURL','BlockInbound','DisableServerRoutes',
                        'DisableClientRoutes','DisableAutoConnect',
                        'DisableProfiles','DisableUpdateSettings')
$directPolicyBound = @($directPolicyParams | Where-Object { $PSBoundParameters.ContainsKey($_) })

if ($PolicyFile -and $directPolicyBound.Count -gt 0) {
    Write-Log "-PolicyFile cannot be combined with direct policy parameters ($($directPolicyBound -join ', '))." 'ERROR'
    exit 2
}

if ($PolicyFile) {
    if (-not (Test-Path $PolicyFile)) {
        Write-Log "Policy file not found: $PolicyFile" 'ERROR'
        exit 2
    }
    Write-Log "Importing policy file: $PolicyFile"
    $regProc = Start-Process -FilePath 'reg.exe' `
                             -ArgumentList @('import', "`"$PolicyFile`"") `
                             -Wait -PassThru -WindowStyle Hidden
    if ($regProc.ExitCode -ne 0) {
        Write-Log "reg.exe import failed with exit code $($regProc.ExitCode)." 'ERROR'
        exit 2
    }
    Write-Log "Policy file imported."
}
elseif ($directPolicyBound.Count -gt 0) {
    if (-not (Test-Path $PolicyKeyPath)) {
        New-Item -Path $PolicyKeyPath -Force | Out-Null
    }
    if ($ManagementURL) {
        New-ItemProperty -Path $PolicyKeyPath -Name 'ManagementURL' `
                         -PropertyType String -Value $ManagementURL -Force | Out-Null
        Write-Log "Policy ManagementURL = $ManagementURL"
    }
    foreach ($name in @('BlockInbound','DisableServerRoutes','DisableClientRoutes',
                        'DisableAutoConnect','DisableProfiles','DisableUpdateSettings')) {
        if ($PSBoundParameters.ContainsKey($name)) {
            $value = if ($PSBoundParameters[$name].IsPresent) { 1 } else { 0 }
            New-ItemProperty -Path $PolicyKeyPath -Name $name `
                             -PropertyType DWord -Value $value -Force | Out-Null
            Write-Log "Policy $name = $value"
        }
    }
}
else {
    Write-Log "No policy parameters given; skipping policy write (install only)."
}

# ---------------------------------------------------------------------------
# 2. Skip install if NetBird is already installed (idempotent for re-runs;
#    the policy above has still been refreshed). With -MinimumVersion, an
#    installed version below the floor falls through to an in-place upgrade.
# ---------------------------------------------------------------------------
$uninstallKeys = @(
    'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
    'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
)
$existing = Get-ItemProperty $uninstallKeys -ErrorAction SilentlyContinue |
            Where-Object { $_.DisplayName -like 'NetBird*' }

$installedVersion = $null
if ($existing) {
    if (-not $MinimumVersion) {
        Write-Log "NetBird already installed (version $($existing.DisplayVersion)). Policy refreshed; skipping install."
        exit 0
    }
    if (-not [version]::TryParse($existing.DisplayVersion, [ref]$installedVersion)) {
        Write-Log "Installed version '$($existing.DisplayVersion)' is not parseable; leaving it untouched." 'WARN'
        exit 0
    }
    if ($installedVersion -ge $MinimumVersion) {
        Write-Log "NetBird $installedVersion meets the $MinimumVersion floor. Policy refreshed; skipping install."
        exit 0
    }
    Write-Log "NetBird $installedVersion is below the $MinimumVersion floor; upgrading in place."
}

# ---------------------------------------------------------------------------
# 3. Obtain the MSI: download from URL, or use a UNC/local path
# ---------------------------------------------------------------------------
$downloaded = $false
if ($MsiSource -match '^https://') {
    Write-Log "Downloading MSI from $MsiSource"
    try {
        Invoke-WebRequest -Uri $MsiSource -OutFile $DownloadPath -UseBasicParsing
    }
    catch {
        Write-Log "Download failed: $($_.Exception.Message)" 'ERROR'
        exit 1
    }
    $msiPath = $DownloadPath
    $downloaded = $true
}
else {
    if (-not (Test-Path $MsiSource)) {
        Write-Log "MSI not found at $MsiSource" 'ERROR'
        exit 1
    }
    if ($MsiSource -like '\\*') {
        # Copy UNC sources local: msiexec is more reliable against a local
        # file, and the WindowsInstaller COM API (upgrade guard) cannot
        # open a database over UNC.
        Write-Log "Copying MSI from $MsiSource to $DownloadPath"
        Copy-Item -Path $MsiSource -Destination $DownloadPath -Force
        $msiPath = $DownloadPath
        $downloaded = $true
    }
    else {
        Write-Log "Using MSI from $MsiSource"
        $msiPath = $MsiSource
    }
}

if (-not (Test-Path $msiPath) -or (Get-Item $msiPath).Length -lt 1MB) {
    Write-Log "MSI file is missing or unexpectedly small." 'ERROR'
    exit 1
}

# ---------------------------------------------------------------------------
# 4. Verify Authenticode signature before executing
# ---------------------------------------------------------------------------
$sig = Get-AuthenticodeSignature -FilePath $msiPath
if ($sig.Status -ne 'Valid') {
    Write-Log "MSI signature is not valid (Status: $($sig.Status)). Aborting." 'ERROR'
    if ($downloaded) { Remove-Item $msiPath -Force -ErrorAction SilentlyContinue }
    exit 1
}
Write-Log "Signature verified. Signer: $($sig.SignerCertificate.Subject)"

# ---------------------------------------------------------------------------
# 5. Upgrade guard: never run msiexec against an MSI that is not newer than
#    the installed version (a stale MsiSource would otherwise re-trigger
#    every boot once -MinimumVersion is raised past it)
# ---------------------------------------------------------------------------
if ($installedVersion) {
    # Read ProductVersion in a child process: the WindowsInstaller COM
    # object keeps the MSI open for the lifetime of its process, which
    # would block Remove-Item and msiexec in this one.
    $readVersion = {
        $i = New-Object -ComObject WindowsInstaller.Installer
        $d = $i.GetType().InvokeMember('OpenDatabase', 'InvokeMethod', $null, $i, @($args[0], 0))
        $v = $d.GetType().InvokeMember('OpenView', 'InvokeMethod', $null, $d,
                                       @("SELECT Value FROM Property WHERE Property = 'ProductVersion'"))
        $v.GetType().InvokeMember('Execute', 'InvokeMethod', $null, $v, $null)
        $r = $v.GetType().InvokeMember('Fetch', 'InvokeMethod', $null, $v, $null)
        $r.GetType().InvokeMember('StringData', 'GetProperty', $null, $r, @(1))
    }
    $msiVersion = $null
    $raw = & powershell.exe -NoProfile -NonInteractive -Command $readVersion -args (Resolve-Path $msiPath).Path 2>$null
    if (-not [version]::TryParse(($raw | Select-Object -Last 1), [ref]$msiVersion)) {
        Write-Log "Could not read ProductVersion from the MSI (got: '$raw')." 'ERROR'
        if ($downloaded) { Remove-Item $msiPath -Force -ErrorAction SilentlyContinue }
        exit 1
    }
    if ($msiVersion -le $installedVersion) {
        Write-Log "MSI at $MsiSource is $msiVersion, not newer than installed $installedVersion; cannot satisfy the $MinimumVersion floor. Update the MSI source." 'ERROR'
        if ($downloaded) { Remove-Item $msiPath -Force -ErrorAction SilentlyContinue }
        exit 1
    }
    Write-Log "Upgrading from $installedVersion to $msiVersion."
}

# ---------------------------------------------------------------------------
# 6. Silent install via msiexec
# ---------------------------------------------------------------------------
Write-Log "Launching msiexec in silent mode."
$msiArgs = @(
    '/i', "`"$msiPath`"",
    '/qn',
    '/norestart',
    '/l*v', "`"$MsiLogPath`""
)
if ($NoAutostart) {
    $msiArgs += 'AUTOSTART=0'
    Write-Log "AUTOSTART=0: installer will not register the tray UI for launch at user login."
}
$proc = Start-Process -FilePath 'msiexec.exe' `
                      -ArgumentList $msiArgs `
                      -Wait `
                      -PassThru `
                      -WindowStyle Hidden

if ($proc.ExitCode -ne 0) {
    Write-Log "Install failed with exit code $($proc.ExitCode). See $MsiLogPath" 'ERROR'
    exit $proc.ExitCode
}

# ---------------------------------------------------------------------------
# 7. Cleanup
# ---------------------------------------------------------------------------
if ($downloaded) {
    Remove-Item $msiPath -Force -ErrorAction SilentlyContinue
}
Write-Log "NetBird installed successfully. Daemon service is running; managed policy applies at config load."
Write-Log "===== NetBird GPO deployment complete ====="
exit 0
