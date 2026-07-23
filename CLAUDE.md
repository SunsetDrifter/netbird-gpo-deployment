# netbird-gpo-deployment

Community/SE-maintained reference for deploying NetBird to Windows domain
clients via Group Policy: managed policy (ADMX/registry) plus a silent MSI
install script. Owner: Jack (Solutions Engineer, NetBird).

## House style

- No em dashes anywhere. Use commas, colons, or parentheses.
- "Open source" is two words. NetBird is one word.
- Verdict first: lead with the conclusion, then the reasoning.
- Label claims: CONFIRMED (with citation) vs INFERENCE (unverified).
- PowerShell: 5.1 compatible, `#Requires -RunAsAdministrator`,
  `$ErrorActionPreference = 'Stop'`. GPO-executed scripts produce no
  console output; they log to `%ProgramData%\NetBird\netbird-deploy.log`.
- Scripts must never echo or log `PreSharedKey` values.
- No real customer URLs or tenant names; the running example is
  `https://api.example.com:443` and domain `domain.example.com`.

## The rule for behavior claims

Any NetBird behavior claim added to this repo must cite its source: a
file path in netbirdio/netbird or a docs.netbird.io URL, in a comment or
adjacent prose. No source, no claim.

## Verified fact base (July 2026, netbirdio/netbird main)

- The Windows daemon reads managed policy from
  `HKLM\Software\Policies\NetBird` (`client/mdm/policy_windows.go`).
  Value names are canonicalized case-insensitively.
- Policy is overlaid onto client config at config load
  (`client/internal/profilemanager/config.go`, `applyMDMPolicy`), as the
  highest-priority layer. Writing registry values triggers NO connection
  attempt; connection happens only on `netbird up` / UI connect.
- Policy keys (`client/mdm/policy.go`): `managementURL`, `preSharedKey`
  (secret, redacted in logs), `disableUpdateSettings`, `disableProfiles`,
  `disableNetworks`, `disableAdvancedView` (UI-only), `disableClientRoutes`,
  `disableServerRoutes`, `blockInbound`, `disableMetricsCollection`
  (reserved, no pipeline yet), `allowServerSSH`, `disableAutoConnect`,
  `disableAutostart` (UI-only), `rosenpassEnabled`, `rosenpassPermissive`,
  `wireguardPort`, `splitTunnelMode`/`splitTunnelApps` (parsed but ignored
  on Windows), `lazyConnection`.
- There is NO MDM key for `--block-lan-access` (as of v0.75).
- Minimum client version for MDM policy: v0.73.0. CONFIRMED: commit
  `2bcea9d` (PR #6374) is the first commit of `client/mdm/`, and v0.73.0
  is the earliest release tag containing it.
- Upstream ships `netbird.admx`, `netbird.adml`, `netbird-policy.reg`,
  `netbird-policy.reg.ps1` in `docs/`. ADMX covers every key except
  `lazyConnection`. ADMX valueName casing is PascalCase
  (e.g. `ManagementURL`); this repo matches it.
- `managementURL` should include the explicit port
  (`https://api.example.com:443`). A UI false-conflict bug on default-port
  URLs was fixed in netbird PR #6672; the explicit form is safe on all
  versions.
- `netbird service reconfigure --management-url <url>` persists the URL as
  a service argument without connecting (`client/cmd/service_installer.go`).
  Documented fallback only.
- MSI: silent install `msiexec /i <msi> /qn /norestart`; AUTOSTART
  property (default 1) writes UI autostart to
  `HKLM\Software\Microsoft\Windows\CurrentVersion\Run`. Download URL:
  `https://pkgs.netbird.io/windows/msi/x64`.
- Client log lines for the overlay: `MDM enrolled with N managed key(s):
  [...]` (`client/mdm/policy.go` LoadPolicy) and
  `MDM override <key> = <value>` with secrets rendered as
  `********** (secret)` (`config.go` applyMDMPolicy).
- The daemon re-reads the policy source once per minute
  (`client/mdm/ticker.go`, log line `MDM policy reload ticker started
  (interval=1m0s)`). Lab-verified on v0.74.7: a `BlockInbound` registry
  flip changed live tunnel behavior within the interval, no restart.
- `DisableUpdateSettings` blocks CLI config writes too: with it enforced,
  `netbird up --management-url ...` fails with `update settings are
  disabled` (lab-verified on v0.74.7).
- Removing a `ManagementURL` policy value does not revert the daemon's
  URL: the overlaid value persists in local client config
  (lab-verified on v0.74.7).
