# GPO setup walkthrough

Rolling NetBird out to a fleet of domain Windows clients by hand means two
problems: getting the client installed without touching each machine, and
making sure users cannot point it at the wrong server or loosen its security
settings. Group Policy solves both in one pass: managed policy values in
`HKLM\Software\Policies\NetBird` enforce configuration (the daemon reads
them as the highest-priority override), and a computer-startup script
performs the silent MSI install. Writing the policy values triggers no
connection; users authenticate via SSO on first login.

Running example throughout: a self-hosted management server at
`https://api.example.com:443` (explicit port included) and an Active
Directory domain `domain.example.com`. Using NetBird Cloud instead? Skip
the ManagementURL policy and keep everything else.

Requires NetBird client v0.73.0 or later (first release with MDM policy
support).

## a. Import the ADMX templates to the Central Store

Follow [admx/README.md](../admx/README.md). Short version: fetch
`netbird.admx` and `netbird.adml` from the upstream repo and copy them to
`\\domain.example.com\SYSVOL\domain.example.com\Policies\PolicyDefinitions\`
(ADML into `en-US\`).

ADMX not an option (no Central Store write access, or you need the
registry-only `LazyConnection` key)? The .reg profiles in
[policy/profiles/](../policy/profiles/) and Group Policy Preferences
Registry items write the identical values; everything below still applies.

## b. Create the policy GPO

1. In the Group Policy Management Console, create a GPO named
   `NetBird Policy` and link it to the OU containing the target computers.
2. Edit it: **Computer Configuration > Policies > Administrative
   Templates > NetBird**.
3. Enable **Management URL** and set it to `https://api.example.com:443`.
   Always include the explicit port. (Older clients had a UI false-conflict
   bug with default-port URLs, fixed in netbird PR #6672; the explicit form
   is safe on all versions.)
4. Enable the lockdown policies your posture requires. For a hardened
   workstation: **Block Inbound**, **Disable Server Routes**, **Disable
   Auto Connect**, **Disable Profiles**, **Disable Update Settings**. That
   set matches [policy/profiles/hardened-workstation.reg](../policy/profiles/hardened-workstation.reg).

Enforce only what you need: any value you leave "Not Configured" stays
under user/CLI control, and a value set to Disabled writes an explicit 0,
which is enforcement too (the GUI shows the setting as managed).

## c. Create the startup-script GPO

The only job policy cannot do is install the software. That is the startup
script's single task (it can also refresh policy, useful for non-ADMX
shops).

1. Copy `scripts/Deploy-NetBird.ps1` to a share readable by domain
   computers, e.g.
   `\\domain.example.com\SYSVOL\domain.example.com\scripts\`.
2. In the same GPO (or a second one named `NetBird Install`), go to
   **Computer Configuration > Policies > Windows Settings > Scripts
   (Startup/Shutdown) > Startup**, tab **PowerShell Scripts**, and add
   `Deploy-NetBird.ps1`.
3. Parameters: none needed when the policy GPO from step b handles
   configuration; the script then only installs. Without ADMX, pass a
   profile instead:

   ```
   -PolicyFile \\domain.example.com\SYSVOL\domain.example.com\scripts\hardened-workstation.reg
   ```

4. Machines without direct internet access: pre-stage the MSI on a share
   and add
   `-MsiSource \\fileserver.domain.example.com\software\netbird.msi`.
   The script verifies the Authenticode signature either way before
   executing the MSI.

If PowerShell execution policy is restricted in your environment, set
**Computer Configuration > Policies > Administrative Templates > Windows
Components > Windows PowerShell > Turn on Script Execution** to
`Allow local scripts and remote signed scripts` and sign the script, or
`Allow all scripts` where acceptable.

## d. Scoping

- Link the GPOs to the OU holding the workstation computer objects, not
  the domain root.
- Different postures for different hardware classes? Use one policy GPO
  per posture (hardened vs standard) linked to separate OUs, or a WMI
  filter, e.g. laptops only:

  ```
  SELECT * FROM Win32_SystemEnclosure WHERE ChassisTypes = 9 OR ChassisTypes = 10 OR ChassisTypes = 14
  ```

- Servers registered with setup keys get the minimal
  [server-peer.reg](../policy/profiles/server-peer.reg) posture: pin the
  URL, keep routing capabilities.

## e. What happens on first user login

After the next reboot (policy plus startup script applied), the machine
has NetBird installed and every managed value enforced, but no tunnel yet:

1. The NetBird UI starts from the MSI's autostart entry and the daemon is
   running, disconnected. Writing policy never initiates a connection.
2. The user clicks **Connect** in the tray UI. The daemon loads its
   config, overlays the managed policy (the client log shows one
   `MDM override <key> = <value>` line per enforced key), and connects to
   `https://api.example.com:443`.
3. The browser opens for SSO; the user signs in with their IdP account.
4. Managed settings are read-only in the GUI from the first start. With
   `DisableAutoConnect` enforced, the user connects manually each session;
   without it, subsequent boots connect automatically.

Later policy changes propagate without a reboot or service restart: the
daemon re-reads the policy key every minute (`client/mdm/ticker.go`), so
a GPO refresh followed by the next ticker interval is enough. Note that
`DisableUpdateSettings` locks the CLI as well as the GUI; once it is
enforced, configuration changes only flow through this policy channel.

Verify the result with [verification.md](verification.md).

## Recap

For `domain.example.com` pointing at `https://api.example.com:443`: ADMX
pair in the Central Store, one GPO enforcing ManagementURL plus the
hardened-workstation lockdown set, one startup script installing the
signed MSI, both linked to the workstation OU. Policy is pure GPO state,
install is one script, and the user's only job is SSO at first connect.
