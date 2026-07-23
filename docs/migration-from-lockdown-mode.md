# Migrating from netbird-windows-lockdown-mode

The old repo enforced lockdown with CLI flags across two boot/login cycles:
install on first boot, `netbird up` with security flags at first login,
`netbird service reconfigure` lockdown on the second boot, with marker
files (`.flags-applied`, `.lockdown-applied`) tracking progress. MDM policy
support (client v0.73.0+) makes all of that obsolete: managed registry
values enforce the same settings in a single pass, before the client ever
starts, and MDM values win over locally set flags at every config load.

## Flag to policy mapping

| Old flag (CLI) | Policy value (`HKLM\Software\Policies\NetBird`) | Type |
|---|---|---|
| `--block-inbound` | `BlockInbound` = 1 | REG_DWORD |
| `--disable-server-routes` | `DisableServerRoutes` = 1 | REG_DWORD |
| `--disable-auto-connect` | `DisableAutoConnect` = 1 | REG_DWORD |
| `--disable-update-settings` | `DisableUpdateSettings` = 1 | REG_DWORD |
| `--disable-profiles` | `DisableProfiles` = 1 | REG_DWORD |
| `--block-lan-access` | No MDM policy key as of v0.75 | see below |
| (management URL via `--management-url` / `service reconfigure`) | `ManagementURL` | REG_SZ |

**`--block-lan-access` has no MDM equivalent** (verified against
`client/mdm/policy.go`, July 2026). If your posture needs it, keep setting
it as a CLI flag (`netbird up --block-lan-access`); the flag persists in
the client config across reconnects. Everything else moves to policy.

## Migration steps per machine

Run elevated, in this order:

1. Delete the old marker files (they only gated the old scripts, but left
   behind they will confuse future audits):

   ```powershell
   Remove-Item C:\ProgramData\Netbird\.flags-applied, C:\ProgramData\Netbird\.lockdown-applied -ErrorAction SilentlyContinue
   ```

2. Strip the flags the old scripts persisted as service arguments:

   ```powershell
   netbird service reconfigure
   ```

   With no flags, this rewrites the service definition without the old
   lockdown arguments.

3. Apply the registry policy, either via the new policy GPO
   ([gpo-setup.md](gpo-setup.md)) or directly:

   ```powershell
   .\Set-NetBirdPolicy.ps1 -ManagementURL 'https://api.example.com:443' -BlockInbound -DisableServerRoutes -DisableAutoConnect -DisableProfiles -DisableUpdateSettings
   ```

4. Restart the service (or have the user reconnect) and verify with
   [verification.md](verification.md).

Strict ordering matters only for steps 2 and 3 on paper; in practice even
that is forgiving, because MDM values are the highest-priority layer and
override locally persisted flags at every config load. Doing step 2 anyway
keeps the service definition clean instead of relying on the override.

Two gotchas verified live on v0.74.7:

- **Removing a `ManagementURL` policy value does not revert the daemon to
  its previous URL.** The overlaid URL persists in the local client
  config, so the peer keeps targeting it. To change servers, set the new
  URL via policy; do not just delete the old value.
- **`DisableUpdateSettings` also blocks CLI config changes.** Once
  enforced, `netbird up --management-url ...` (and any flag that writes
  config) is rejected with `update settings are disabled`. That is the
  point of the policy: the managed channel becomes the only way to change
  managed settings. Plan the migration so the URL is correct in policy
  before the lockdown lands, or apply `DisableUpdateSettings` last.

## Replace the old GPOs

- Remove the User Logon script GPO entry (`Deploy-NetBird-Logon.ps1`)
  entirely. Connection and SSO are user actions in the tray UI; no script
  is needed.
- Replace the old startup script with `scripts/Deploy-NetBird.ps1` and add
  the policy GPO. New machines then deploy fully configured in one boot.
