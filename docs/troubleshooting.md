# Troubleshooting

## The app won't start

**Nothing happens when I double-click the exe.**
Approve the UAC prompt. If it was dismissed, the app exits silently. Also check that your
antivirus did not quarantine it — unsigned binaries are sometimes blocked.

**"Windows protected your PC" (SmartScreen).**
Click **More info → Run anyway**, or build it yourself (`.\src\Build-Exe.ps1`).

**"This app can't run on your PC."**
The release build is x64. On 32-bit Windows, run the source instead:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\WindowsUpdateManager.ps1
```

**Script mode: "running scripts is disabled on this system".**
Use the provided launcher or bypass the policy for that one process:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -STA -File .\src\WindowsUpdateManager.ps1
```

## The Settings page is still there after Disable

The `SettingsPageVisibility` policy is read by the Settings app when it starts. If Settings was
already open, close it completely (or sign out and back in). If it still appears, verify the value:

```powershell
Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name SettingsPageVisibility
```

Expected while disabled: `hide:<something>;windowsupdate`.

To force a refresh without rebooting:

```powershell
Get-Process SystemSettings -ErrorAction SilentlyContinue | Stop-Process -Force
```

## Windows Update came back on its own

Something re-applied policy. Check these in order:

1. **Is the pause still set?**

   ```powershell
   (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings').PauseUpdatesExpiryTime
   ```

   Should be `2099-12-31T23:59:59Z`.

2. **Are the policy keys present?**

   ```powershell
   Test-Path 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
   ```

3. **Did `Registry.pol` lose the entries?**

   ```powershell
   Get-ItemProperty 'HKLM:\SOFTWARE\WindowsUpdateManager'   # marker should show MenuHidden = 1
   ```

4. **Is a domain / MDM policy in charge?** On a work or school machine, `gpupdate` can overwrite
   local settings. Run `gpresult /h %TEMP%\gp.html` and look for Windows Update policies coming from
   the organization. Local policy cannot override those.

5. **Windows Update Medic Service** (`WaaSMedicSvc`) can repair update components on some builds.
   If updates keep coming back, re-run Disable; the pause is the strongest lever.

## The Microsoft Store stopped working

It shouldn't — this tool never touches services. Check them:

```powershell
Get-Service wuauserv, UsoSvc, DoSvc, bits, cryptsvc, InstallService | Select-Object Name, Status, StartType
```

All should be `Running`. If any is stopped:

```powershell
Start-Service wuauserv, UsoSvc, DoSvc, bits, cryptsvc
```

If the Store still fails, it is usually unrelated (store cache, sign-in). Try
`wsreset.exe`, then reboot.

## Enable didn't bring the page back

Enable restores the values recorded in `HKLM\SOFTWARE\WindowsUpdateManager`. If that key was
deleted manually, the originals are gone and the policy values are simply removed (which is
normally the desired end state anyway). To do it by hand:

```powershell
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' -Name SettingsPageVisibility -ErrorAction SilentlyContinue
Remove-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate' -Name DisableWindowsUpdateAccess -ErrorAction SilentlyContinue
Remove-Item 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' -Recurse -Force -ErrorAction SilentlyContinue
```

Then restart Settings.

## "Check for updates" fails after Enable

Give it a minute, then force a scan:

```powershell
Restart-Service wuauserv
Start-Process 'ms-settings:windowsupdate'
```

If it still fails, re-import the newest backup from
`%ProgramData%\WindowsUpdateManager\backup-*\` and reboot.

## Updates that were already downloaded installed anyway

Disable stops new update activity; it does not cancel an install that was already staged. Let it
finish (or reboot), then press Disable again — the pause is re-applied to the new state.

## I want to verify nothing sneaky is happening

- The app makes no network requests. Watch it with Resource Monitor or
  [TCPView](https://learn.microsoft.com/sysinternals/downloads/tcpview).
- Diff the registry before/after with the backups in `%ProgramData%\WindowsUpdateManager\`.
- Run `.\src\Test-WuManager.ps1` and read `%TEMP%\wu-manager-test.log`.
- Or just read [`src/WuCore.ps1`](../src/WuCore.ps1) — it is ~460 lines and commented.

## Still stuck?

Open an issue with:

- Windows edition, version and build (`winver`)
- What you pressed and what happened
- The output of the verification commands above
- `%TEMP%\wu-manager-test.log`, if you ran the harness
