<#
.SYNOPSIS
    Self-test for WuCore.ps1: runs 4 full Disable -> Enable cycles and verifies
    every state change. Writes a log to %TEMP%\wu-manager-test.log.

.PARAMETER NoPause
    Do not wait for a key press at the end.
#>
param(
    [switch]$NoPause
)

$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"")
    if ($NoPause) { $argList += '-NoPause' }
    try { Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList -Wait } catch { }
    exit
}

$ErrorActionPreference = 'Continue'

$base = $PSScriptRoot
if (-not $base) { $base = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path $base 'WuCore.ps1')

$log = Join-Path $env:TEMP 'wu-manager-test.log'
if (Test-Path $log) { Remove-Item $log -Force }

function Log {
    param([string]$Message)
    $line = "[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss.fff'), $Message
    Add-Content -Path $log -Value $line
    Write-Host $line
}

$script:pass = 0
$script:fail = 0
function Check {
    param([string]$Name, [bool]$Ok, [string]$Detail = '')
    if ($Ok) {
        $script:pass++
        Log "  PASS  $Name $Detail"
    } else {
        $script:fail++
        Log "  FAIL  $Name $Detail"
    }
}

$testBase = Join-Path $env:TEMP 'wu-manager-test-backups'
New-Item -ItemType Directory -Path $testBase -Force | Out-Null

# Close any running GUI so it does not interfere.
Get-Process -Name powershell -ErrorAction SilentlyContinue |
    Where-Object { $_.MainWindowTitle -eq 'Windows Update Manager' } |
    Stop-Process -Force -ErrorAction SilentlyContinue

Log "=== WuCore self-test ==="
Log "Core: $base\WuCore.ps1"

$initial = Get-WuState
$originalSpv = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
# If the machine is already hidden by us, the "original" is what we saved before hiding.
$markerAtStart = Get-ItemProperty -Path $script:MarkerKey -ErrorAction SilentlyContinue
if ($markerAtStart -and $markerAtStart.MenuHidden -eq 1 -and $markerAtStart.SavedSPV) {
    if ($markerAtStart.SavedSPV -eq '__NONE__') { $originalSpv = $null } else { $originalSpv = $markerAtStart.SavedSPV }
}
Log "Initial: state=$($initial.State) policy=$($initial.PolicyKey) paused=$($initial.Paused) polWU=$($initial.PolWuEntries) menuHidden=$($initial.MenuHidden)"
Log "Original SettingsPageVisibility: '$originalSpv'"

for ($cycle = 1; $cycle -le 4; $cycle++) {
    Log ""
    Log "--- Cycle $cycle / 4 ---"

    # ----- DISABLE -----
    $sw = [Diagnostics.Stopwatch]::StartNew()
    $null = Disable-WuFast -BaseDir $testBase
    $sw.Stop()
    $dms = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)

    $st     = Get-WuState
    $reg    = Get-ItemProperty -Path $script:WuPolicyKey -ErrorAction SilentlyContinue
    $auReg  = Get-ItemProperty -Path $script:AuKey -ErrorAction SilentlyContinue
    $svc    = Get-Service wuauserv -ErrorAction SilentlyContinue
    $expiry = $null
    if (Test-Path $script:UxKey) {
        $expiry = (Get-ItemProperty -Path $script:UxKey -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
    }
    $far = $false
    if ($expiry) {
        try { $far = ([datetime]::Parse($expiry)).ToUniversalTime() -gt (Get-Date).AddYears(1).ToUniversalTime() } catch { }
    }

    Log "DISABLE took $dms ms"
    Check 'policy key created' ($null -ne $reg)
    Check 'SetDisableUXWUAccess=1' ($reg.SetDisableUXWUAccess -eq 1)
    Check 'DoNotConnectToWindowsUpdateInternetLocations=1' ($reg.DoNotConnectToWindowsUpdateInternetLocations -eq 1)
    Check 'NoAutoUpdate=1' ($auReg.NoAutoUpdate -eq 1)
    Check 'AUOptions=1' ($auReg.AUOptions -eq 1)
    Check 'pause expiry far future' $far "($expiry)"
    Check 'Registry.pol has 8 WU entries' ($st.PolWuEntries -eq 8) "(got $($st.PolWuEntries))"
    Check 'wuauserv start type not Disabled' ($svc.StartType -ne 'Disabled') "(got $($svc.StartType))"
    Check 'UsoSvc start type not Disabled' ((Get-Service UsoSvc -ErrorAction SilentlyContinue).StartType -ne 'Disabled')
    Check 'DoSvc start type not Disabled' ((Get-Service DoSvc -ErrorAction SilentlyContinue).StartType -ne 'Disabled')
    Check 'state reports Disabled' ($st.State -eq 'Disabled')
    Check 'disable under 5000 ms' ($dms -lt 5000) "($dms ms)"

    $spvNow = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
    $dwuaNow = (Get-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -ErrorAction SilentlyContinue).DisableWindowsUpdateAccess
    Check 'Settings page hidden' ($st.MenuHidden)
    Check 'SettingsPageVisibility includes windowsupdate' ($spvNow -match 'windowsupdate') "(got '$spvNow')"
    Check 'DisableWindowsUpdateAccess=1' ($dwuaNow -eq 1) "(got '$dwuaNow')"

    # Idempotency: a second Disable must not duplicate pol entries.
    $null = Disable-WuFast -BaseDir $testBase
    $st2 = Get-WuState
    Check 'second Disable keeps 8 entries' ($st2.PolWuEntries -eq 8) "(got $($st2.PolWuEntries))"

    # ----- ENABLE -----
    $sw.Restart()
    $null = Enable-WuFast -BaseDir $testBase
    $sw.Stop()
    $ems = [math]::Round($sw.Elapsed.TotalMilliseconds, 0)

    $st3       = Get-WuState
    $svcW      = Get-Service wuauserv -ErrorAction SilentlyContinue
    $svcB      = Get-Service bits -ErrorAction SilentlyContinue
    $svcC      = Get-Service cryptsvc -ErrorAction SilentlyContinue
    $pauseLeft = $null
    if (Test-Path $script:UxKey) {
        $pauseLeft = (Get-ItemProperty -Path $script:UxKey -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
    }

    Log "ENABLE took $ems ms"
    Check 'policy key removed' (-not (Test-Path "Registry::$script:WuPolicyReg"))
    Check 'Registry.pol WU entries = 0' ($st3.PolWuEntries -eq 0) "(got $($st3.PolWuEntries))"
    Check 'pause expiry cleared' ([string]::IsNullOrEmpty($pauseLeft)) "($pauseLeft)"
    Check 'wuauserv startup Manual' ($svcW.StartType -eq 'Manual') "(got $($svcW.StartType))"
    Check 'bits startup Automatic' ($svcB.StartType -eq 'Automatic') "(got $($svcB.StartType))"
    Check 'cryptsvc startup Automatic' ($svcC.StartType -eq 'Automatic') "(got $($svcC.StartType))"
    Check 'state reports Enabled' ($st3.State -eq 'Enabled')
    Check 'enable under 5000 ms' ($ems -lt 5000) "($ems ms)"

    $spvAfter = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
    $dwuaAfter = (Get-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -ErrorAction SilentlyContinue).DisableWindowsUpdateAccess
    Check 'Settings page shown again' (-not $st3.MenuHidden)
    Check 'SettingsPageVisibility restored' ($spvAfter -eq $originalSpv) "(got '$spvAfter', want '$originalSpv')"
    Check 'DisableWindowsUpdateAccess removed' ($null -eq $dwuaAfter) "(got '$dwuaAfter')"
}

# ---------------------------------------------------------------------------
# Snapshot / exact restore
# ---------------------------------------------------------------------------
Log ""
Log "== snapshot / exact restore =="

$snapBase = Join-Path $env:TEMP 'wu-manager-test-snapshot'
Remove-Item $snapBase -Recurse -Force -ErrorAction SilentlyContinue
New-Item -ItemType Directory -Path $snapBase -Force | Out-Null

function Restore-TestState {
    param(
        [object]$Policy,
        [object]$Ux,
        [bool]$UxExisted,
        [object]$Spv,
        [object]$Dwua,
        [bool]$ExplorerExisted,
        [bool]$LegacyExisted,
        [byte[]]$PolBytes
    )

    Set-WuRegistrySnapshot -Snapshot $Policy

    foreach ($n in @($script:PauseAllNames + $script:ReleasePinNames)) {
        if (Test-Path $script:UxKey) {
            Remove-ItemProperty -Path $script:UxKey -Name $n -Force -ErrorAction SilentlyContinue
        }
    }
    if ($UxExisted) {
        if (-not (Test-Path $script:UxKey)) { New-Item -Path $script:UxKey -Force | Out-Null }
        foreach ($p in $Ux.GetEnumerator()) {
            if ($null -ne $p.Value -and [string]$p.Value -ne '') {
                New-ItemProperty -Path $script:UxKey -Name $p.Key -Value ([string]$p.Value) -PropertyType String -Force | Out-Null
            }
        }
    } elseif (Test-Path $script:UxKey) {
        $item = Get-Item -Path $script:UxKey -ErrorAction SilentlyContinue
        if ($item -and $item.ValueCount -eq 0 -and @(Get-ChildItem -Path $script:UxKey -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $script:UxKey -Force -ErrorAction SilentlyContinue
        }
    }

    Set-WuPageVisibility -SettingsPageVisibility $Spv -DisableWindowsUpdateAccess $Dwua `
        -ExplorerKeyExisted $ExplorerExisted -LegacyKeyExisted $LegacyExisted

    if ($null -ne $PolBytes) {
        [IO.File]::WriteAllBytes($script:PolPath, $PolBytes)
    }
}

# Capture the clean state so the test can put it back exactly.
$prePolicy = Get-WuRegistrySnapshot -RootPath $script:WuPolicyKey
$preUxExisted = Test-Path $script:UxKey
$preUx = [ordered]@{}
foreach ($n in @($script:PauseAllNames + $script:ReleasePinNames)) {
    $v = $null
    if ($preUxExisted) { $v = (Get-ItemProperty -Path $script:UxKey -Name $n -ErrorAction SilentlyContinue).$n }
    $preUx[$n] = $(if ($null -eq $v) { $null } else { [string]$v })
}
$preSpv = $null
if (Test-Path $script:ExplorerPolicyKey) {
    $preSpv = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
}
$preDwua = $null
if (Test-Path $script:LegacyWuPolicyKey) {
    $preDwua = (Get-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -ErrorAction SilentlyContinue).DisableWindowsUpdateAccess
}
$preExplorerExisted = Test-Path $script:ExplorerPolicyKey
$preLegacyExisted = Test-Path $script:LegacyWuPolicyKey
$prePolBytes = $null
if (Test-Path $script:PolPath) { $prePolBytes = [IO.File]::ReadAllBytes($script:PolPath) }

# Seed values that a real machine might already have.
New-Item -Path $script:WuPolicyKey -Force | Out-Null
New-Item -Path $script:AuKey -Force | Out-Null
New-ItemProperty -Path $script:WuPolicyKey -Name 'TargetReleaseVersion' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $script:WuPolicyKey -Name 'TargetReleaseVersionInfo' -Value '22H2' -PropertyType String -Force | Out-Null
New-ItemProperty -Path $script:WuPolicyKey -Name 'SetDisableUXWUAccess' -Value 0 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $script:WuPolicyKey -Name 'DeferFeatureUpdates' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $script:WuPolicyKey -Name 'DeferFeatureUpdatesPeriodInDays' -Value 7 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $script:AuKey -Name 'NoAutoUpdate' -Value 0 -PropertyType DWord -Force | Out-Null

New-Item -Path $script:UxKey -Force | Out-Null
$seedPause = '2026-12-31T23:59:59Z'
New-ItemProperty -Path $script:UxKey -Name 'PauseUpdatesExpiryTime' -Value $seedPause -PropertyType String -Force | Out-Null

if (-not (Test-Path $script:ExplorerPolicyKey)) { New-Item -Path $script:ExplorerPolicyKey -Force | Out-Null }
$seedSpv = 'hide:privacy'
New-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -Value $seedSpv -PropertyType String -Force | Out-Null

if (-not (Test-Path $script:LegacyWuPolicyKey)) { New-Item -Path $script:LegacyWuPolicyKey -Force | Out-Null }
New-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -Value 0 -PropertyType DWord -Force | Out-Null

$polSeeded = $false
if (Test-Path $script:PolPath) {
    $seedEntries = @(
        [pscustomobject]@{ Key = 'Software\Policies\Microsoft\Windows\WindowsUpdate'; Value = 'TargetReleaseVersion'; Type = 4; Data = [BitConverter]::GetBytes([uint32]1) },
        [pscustomobject]@{ Key = 'Software\Policies\Microsoft\Windows\Personalization'; Value = 'NoLockScreen'; Type = 4; Data = [BitConverter]::GetBytes([uint32]1) }
    )
    Add-WuEntriesToPol -Path $script:PolPath -Entries $seedEntries
    $polSeeded = $true
}

# First Disable must snapshot the seeded state, not the disabled state.
$disA = Disable-WuFast -BaseDir $snapBase
$snapDir = Join-Path $snapBase 'original-state'
$snapFile = Join-Path $snapDir 'state.json'
Check 'snapshot created on first Disable' (Test-Path $snapFile)
Check 'snapshot exported policy .reg' (Test-Path (Join-Path $snapDir 'WindowsUpdate-policy.reg'))
$snapJson = Get-Content $snapFile -Raw | ConvertFrom-Json
Check 'snapshot recorded pre-existing TargetReleaseVersion' (@($snapJson.policy.Values | Where-Object { $_.Name -eq 'TargetReleaseVersion' }).Count -eq 1)
Check 'snapshot recorded pre-existing pause' ($snapJson.ux.PauseUpdatesExpiryTime -eq $seedPause) "(got '$($snapJson.ux.PauseUpdatesExpiryTime)')"
Check 'disable verification passed' ($disA.Verification.Ok) "($($disA.Verification.Summary))"

# A second Disable must not overwrite the original snapshot.
$disA2 = Disable-WuFast -BaseDir $snapBase
$snapJson2 = Get-Content $snapFile -Raw | ConvertFrom-Json
Check 'second Disable keeps the original snapshot' ($snapJson2.created -eq $snapJson.created)

# Enable must restore the snapshot exactly.
$enaA = Enable-WuFast -BaseDir $snapBase
Check 'enable used the snapshot' ($enaA.Mode -eq 'snapshot') "(got $($enaA.Mode))"
Check 'snapshot removed after restore' (-not (Test-Path $snapDir))
Check 'enable verification passed' ($enaA.Verification.Ok) "($($enaA.Verification.Summary))"

$trv  = Get-WuRegistryValue -Path $script:WuPolicyKey -Name 'TargetReleaseVersion'
$trvi = Get-WuRegistryValue -Path $script:WuPolicyKey -Name 'TargetReleaseVersionInfo'
$sd   = Get-WuRegistryValue -Path $script:WuPolicyKey -Name 'SetDisableUXWUAccess'
$df   = Get-WuRegistryValue -Path $script:WuPolicyKey -Name 'DeferFeatureUpdates'
$dfp  = Get-WuRegistryValue -Path $script:WuPolicyKey -Name 'DeferFeatureUpdatesPeriodInDays'
$nau  = Get-WuRegistryValue -Path $script:AuKey -Name 'NoAutoUpdate'
Check 'TargetReleaseVersion restored' ($trv -eq 1) "(got $trv)"
Check 'TargetReleaseVersionInfo restored' ($trvi -eq '22H2') "(got $trvi)"
Check 'pre-existing SetDisableUXWUAccess=0 restored (not deleted)' ($sd -eq 0) "(got $sd)"
Check 'pre-existing DeferFeatureUpdates restored' ($df -eq 1) "(got $df)"
Check 'pre-existing DeferFeatureUpdatesPeriodInDays=7 restored' ($dfp -eq 7) "(got $dfp)"
Check 'pre-existing NoAutoUpdate=0 restored' ($nau -eq 0) "(got $nau)"

$pauseRestored = $null
if (Test-Path $script:UxKey) {
    $pauseRestored = (Get-ItemProperty -Path $script:UxKey -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
}
Check 'pre-existing pause restored' ($pauseRestored -eq $seedPause) "(got $pauseRestored)"

$spvRestored = $null
if (Test-Path $script:ExplorerPolicyKey) {
    $spvRestored = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
}
Check 'pre-existing SettingsPageVisibility restored' ($spvRestored -eq $seedSpv) "(got '$spvRestored')"

$dwuaRestored = $null
if (Test-Path $script:LegacyWuPolicyKey) {
    $dwuaRestored = (Get-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -ErrorAction SilentlyContinue).DisableWindowsUpdateAccess
}
Check 'pre-existing DisableWindowsUpdateAccess=0 restored' ($dwuaRestored -eq 0) "(got $dwuaRestored)"

$polNow = @(Get-WuPolEntries)
Check 'pre-existing WU pol entry restored' (@($polNow | Where-Object { $_.Value -eq 'TargetReleaseVersion' }).Count -eq 1) "(got $($polNow.Count) WU entries)"
Check 'all 8 tool pol entries removed' (@($polNow | Where-Object { $script:WuSettingNames -contains $_.Value }).Count -eq 0)
if ($polSeeded) {
    $allPol = @(Get-PolEntries -Path $script:PolPath)
    Check 'non-WU pol entry preserved' (@($allPol | Where-Object { $_.Key -like '*Personalization*' -and $_.Value -eq 'NoLockScreen' }).Count -eq 1)
}

# Put the clean state back before the fallback test.
Restore-TestState -Policy $prePolicy -Ux $preUx -UxExisted $preUxExisted -Spv $preSpv -Dwua $preDwua `
    -ExplorerExisted $preExplorerExisted -LegacyExisted $preLegacyExisted -PolBytes $prePolBytes
Remove-Item $snapDir -Recurse -Force -ErrorAction SilentlyContinue

# ---------------------------------------------------------------------------
# Safe fallback when the snapshot is missing
# ---------------------------------------------------------------------------
Log ""
Log "== safe fallback (snapshot missing) =="

New-Item -Path $script:WuPolicyKey -Force | Out-Null
New-ItemProperty -Path $script:WuPolicyKey -Name 'TargetReleaseVersion' -Value 1 -PropertyType DWord -Force | Out-Null
New-ItemProperty -Path $script:WuPolicyKey -Name 'TargetReleaseVersionInfo' -Value '23H2' -PropertyType String -Force | Out-Null

$disB = Disable-WuFast -BaseDir $snapBase
Check 'fallback test created a snapshot' (Test-Path $snapFile)

# Simulate a machine disabled by an older version: the snapshot is gone.
Remove-Item $snapDir -Recurse -Force -ErrorAction SilentlyContinue
$saveWhileDisabled = Save-WuOriginalState -BaseDir $snapBase
Check 'Save-WuOriginalState refuses to snapshot a disabled machine' ($null -eq $saveWhileDisabled)
Check 'no snapshot was recreated while disabled' (-not (Test-Path $snapFile))

$enaB = Enable-WuFast -BaseDir $snapBase
Check 'enable used the fallback path' ($enaB.Mode -eq 'fallback') "(got $($enaB.Mode))"
Check 'fallback verification passed' ($enaB.Verification.Ok) "($($enaB.Verification.Summary))"

$trvB  = Get-WuRegistryValue -Path $script:WuPolicyKey -Name 'TargetReleaseVersion'
$trviB = Get-WuRegistryValue -Path $script:WuPolicyKey -Name 'TargetReleaseVersionInfo'
Check 'fallback left TargetReleaseVersion alone' ($trvB -eq 1) "(got $trvB)"
Check 'fallback left TargetReleaseVersionInfo alone' ($trviB -eq '23H2') "(got $trviB)"

$left = @()
foreach ($s in $script:WuSettings) {
    if ($null -ne (Get-WuRegistryValue -Path $s.Path -Name $s.Name)) { $left += $s.Name }
}
Check 'fallback removed all 8 tool values' ($left.Count -eq 0) "($($left -join ', '))"

$pauseB = $null
if (Test-Path $script:UxKey) {
    $pauseB = (Get-ItemProperty -Path $script:UxKey -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
}
Check 'fallback cleared the pause' ([string]::IsNullOrEmpty($pauseB)) "(got '$pauseB')"

$spvB = $null
if (Test-Path $script:ExplorerPolicyKey) {
    $spvB = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
}
Check 'fallback removed the windowsupdate token' (-not ($spvB -match 'windowsupdate')) "(got '$spvB')"

$dwuaB = $null
if (Test-Path $script:LegacyWuPolicyKey) {
    $dwuaB = (Get-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -ErrorAction SilentlyContinue).DisableWindowsUpdateAccess
}
Check 'fallback removed DisableWindowsUpdateAccess' ($null -eq $dwuaB) "(got '$dwuaB')"

# Put the clean state back again.
Restore-TestState -Policy $prePolicy -Ux $preUx -UxExisted $preUxExisted -Spv $preSpv -Dwua $preDwua `
    -ExplorerExisted $preExplorerExisted -LegacyExisted $preLegacyExisted -PolBytes $prePolBytes
Remove-Item $snapBase -Recurse -Force -ErrorAction SilentlyContinue

Log ""

# Leave the machine in whatever state it was in before the test.
if ($initial.State -eq 'Disabled') {
    $null = Disable-WuFast -BaseDir $testBase
    Start-WuServices
    $restored = Get-WuState
    Check 'restored initial Disabled state' ($restored.State -eq 'Disabled') "($($restored.State))"
    Check 'Store services left usable' (
        (Get-Service wuauserv -ErrorAction SilentlyContinue).StartType -ne 'Disabled' -and
        (Get-Service UsoSvc   -ErrorAction SilentlyContinue).StartType -ne 'Disabled' -and
        (Get-Service DoSvc    -ErrorAction SilentlyContinue).StartType -ne 'Disabled'
    )
}

$final = Get-WuState
Log "Final: state=$($final.State) policy=$($final.PolicyKey) paused=$($final.Paused) polWU=$($final.PolWuEntries)"

# ---------------------------------------------------------------------------
# Startup regression: a ps2exe build leaves $PSScriptRoot and the command path
# empty, so the path block must not call Split-Path with a null path.
# ---------------------------------------------------------------------------
Log ""
Log "== startup path resolution (ps2exe conditions) =="
$guiText = Get-Content (Join-Path $base 'WindowsUpdateManager.ps1') -Raw
$startMarker = '# Paths + shared core'
$endMarker   = '# Backups always go to ProgramData'
$si = $guiText.IndexOf($startMarker)
$ei = $guiText.IndexOf($endMarker)
if ($si -ge 0 -and $ei -gt $si) {
    $block = $guiText.Substring($si, $ei - $si)
    $threw = $null
    try {
        # A string scriptblock has no $PSScriptRoot and no command path, which
        # is exactly what the compiled executable sees at startup.
        $probe = "`$ErrorActionPreference = 'Stop'`n`$PSScriptRoot = `$null`n" + $block
        $null = & ([scriptblock]::Create($probe))
    } catch {
        $threw = $_.Exception.Message
    }
    Check 'path block survives empty $PSScriptRoot' ($null -eq $threw) "($threw)"
} else {
    Check 'path block found in GUI script' $false '(markers not found)'
}

Log "RESULT: $script:pass passed, $script:fail failed"
Log "Log: $log"

if (-not $NoPause) {
    Write-Host "`nPress Enter to close..."
    [void][Console]::ReadLine()
}
