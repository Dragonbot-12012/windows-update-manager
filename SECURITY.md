# Security Policy

## Supported versions

| Version | Supported |
| --- | --- |
| 1.0.x | ✅ |
| < 1.0 | ❌ |

## Reporting a vulnerability

Please **do not open a public issue** for security problems.

Use GitHub's private reporting flow: go to the **Security** tab → **Report a vulnerability**.
If that is unavailable, open a minimal public issue asking for a private contact channel, without
details.

Please include:

- Windows version and build
- Steps to reproduce
- What an attacker could achieve (e.g. privilege escalation, arbitrary registry write, code
  execution)
- Any proof-of-concept output

You can expect an initial reply within a few days. There is no bug bounty.

## Threat model — read this before running a build

This is an **administrator tool**. It runs elevated, writes to `HKLM`, and rewrites
`%SystemRoot%\System32\GroupPolicy\Machine\Registry.pol`. Treat it with the same caution as any
`.exe` that asks for UAC.

**The official binary is not code-signed.** That means:

- SmartScreen and some antivirus engines may flag or block it.
- You cannot verify its publisher from the signature.

Because of that, the recommended path is to **build it yourself** from source:

```powershell
.\src\Build-Exe.ps1
```

If you download a binary, verify its SHA-256 against the `SHA256SUMS.txt` published with the
release. The file lists both architectures, so check the one you downloaded:

```powershell
Get-FileHash '.\Windows-Update-Manager-x64.exe' -Algorithm SHA256   # 64-bit Windows
Get-FileHash '.\Windows-Update-Manager-x86.exe' -Algorithm SHA256   # 32-bit Windows
```

Compare the result with the matching line in `SHA256SUMS.txt`. A mismatch means the file is not the
one that was built and published — do not run it.

### What this software never does

- No network connections of any kind
- No telemetry, analytics, or crash reporting
- No auto-update mechanism
- No background service, driver, or scheduled task
- No writes outside `HKLM\SOFTWARE\...` policy keys, `%ProgramData%\WindowsUpdateManager\`, and
  `Registry.pol`

### What it writes on disk

- `%ProgramData%\WindowsUpdateManager\original-state\` — the exact pre-change snapshot
  (`state.json` + `WindowsUpdate-policy.reg`), deleted after a successful Enable.
- `%ProgramData%\WindowsUpdateManager\backup-<timestamp>\` — timestamped registry exports and a
  `Registry.pol` copy, written before every action.
- `%ProgramData%\WindowsUpdateManager\manager.log` — plain-text activity and verification log,
  rotated at 1 MB. It contains only Windows Update policy paths and values, never user data.

### Inherent risks

Disabling Windows Update means **no security patches** until you re-enable it. That is the intended
function of the tool, not a vulnerability. Do not report it as one.

## Scope

In scope:

- Privilege escalation or code execution via crafted input
- Writes to unintended registry locations or files
- Corruption of `Registry.pol` entries belonging to other policies
- Data loss in the backup/restore path

Out of scope:

- "It disables security updates" (that is the feature)
- SmartScreen/AV warnings caused by the missing code signature
- Issues that require an already-compromised machine
