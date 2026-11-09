# Contributing

Thanks for wanting to help. This is a small tool with a sharp edge — it edits `HKLM` and
`Registry.pol` on a live machine — so the bar for "tested" is a bit higher than usual.

## Before you start

- Read [docs/how-it-works.md](docs/how-it-works.md) so you know which registry keys are in play.
- **Test on a VM or a machine you can afford to reinstall.** Snapshot first.
- Open an issue before a large change, so we don't duplicate work.

## Ground rules

1. **Never disable or stop services.** The entire point of this project is that the Microsoft
   Store keeps working. A PR that touches service startup types in `Disable` will be rejected.
2. **Every change must be reversible.** `Enable` has to restore the machine to its pre-Disable
   state, including values that were absent before.
3. **Don't break other policy.** `SettingsPageVisibility` and `Registry.pol` may contain unrelated
   entries. Preserve them; only add/remove what belongs to Windows Update.
4. **No new runtime dependencies.** The shipped app must stay a single self-contained `.exe`.
5. **No network calls, telemetry, or background processes.**

## Development setup

```powershell
git clone https://github.com/Dragonbot-12012/windows-update-manager.git
cd windows-update-manager
Install-Module ps2exe -Scope CurrentUser -Force
```

Run the GUI from source:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\WindowsUpdateManager.ps1
```

Build the executable:

```powershell
.\src\Build-Exe.ps1
```

## Testing

Run the harness as administrator:

```powershell
.\src\Test-WuManager.ps1
```

It performs four full `Disable → Enable` cycles and checks:

- policy keys and values, both live and in `Registry.pol`
- the pause window and its expiry
- Settings page visibility before/after, and exact restoration afterwards
- service state (must stay running)

All checks must pass before a PR is merged. Include the final pass/fail count in your PR
description.

## Style

- PowerShell 5.1 compatible — no `??`, no `-Parallel`, no ternary operator.
- 4 spaces, no tabs.
- Keep functions in `WuCore.ps1` when both the GUI and the tests need them.
- Comment *why*, not *what*. Registry paths get a short note explaining what they control.
- Do not hard-code user paths. Use `$env:ProgramData`, `$env:TEMP`, `$PSScriptRoot`.

## Commit messages

Short imperative subject line, e.g.:

```
Add restore of legacy DisableWindowsUpdateAccess value
Fix pause expiry parsing on non-en-US locales
```

## Reporting bugs

Use the issue template and include:

- Windows edition, version and build (`winver`)
- Which button you pressed and what you expected
- The relevant registry state (`Get-ItemProperty` output)
- `%TEMP%\wu-manager-test.log` if you ran the harness

For security issues, follow [SECURITY.md](SECURITY.md) instead of opening a public issue.
