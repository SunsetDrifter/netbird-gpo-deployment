# NetBird ADMX templates

The admin templates are not vendored here on purpose. They version with the
NetBird client, so always fetch the pair that matches the client version you
deploy from the upstream repo:

- `netbird.admx`: https://github.com/netbirdio/netbird/blob/main/docs/netbird.admx
- `netbird.adml`: https://github.com/netbirdio/netbird/blob/main/docs/netbird.adml

## Import to the Central Store

1. Download both files (raw):

   ```powershell
   Invoke-WebRequest 'https://raw.githubusercontent.com/netbirdio/netbird/main/docs/netbird.admx' -OutFile netbird.admx
   Invoke-WebRequest 'https://raw.githubusercontent.com/netbirdio/netbird/main/docs/netbird.adml' -OutFile netbird.adml
   ```

2. Copy them into the domain Central Store (on a domain controller, or any
   box with write access to SYSVOL). Using the running example domain
   `domain.example.com`:

   ```powershell
   Copy-Item netbird.admx '\\domain.example.com\SYSVOL\domain.example.com\Policies\PolicyDefinitions\'
   Copy-Item netbird.adml '\\domain.example.com\SYSVOL\domain.example.com\Policies\PolicyDefinitions\en-US\'
   ```

   No Central Store? Copy to `C:\Windows\PolicyDefinitions\` (and
   `en-US\`) on the machine where you run GPMC instead.

3. Reopen the Group Policy Management Editor. The policies appear under
   **Computer Configuration > Policies > Administrative Templates > NetBird**.

## What the ADMX covers

The ADMX defines all managed policy keys except `LazyConnection`, which is
registry-only (set it via `Set-NetBirdPolicy.ps1`, a .reg profile, or GPP
Registry). All values land in `HKLM\Software\Policies\NetBird`, the same
key the .reg profiles in `../policy/` write, so pick one mechanism per
setting and do not mix them for the same value name.
