# netbird-gpo-deployment

Deploy [NetBird](https://netbird.io) to Windows domain clients via Group
Policy: managed policy (ADMX/registry) plus silent MSI install.

Enforcing NetBird settings on domain Windows fleets used to require CLI
flags applied across multiple boot/login cycles. Since client **v0.73.0**,
the Windows daemon reads managed policy from
`HKLM\Software\Policies\NetBird` and overlays it on the client config as
the highest-priority layer (above CLI flags, env vars, and on-disk
config). Deployment collapses to two GPO artifacts: a policy GPO that
enforces settings, and a computer-startup script whose only irreducible
job is the silent MSI install.

This is a community, SE-maintained reference. The authoritative sources
are the official docs:
[MDM integration](https://docs.netbird.io/client/mdm-integration),
[Windows install](https://docs.netbird.io/get-started/install/windows),
and the
[Intune guide](https://docs.netbird.io/client/mdm-integration#intune) for
non-GPO MDMs.

## Minimum client version

**v0.73.0** (CONFIRMED): MDM configuration profile support landed in
netbirdio/netbird commit `2bcea9d` (PR #6374) and first shipped in the
v0.73.0 release. Earlier clients ignore the policy key entirely.

## Layout

| Path | What it is |
|---|---|
| `scripts/Deploy-NetBird.ps1` | GPO computer-startup script: policy write (optional) + signed silent MSI install |
| `scripts/Set-NetBirdPolicy.ps1` | Standalone parameterized policy writer, `-WhatIf` support, no install |
| `policy/netbird-policy.sample.reg` | Annotated sample of every supported key |
| `policy/profiles/*.reg` | Ready-made postures: hardened workstation, standard workstation, server peer |
| `admx/README.md` | Fetching upstream `netbird.admx`/`.adml` and importing to the Central Store |
| `docs/gpo-setup.md` | GPMC walkthrough: ADMX import, policy GPO, startup script, scoping, first login |
| `docs/verification.md` | Registry, `netbird status -d`, log, and behavior checks |
| `docs/migration-from-lockdown-mode.md` | Coming from the old flag-based two-boot approach |

Policy and install are split on purpose: policy is pure GPO state (no
script needed for URL or lockdown), so Intune or any other MDM shop can
take `policy/` alone and ignore the script.

## Quick start (single test machine)

Elevated PowerShell:

```powershell
# 1. Write a hardened policy posture (edit the URL first; omit for NetBird Cloud)
reg import policy\profiles\hardened-workstation.reg

# 2. Install silently (downloads, verifies signature, logs to %ProgramData%\NetBird)
powershell -NoProfile -ExecutionPolicy Bypass -File scripts\Deploy-NetBird.ps1

# 3. Verify
reg query HKLM\Software\Policies\NetBird
```

## Fleet deployment (GPO)

1. **ADMX**: fetch `netbird.admx`/`.adml` from upstream and copy to the
   Central Store ([admx/README.md](admx/README.md)).
2. **Policy GPO**: Computer Configuration > Policies > Administrative
   Templates > NetBird. Set Management URL with its explicit port
   (`https://api.example.com:443`; skip for NetBird Cloud) and the
   lockdown policies you want. Get the URL right before enabling
   Disable Update Settings; after that, policy is the only channel that
   can change it.
3. **Install GPO**: add `scripts/Deploy-NetBird.ps1` from SYSVOL as a
   computer startup script. No parameters needed; pass
   `-MsiSource \\fileserver\software\netbird.msi` for clients without
   internet access.
4. **Scope**: link both GPOs to the workstation OU.
5. **Done**: machines install on next boot; users click Connect and sign
   in via SSO on first login. Policy edits reach running clients within
   about a minute (the daemon re-reads the key every 60 s). Verify with
   [docs/verification.md](docs/verification.md).

Full walkthrough with scoping and first-login details:
[docs/gpo-setup.md](docs/gpo-setup.md).

## Security notes

- **No inbound firewall ports on peers.** With NetBird Cloud, all peer
  connections use outbound NAT traversal; nothing here requires opening
  inbound ports on clients. Self-hosted: the management server is the only
  inbound exposure.
- **HKLM policy beats CLI flags.** The policy key is writable only by
  administrators, and the daemon applies it above any locally set flag, so
  a standard user cannot loosen the posture that the old flag-based
  approach left changeable.
- **Secrets:** `PreSharedKey` is redacted in client logs and by
  `Set-NetBirdPolicy.ps1`, but any local admin can read the registry
  value. Treat it accordingly.
- **Installer integrity:** `Deploy-NetBird.ps1` enforces TLS 1.2 and
  verifies the MSI Authenticode signature before executing it, whether
  downloaded or pre-staged on a share.

## License

MIT, see [LICENSE](LICENSE).
