# How it works

This document explains exactly what the app writes, why each piece is there, and what happens on
Enable. Everything lives in [`src/WuCore.ps1`](../src/WuCore.ps1); the GUI is only a shell around
`Disable-WuFast` and `Enable-WuFast`.

## Design constraints

1. **Microsoft Store must keep working.** The Store's install/update pipeline shares services with
   Windows Update (`wuauserv`, `UsoSvc`, `DoSvc`). Therefore services are never stopped or disabled.
2. **No `gpedit.msc`.** Windows Home has no Group Policy Editor, so all policy is written directly
   to the registry (which is what `gpedit` does anyway).
3. **Must be fast.** Both actions complete in well under a second. No `gpupdate /force`, no
   `sfc`, no component reset.
4. **Must be reversible.** The first Disable records the original values; Enable restores them
   byte-for-byte.

## 32-bit and 64-bit builds

The release ships two executables built from the same source:

| File | PE machine | Runs on |
| --- | --- | --- |
| `Windows-Update-Manager-x64.exe` | `0x8664` (AMD64) | 64-bit Windows |
| `Windows-Update-Manager-x86.exe` | `0x014C` (i386) | 32-bit Windows |

Both are real single-file builds; neither is a wrapper around the other.

### Why the 32-bit build refuses to run on 64-bit Windows

Everything this tool writes lives in two places that WOW64 redirects:

- `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` — a 32-bit process writing to
  `HKLM\SOFTWARE` is silently redirected to `HKLM\SOFTWARE\WOW6432Node\...`.
- `%SystemRoot%\System32\GroupPolicy\Machine\Registry.pol` — a 32-bit process asking for
  `System32` is redirected to `%SystemRoot%\SysWOW64\...`.

Windows reads the Windows Update policies from the **64-bit** view and the **native** `System32`.
So a 32-bit process on 64-bit Windows would report success while changing keys that Windows never
looks at. That is worse than failing, so the app checks first:

```powershell
function Test-WuArchitectureSupported {
    return ((-not [Environment]::Is64BitOperatingSystem) -or [Environment]::Is64BitProcess)
}
```

- 64-bit Windows + 64-bit process → supported.
- 32-bit Windows (any process) → supported.
- 64-bit Windows + 32-bit process → **not** supported.

In the GUI, an unsupported combination looks for `Windows-Update-Manager-x64.exe` (or the old
`Windows Update Manager.exe`) in the same folder and launches it. If it is not there, the app shows
a warning and exits with code 1. The two console scripts perform the same check and refuse with a
message. No registry value or policy file is touched before the check runs.

The build itself is guarded too: `Build-Exe.ps1` reads the PE header of every output and throws if
the machine type does not match the requested architecture, so an x64 binary can never be published
under the x86 name.

## Disable — step by step

### 1. Pause updates

```
HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings
```

| Value | Set to |
| --- | --- |
| `PauseUpdatesStartTime` | now (UTC, ISO 8601) |
| `PauseFeatureUpdatesStartTime` | now |
| `PauseQualityUpdatesStartTime` | now |
| `PauseUpdatesExpiryTime` | `2099-12-31T23:59:59Z` |
| `PauseFeatureUpdatesEndTime` | `2099-12-31T23:59:59Z` |
| `PauseQualityUpdatesEndTime` | `2099-12-31T23:59:59Z` |

This is the same switch the **Pause updates** button in Settings uses. It stops scanning,
downloading and installing, and — importantly — it has **no effect on the Microsoft Store**.

### 2. Policy values

```
HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate
HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU
```

| Key | Value | Purpose |
| --- | --- | --- |
| `WindowsUpdate` | `SetDisableUXWUAccess = 1` | Removes the Windows Update UI surface |
| `WindowsUpdate` | `DoNotConnectToWindowsUpdateInternetLocations = 1` | Blocks WU internet endpoints |
| `WindowsUpdate` | `DeferQualityUpdates = 1` | Enables deferral |
| `WindowsUpdate` | `DeferQualityUpdatesPeriodInDays = 30` | Maximum deferral |
| `WindowsUpdate` | `DeferFeatureUpdates = 1` | Enables feature deferral |
| `WindowsUpdate` | `DeferFeatureUpdatesPeriodInDays = 30` | Maximum deferral |
| `AU` | `NoAutoUpdate = 1` | Disables automatic updates |
| `AU` | `AUOptions = 1` | "Never check for updates" |

### 3. Mirror into `Registry.pol`

```
%SystemRoot%\System32\GroupPolicy\Machine\Registry.pol
```

Local Group Policy is backed by this binary file. Writing only to `HKLM\SOFTWARE\Policies` works
until the Group Policy engine refreshes, at which point it can overwrite those values from
`Registry.pol`. To make the block stick across reboots and GP refreshes, the same eight values are
written into `Registry.pol` as well.

The app includes a small `PReg` parser/writer:

- `Get-PolEntries` reads the `[key;value;type;size;data]` records.
- `Remove-WuEntriesFromPol` removes **only** entries whose key starts with
  `Software\Policies\Microsoft\Windows\WindowsUpdate`, leaving every other policy untouched.
- `Add-WuEntriesToPol` appends the new records.

No `gpupdate` is run. The live registry values take effect immediately; `Registry.pol` just keeps
them from being reverted later.

### 4. Hide the Windows Update page in Settings

```
HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer
    SettingsPageVisibility = "hide:<existing tokens>;windowsupdate"

HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate
    DisableWindowsUpdateAccess = 1
```

`SettingsPageVisibility` takes a `hide:` or `show:` list. The app **appends** `windowsupdate` to
the existing list instead of replacing it, so other hidden pages stay hidden. If the existing value
is a `show:` list, `windowsupdate` is removed from it instead.

`DisableWindowsUpdateAccess` is the older (Windows 8/8.1/10) mechanism and is still honoured by
some builds.

### 5. Save the originals

```
HKLM\SOFTWARE\WindowsUpdateManager
    SavedSPV  = <original SettingsPageVisibility, or "__NONE__">
    SavedDWUA = <original DisableWindowsUpdateAccess, or "__NONE__">
    MenuHidden = 1
```

This marker key is what makes Enable exact. If the values did not exist before, `Enable` deletes
them again instead of writing a default.

### 6. Services — intentionally untouched

No `Stop-Service`, no `Set-Service`, no `sc config`. The services below are left exactly as they
are:

```
wuauserv  UsoSvc  DoSvc  InstallService  AppXSvc  bits  cryptsvc
```

## Enable — step by step

1. Delete `HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate` recursively.
2. Strip the Windows Update records out of `Registry.pol` (others preserved).
3. Delete the six pause values plus `TargetReleaseVersion` / `TargetReleaseVersionInfo`.
4. Restore `SettingsPageVisibility` and `DisableWindowsUpdateAccess` from the marker key, or delete
   them if they were absent originally, then clear the marker values.
5. Reset normal service start types:

   | Service | Startup type |
   | --- | --- |
   | `wuauserv` | Manual |
   | `UsoSvc` | Manual |
   | `DoSvc` | Manual |
   | `msiserver` | Manual |
   | `bits` | Automatic |
   | `cryptsvc` | Automatic |

6. Start `bits`, `cryptsvc`, `wuauserv`, `DoSvc`, `UsoSvc` if they are not running.

Windows will pick the changes up on its own schedule. You can force an immediate check from
Settings → Windows Update → **Check for updates**.

## Backups

Before either action, `Backup-WuState` exports the current state to:

```
%ProgramData%\WindowsUpdateManager\backup-yyyyMMdd-HHmmss-fff\
```

Contents (only files that exist at the time are written):

- `WindowsUpdate-policy.reg`
- `UX-Settings.reg`
- `Explorer-policy.reg`
- `Legacy-WindowsUpdate-policy.reg`
- `Manager-state.reg`
- `Registry.pol.bak`

Restore any of them with `reg import <file>` (or copy the `.pol` back) from an elevated prompt.

## Known limitations

- **Settings Home card.** The sidebar entry and the whole Windows Update page are hidden, and
  `ms-settings:windowsupdate` redirects to Home. However, the Settings **Home** page still renders a
  small "Windows Update — Last checked" card. It is a separate widget with no supported switch, and
  its link is dead. Removing it would require patching the Settings app, which this project does
  not do.
- **Already-staged updates.** Updates that were already downloaded and staged before you pressed
  Disable may still finish installing on the next reboot. Disable prevents *new* work, it does not
  cancel an in-flight install.
- **Windows Update Medic Service.** On some builds `WaaSMedicSvc` can re-apply update
  configuration. It is left alone on purpose; the pause + policy combination is enough in practice.
- **No signature.** The binary is unsigned, so SmartScreen may warn. Build from source if that
  matters to you.
