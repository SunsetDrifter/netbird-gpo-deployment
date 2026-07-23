# Verifying a deployment

Checks in the order an admin actually runs them: registry first (did policy
land?), then daemon state, then logs, then enforced behavior. All commands
run on the deployed client in an elevated PowerShell unless noted.

## 1. Managed policy landed in the registry

```powershell
reg query HKLM\Software\Policies\NetBird
```

Expected for the hardened-workstation profile:

```
HKEY_LOCAL_MACHINE\Software\Policies\NetBird
    ManagementURL            REG_SZ    https://api.example.com:443
    BlockInbound             REG_DWORD 0x1
    DisableServerRoutes      REG_DWORD 0x1
    DisableAutoConnect       REG_DWORD 0x1
    DisableProfiles          REG_DWORD 0x1
    DisableUpdateSettings    REG_DWORD 0x1
```

Missing key entirely? The policy GPO did not apply; check `gpresult /r`
for the GPO name and scoping.

## 2. Install and daemon state

```powershell
netbird status -d
```

Shows daemon version, management URL, connection state, and active
settings. Before first user connect, `Disconnected` is the expected state:
policy writes never trigger a connection.

Deployment script log (install path, signature check, msiexec result):

```powershell
Get-Content "$env:ProgramData\NetBird\netbird-deploy.log"
```

Verbose MSI log, if the install itself failed:
`%ProgramData%\NetBird\netbird-install.log`.

## 3. Client log shows the MDM overlay

The daemon logs the policy overlay at config load (service start or
connect). In the client log
(`C:\Program Files\NetBird\client.log`, or wherever `netbird status -d`
reports the daemon logging):

```
MDM enrolled with 6 managed key(s): [blockInbound disableAutoConnect disableProfiles disableServerRoutes disableUpdateSettings managementURL]
MDM override managementURL = https://api.example.com:443
MDM override blockInbound = true
```

One `MDM override <key> = <value>` line per enforced key. The
`preSharedKey` value, if managed, appears only as
`MDM override preSharedKey = ********** (secret)`.

The daemon also re-reads the policy key once per minute (`MDM policy
reload ticker started (interval=1m0s)` in the log), so registry changes
take effect within about a minute of landing, no service restart needed.
Verified live on v0.74.7: flipping `BlockInbound` in the registry changed
ping behavior on the running tunnel within the ticker interval.

Log lines quoted from `client/mdm/policy.go` (LoadPolicy),
`client/mdm/ticker.go` (reload ticker), and
`client/internal/profilemanager/config.go` (applyMDMPolicy) in
netbirdio/netbird.

## 4. Behavioral checks

After the user has connected once (SSO completed):

- **BlockInbound**: from another NetBird peer, ping the deployed machine's
  NetBird IP. The ping times out. (Remember this also blocks RDP over
  NetBird to that peer.)
- **DisableUpdateSettings**: open the NetBird GUI settings; managed
  settings are read-only.
- **DisableProfiles**: the profile/account switcher is unavailable.
- **DisableAutoConnect**: after a reboot, the client stays disconnected
  until the user clicks Connect.
- **ManagementURL**: `netbird status -d` reports
  `https://api.example.com:443` as the management URL.

## 5. Common failure signatures

| Symptom | Likely cause | Fix |
|---|---|---|
| Registry key present, but `netbird status -d` shows the wrong URL | Daemon has not reloaded config since the policy landed | Wait up to a minute (MDM reload ticker) or restart the NetBird service |
| `netbird up` with config flags fails with `update settings are disabled` | `DisableUpdateSettings` is enforced, and it blocks CLI config writes too (verified on v0.74.7) | Working as designed: make the change via policy instead, or lift `DisableUpdateSettings` |
| Key absent after reboot | GPO not applied to this computer | `gpresult /r`, check OU link and WMI filter |
| Install log shows signature error | MSI download corrupted or intercepted (TLS inspection) | Pre-stage the MSI on a share and pass `-MsiSource`, or exempt pkgs.netbird.io from interception |
| `netbird-deploy.log` missing | Startup script never ran | Check the Scripts policy, execution policy, and share ACLs for the computer account |
