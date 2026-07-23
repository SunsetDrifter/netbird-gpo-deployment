#Requires -Version 5.1
#Requires -RunAsAdministrator

<#
.SYNOPSIS
    Writes NetBird MDM managed policy values to HKLM\Software\Policies\NetBird.

.DESCRIPTION
    Standalone policy writer: no install, no connection attempt. The NetBird
    daemon (v0.73.0 or later) overlays these values onto the client config at
    config load, as the highest-priority layer (above CLI flags, env vars,
    and on-disk config).

    Only parameters you explicitly pass are written. Boolean policies are
    switches: present means 1 (enforced on), and the explicit negation form
    -BlockInbound:$false writes 0 (enforced off). A value that is absent
    from the registry is unmanaged, so the user or CLI keeps control of it;
    use -RemoveValue to return a value to the unmanaged state.

    Supports -WhatIf and -Confirm. Prints the resulting key state on
    completion. The PreSharedKey value is never printed or logged; it is
    shown redacted, mirroring the client's own log redaction.

.PARAMETER ManagementURL
    Management URL including the explicit port, e.g.
    https://api.example.com:443 (REG_SZ).

.PARAMETER PreSharedKey
    WireGuard pre-shared key (REG_SZ): an extra symmetric encryption layer
    on the tunnels. Not an enrollment/setup key; registration still
    happens via SSO or netbird up --setup-key. Secret: never echoed or
    logged. Anyone with local admin rights can read this registry value,
    so prefer distribution channels scoped to the machines that need it.

.PARAMETER DisableUpdateSettings
    GUI settings are read-only for the user (REG_DWORD).

.PARAMETER DisableProfiles
    User cannot switch NetBird profiles/accounts (REG_DWORD).

.PARAMETER DisableNetworks
    Hide/disable the Networks view in the client UI (REG_DWORD).

.PARAMETER DisableAdvancedView
    Hide the advanced-view section in the client UI (REG_DWORD). UI-only.

.PARAMETER DisableClientRoutes
    Peer does not install routes to network resources (REG_DWORD).

.PARAMETER DisableServerRoutes
    Peer cannot act as a routing peer (REG_DWORD).

.PARAMETER BlockInbound
    Peer accepts no inbound connections (REG_DWORD).

.PARAMETER DisableMetricsCollection
    Reserved by upstream; no metrics pipeline consumes it yet (REG_DWORD).

.PARAMETER AllowServerSSH
    Allow the embedded SSH server on this peer (REG_DWORD).

.PARAMETER DisableAutoConnect
    Client does not connect automatically at service start (REG_DWORD).

.PARAMETER DisableAutostart
    Suppress the GUI's own launch-on-login default (REG_DWORD). UI-only,
    and it does not remove the MSI installer's machine-wide Run entry;
    to stop the tray UI launching at login entirely, install with
    Deploy-NetBird.ps1 -NoAutostart (msiexec AUTOSTART=0).

.PARAMETER RosenpassEnabled
    Enable Rosenpass post-quantum key exchange (REG_DWORD).

.PARAMETER RosenpassPermissive
    Allow connections to peers without Rosenpass (REG_DWORD).

.PARAMETER WireguardPort
    Local WireGuard listen port, 1-65535 (REG_DWORD).

.PARAMETER SplitTunnelMode
    'allow' or 'disallow' (REG_SZ). Parsed but ignored on Windows as of
    v0.75; defined for parity with mobile platforms.

.PARAMETER SplitTunnelApps
    Comma-separated app list for split tunnel (REG_SZ). Parsed but ignored
    on Windows as of v0.75.

.PARAMETER LazyConnection
    Force the lazy-connection feature on (or off with :$false), overriding
    the management feature flag (REG_DWORD). Registry-only key; not in the
    upstream ADMX.

.PARAMETER RemoveValue
    One or more value names to delete from the policy key, returning them
    to the unmanaged state.

.NOTES
    Run as Administrator. PowerShell 5.1 compatible.
    Reference: https://docs.netbird.io/client/mdm-integration
    Canonical key list: client/mdm/policy.go in netbirdio/netbird.
    Value names are canonicalized case-insensitively by the client; this
    script uses the upstream ADMX casing.

.EXAMPLE
    Set-NetBirdPolicy.ps1 -ManagementURL 'https://api.example.com:443' -BlockInbound -DisableUpdateSettings

.EXAMPLE
    Set-NetBirdPolicy.ps1 -BlockInbound:$false -WhatIf

.EXAMPLE
    Set-NetBirdPolicy.ps1 -RemoveValue BlockInbound,DisableProfiles
#>

[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$ManagementURL,
    [string]$PreSharedKey,
    [switch]$DisableUpdateSettings,
    [switch]$DisableProfiles,
    [switch]$DisableNetworks,
    [switch]$DisableAdvancedView,
    [switch]$DisableClientRoutes,
    [switch]$DisableServerRoutes,
    [switch]$BlockInbound,
    [switch]$DisableMetricsCollection,
    [switch]$AllowServerSSH,
    [switch]$DisableAutoConnect,
    [switch]$DisableAutostart,
    [switch]$RosenpassEnabled,
    [switch]$RosenpassPermissive,
    [ValidateRange(1,65535)]
    [int]$WireguardPort,
    [ValidateSet('allow','disallow')]
    [string]$SplitTunnelMode,
    [string]$SplitTunnelApps,
    [switch]$LazyConnection,
    [string[]]$RemoveValue
)

$ErrorActionPreference = 'Stop'
$PolicyKeyPath = 'HKLM:\SOFTWARE\Policies\NetBird'

# Value names whose content must never be echoed, logged, or printed.
# Mirrors mdm.SecretKeys in client/mdm/policy.go.
$SecretValueNames = @('PreSharedKey')

# Canonical value name -> registry type. Casing matches the upstream ADMX.
$StringValues = @('ManagementURL','PreSharedKey','SplitTunnelMode','SplitTunnelApps')
$DwordSwitches = @('DisableUpdateSettings','DisableProfiles','DisableNetworks',
                   'DisableAdvancedView','DisableClientRoutes','DisableServerRoutes',
                   'BlockInbound','DisableMetricsCollection','AllowServerSSH',
                   'DisableAutoConnect','DisableAutostart','RosenpassEnabled',
                   'RosenpassPermissive','LazyConnection')

$boundNames = @(($StringValues + $DwordSwitches + @('WireguardPort')) |
                Where-Object { $PSBoundParameters.ContainsKey($_) })

if ($boundNames.Count -eq 0 -and -not $RemoveValue) {
    Write-Host "Nothing to do: pass at least one policy parameter or -RemoveValue."
    Write-Host "Current state of ${PolicyKeyPath}:"
}

# ---------------------------------------------------------------------------
# Ensure the policy key exists (only when we have something to write)
# ---------------------------------------------------------------------------
if ($boundNames.Count -gt 0 -and -not (Test-Path $PolicyKeyPath)) {
    if ($PSCmdlet.ShouldProcess($PolicyKeyPath, 'Create registry key')) {
        New-Item -Path $PolicyKeyPath -Force | Out-Null
    }
}

# ---------------------------------------------------------------------------
# Write bound values with correct registry types
# ---------------------------------------------------------------------------
foreach ($name in $StringValues) {
    if (-not $PSBoundParameters.ContainsKey($name)) { continue }
    $value = $PSBoundParameters[$name]
    $display = if ($SecretValueNames -contains $name) { '**********' } else { $value }
    if ($PSCmdlet.ShouldProcess("$PolicyKeyPath\$name", "Set REG_SZ to $display")) {
        New-ItemProperty -Path $PolicyKeyPath -Name $name `
                         -PropertyType String -Value $value -Force | Out-Null
        Write-Host "Set $name (REG_SZ) = $display"
    }
}

foreach ($name in $DwordSwitches) {
    if (-not $PSBoundParameters.ContainsKey($name)) { continue }
    $value = if ($PSBoundParameters[$name].IsPresent) { 1 } else { 0 }
    if ($PSCmdlet.ShouldProcess("$PolicyKeyPath\$name", "Set REG_DWORD to $value")) {
        New-ItemProperty -Path $PolicyKeyPath -Name $name `
                         -PropertyType DWord -Value $value -Force | Out-Null
        Write-Host "Set $name (REG_DWORD) = $value"
    }
}

if ($PSBoundParameters.ContainsKey('WireguardPort')) {
    if ($PSCmdlet.ShouldProcess("$PolicyKeyPath\WireguardPort", "Set REG_DWORD to $WireguardPort")) {
        New-ItemProperty -Path $PolicyKeyPath -Name 'WireguardPort' `
                         -PropertyType DWord -Value $WireguardPort -Force | Out-Null
        Write-Host "Set WireguardPort (REG_DWORD) = $WireguardPort"
    }
}

# ---------------------------------------------------------------------------
# Remove values returning them to the unmanaged state
# ---------------------------------------------------------------------------
foreach ($name in ($RemoveValue | Where-Object { $_ })) {
    if (-not (Test-Path $PolicyKeyPath)) { break }
    $prop = Get-ItemProperty -Path $PolicyKeyPath -Name $name -ErrorAction SilentlyContinue
    if (-not $prop) {
        Write-Host "Skip remove: $name is not set."
        continue
    }
    if ($PSCmdlet.ShouldProcess("$PolicyKeyPath\$name", 'Remove value')) {
        Remove-ItemProperty -Path $PolicyKeyPath -Name $name
        Write-Host "Removed $name (now unmanaged)."
    }
}

# ---------------------------------------------------------------------------
# Print resulting key state (PreSharedKey redacted)
# ---------------------------------------------------------------------------
Write-Host ""
Write-Host "Resulting state of ${PolicyKeyPath}:"
if (-not (Test-Path $PolicyKeyPath)) {
    Write-Host "  (key does not exist; no NetBird values are managed)"
}
else {
    $key = Get-Item $PolicyKeyPath
    if ($key.ValueCount -eq 0) {
        Write-Host "  (key exists but holds no values)"
    }
    foreach ($name in ($key.GetValueNames() | Sort-Object)) {
        $type = $key.GetValueKind($name)
        $display = if ($SecretValueNames -contains $name) {
            '**********'
        } else {
            $key.GetValue($name)
        }
        Write-Host ("  {0,-26} {1,-10} {2}" -f $name, $type, $display)
    }
}
Write-Host ""
Write-Host "Values apply at the next config load (service restart, netbird up, or UI connect)."
