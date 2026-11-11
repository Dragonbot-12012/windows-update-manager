# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

## [1.0.2] — 2026-11-11

Correctness release: exact restore, read-back verification, and managed-device awareness.

### Added

- **Full original-state snapshot.** Before the first change, the app saves the complete Windows
  Update policy key tree (every value, including child keys), the pause/release values,
  the Windows Update `Registry.pol` entries, the Settings-page values and key-existence flags to
  `%ProgramData%\WindowsUpdateManager\original-state\state.json`, plus a human-readable
  `WindowsUpdate-policy.reg`. Enable restores this exactly and then deletes the snapshot.
- **Safe fallback.** If no snapshot exists (for example a machine disabled by an older version),
  Enable removes only the eight values and policy entries this tool owns and leaves pre-existing
  policy such as `TargetReleaseVersion` untouched.
- **Read-back verification.** After Disable and Enable the app re-reads the registry and
  `Registry.pol`, and warns with a dialog plus a `manager.log` entry if anything did not apply.
- **Managed-device detection.** `dsregcmd /status` (then a registry fallback) detects domain,
  Azure AD, Enterprise and MDM management; the Disable confirmation notes that organisation policy
  may override local settings. Built-in enrollment stubs are ignored.
- **Activity log.** `%ProgramData%\WindowsUpdateManager\manager.log`, rotated at 1 MB.
- **Single-instance mutex.** `Global\WindowsUpdateManager` prevents two copies from racing while
  editing `Registry.pol`.

### Fixed

- **Disable no longer destroys pre-existing policy values.** `New-Item -Force` on an existing
  registry key silently deletes every value in it. Disable now creates keys only when they are
  missing, so values like `TargetReleaseVersion` survive.
- **Snapshot restore now actually writes values.** The previous restore path used
  `RegistryKey.SetValue` on a key returned by `Get-Item`, which is read-only on some PowerShell
  builds and threw *"Cannot write to the registry key."* Restore now uses `New-ItemProperty`.
- **`REG_EXPAND_SZ` values are captured and compared raw**, so an exact restore does not bake in the
  current environment.

### Changed

- GUI footer, executable version and README badge are `v1.0.2`.
- Self-test grows from 111 to **143** checks, including a snapshot round-trip with seeded
  pre-existing policy and a snapshot-missing fallback case.

## [1.0.1] — 2026-11-10

32-bit support.

### Added

- **32-bit build:** `Windows-Update-Manager-x86.exe`, built from the same source as the x64 build.
  Each release now ships `Windows-Update-Manager-x64.exe` and `Windows-Update-Manager-x86.exe`,
  with explicit names so the wrong file is not downloaded by accident.
- `Build-Exe.ps1 -Architecture x64|x86|Both` (default `Both`). Every build is checked against its
  expected PE machine type (`0x8664` / `0x014C`) and fails if they do not match.
- Architecture guard (`Test-WuArchitectureSupported`): on 64-bit Windows the 32-bit build shows a
  clear warning and exits, because a 32-bit process is redirected to `WOW6432Node` / `SysWOW64`
  where Windows never reads these policies. If `Windows-Update-Manager-x64.exe` sits next to it,
  the 32-bit build launches that instead.
- The same guard in `Disable-WindowsUpdate.ps1` and `Enable-WindowsUpdate.ps1`.
- The version is now stamped into the executable at build time, and the footer reads it from that
  value instead of a hard-coded string.

### Changed

- Release assets now include both architectures and a single `SHA256SUMS.txt` covering both.
- GUI footer and the release version are `v1.0.1`.
- README download section is a per-architecture table.

## [1.0.0] — 2026-11-10

First public release.

### Added

- Single-file `Windows Update Manager.exe` (x64, admin manifest, no console window).
- Policy-only Disable: far-future pause + Windows Update policy keys + `Registry.pol` mirror.
- Hides the Windows Update page in Settings via `SettingsPageVisibility` and the legacy
  `DisableWindowsUpdateAccess` value, preserving any pre-existing tokens.
- Enable restores the exact original registry values recorded before the first change.
- Automatic timestamped backups (`reg export` + `Registry.pol` copy) in
  `%ProgramData%\WindowsUpdateManager\`.
- Windows 11 logo in the GUI, app name under it, `v1.0` footer.
- `Test-WuManager.ps1` self-test: four `Disable → Enable` cycles, 110 assertions.
- CI workflow that builds the executable and attaches it to tagged releases.

### Fixed

- The compiled executable no longer crashes at startup with
  `Cannot bind argument to parameter 'Path' because it is null`. A ps2exe build leaves
  `$PSScriptRoot` and the command path empty, so the path block now skips `Split-Path`
  in that case. Added a regression assertion to `Test-WuManager.ps1`.

### Notes

- Services are **never** stopped or disabled, so the Microsoft Store keeps working.
- Windows Update still appears as a "Last checked" card on the Settings **Home** page; the page
  itself and the sidebar entry are hidden.

[1.0.2]: https://github.com/Dragonbot-12012/windows-update-manager/releases/tag/v1.0.2
[1.0.1]: https://github.com/Dragonbot-12012/windows-update-manager/releases/tag/v1.0.1
[1.0.0]: https://github.com/Dragonbot-12012/windows-update-manager/releases/tag/v1.0.0
