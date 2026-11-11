# Troubleshooting

## The app won't start

**Nothing happens when I double-click the exe.**
Approve the UAC prompt. If it was dismissed, the app exits silently. Also check that your
antivirus did not quarantine it — unsigned binaries are sometimes blocked.

**"Windows protected your PC" (SmartScreen).**
Click **More info → Run anyway**, or build it yourself (`.\src\Build-Exe.ps1`).

**"This app can't run on your PC."**
You downloaded the wrong architecture. Use `Windows-Update-Manager-x64.exe` on 64-bit Windows and
`Windows-Update-Manager-x86.exe` on 32-bit Windows. Check **Settings → System → About → System type**
if you are unsure.

**The 32-bit exe says "This is the 32-bit build, but Windows is 64-bit."**
That is intentional. A 32-bit process on 64-bit Windows is redirected to `WOW6432Node` and
`SysWOW64`, where Windows does not read these policies, so the 32-bit build refuses to run instead
of pretending to work. Use `Windows-Update-Manager-x64.exe`. If both files are in the same folder,
the 32-bit build starts the x64 one for you.

**Script mode: "This is a 32-bit PowerShell session on 64-bit Windows."**
Run the script from 64-bit PowerShell (`%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe`),
not the SysWOW64 one.

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
   local settings. The app detects this and warns before Disable, but you can check yourself:

   ```powershell
   dsregcmd /status   # look at DomainJoined / AzureAdJoined / EnterpriseJoined / MdmUrl
   gpresult /h %TEMP%\gp.html
   ```

   Local policy cannot override organisation policy.

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

## The app says "verification failed" after Disable or Enable

The action was attempted, but the read-back check found a mismatch. Open
`%ProgramData%\WindowsUpdateManager\manager.log` — the failing checks are listed by name, for
example:

```
Verification (Disabled): 1 of 12 checks failed: Registry.pol mirrors the 8 tool values
```

Common causes:

- **A managed device re-applied its own policy** between the write and the read. See the
  domain/MDM check above.
- **`Registry.pol` is locked** by a Group Policy refresh. Close `gpedit.msc` / wait for the refresh,
  then run the action again.
- **Antivirus blocked a registry write.** Check its protection log.
- **A 32-bit process wrote to `WOW6432Node`.** Use the x64 build on 64-bit Windows.

The app does not silently retry; running the same action again is safe and idempotent.

## Enable didn't bring the page back

Enable restores `%ProgramData%\WindowsUpdateManager\original-state\` when it exists. If the snapshot
and the marker key were deleted manually, the originals are gone and the policy values are simply
removed (which is normally the desired end state anyway). To do it by hand:

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
- Read the plain-text activity log at `%ProgramData%\WindowsUpdateManager\manager.log`.
- Inspect the exact pre-change snapshot in `%ProgramData%\WindowsUpdateManager\original-state\`
  (it is deleted after a successful Enable).
- Run `.\src\Test-WuManager.ps1` and read `%TEMP%\wu-manager-test.log`.
- Or just read [`src/WuCore.ps1`](../src/WuCore.ps1) — it is commented and split into small functions.

## Still stuck?

Open an issue with:

- Windows edition, version and build (`winver`)
- What you pressed and what happened
- The output of the verification commands above
- `%TEMP%\wu-manager-test.log`, if you ran the harness
