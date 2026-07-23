# Changes from the predecessor repos

This repo replaces two repos. Summary of what was carried, what was
dropped, and why.

## From netbird-windows-lockdown-mode

Dropped entirely:

- **`Deploy-NetBird-Logon.ps1` (user logon script).** Its job was running
  `netbird up` with security flags in user context. MDM policy (client
  v0.73.0+) enforces the same settings from
  `HKLM\Software\Policies\NetBird` before the client ever starts, and
  connection/SSO is a user action in the tray UI. No script needed.
- **Marker files `.flags-applied` and `.lockdown-applied`.** They existed
  only to sequence the two-boot flag dance. Registry policy is idempotent
  state, not a sequence, so there is nothing to track.
- **Second-boot lockdown pass (`netbird service reconfigure
  --disable-update-settings --disable-profiles`).** Replaced by
  `DisableUpdateSettings`/`DisableProfiles` policy values, which also win
  over any locally set flags at every config load.
- **EXE installer from a mandatory network share.** Replaced by the signed
  MSI, downloaded from `https://pkgs.netbird.io/windows/msi/x64` or
  pre-staged via `-MsiSource`.

Carried over in spirit: the hardened posture (blockInbound,
disableServerRoutes, disableAutoConnect, disableProfiles,
disableUpdateSettings) as `policy/profiles/hardened-workstation.reg`, the
verification checks, and the security notes in the README.

Not carried: `--block-lan-access` has no MDM policy key as of v0.75; the
migration doc documents keeping it as a CLI flag where required.

## From netbird-everyday-scripts

`Install-NetBird.ps1` was merged into `scripts/Deploy-NetBird.ps1`
unchanged in its core: file-only logging to
`%ProgramData%\NetBird\netbird-deploy.log`, idempotency via uninstall
registry keys, TLS 1.2 enforcement, Authenticode verification before
msiexec, silent `msiexec /qn /norestart /l*v`, meaningful exit codes.

Added on top: optional policy write before install (`-PolicyFile` .reg
import, or `-ManagementURL` plus lockdown switches) and `-MsiSource`
supporting a UNC/local path as an alternative to the download URL.
