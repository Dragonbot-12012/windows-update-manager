# Changelog

All notable changes to this project are documented here.
This project follows [Semantic Versioning](https://semver.org/).

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

[1.0.0]: https://github.com/Dragonbot-12012/windows-update-manager/releases/tag/v1.0.0
