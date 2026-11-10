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
