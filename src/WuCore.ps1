<#
.SYNOPSIS
    Shared Windows Update enable/disable core used by the GUI and the tests.

.DESCRIPTION
    Disable does four things that actually stop Windows Update:
      1. Pauses updates far in the future (the real switch Settings > Pause uses)
      2. Applies the local policy blocks + mirrors them into Registry.pol
      3. Hides the Windows Update page in Settings (restores it on Enable)
      4. Leaves all services running so Microsoft Store keeps working

    Before the first change it saves a snapshot of the exact original state in
    %ProgramData%\WindowsUpdateManager\original-state\. Enable restores that
    snapshot byte-for-byte instead of assuming "absent" was the original state.

    Enable also has a safe fallback for machines that were disabled before the
    snapshot existed: it removes only this tool's own values and leaves any
    pre-existing policy (for example TargetReleaseVersion) alone.

    No gpupdate is run, so both operations stay fast. The live values take
    effect immediately and Registry.pol keeps them after a reboot / GP refresh.
#>

$script:WuPolicyReg = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:WuPolicyKey = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$script:AuKey       = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate\AU'
$script:PolPath     = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Registry.pol'
$script:UxKey       = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'

# Where the "hide the Windows Update page" policies live.
$script:ExplorerPolicyKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer'
$script:LegacyWuPolicyKey  = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate'
# Our own bookkeeping so Enable can restore exactly what was there before.
$script:MarkerKey          = 'HKLM:\SOFTWARE\WindowsUpdateManager'
$script:SettingsPageId     = 'windowsupdate'

$script:PauseStartNames = @(
    'PauseUpdatesStartTime',
    'PauseFeatureUpdatesStartTime',
    'PauseQualityUpdatesStartTime'
)
$script:PauseEndNames = @(
    'PauseUpdatesExpiryTime',
    'PauseFeatureUpdatesEndTime',
    'PauseQualityUpdatesEndTime'
)
$script:PauseAllNames = @($script:PauseStartNames + $script:PauseEndNames)
$script:ReleasePinNames = @('TargetReleaseVersion', 'TargetReleaseVersionInfo')

# The eight values this tool owns. Kept in one place so Disable, the safe
# fallback in Enable, and the verification step cannot drift apart.
$script:WuSettings = @(
    @{ Path = $script:WuPolicyKey; Name = 'SetDisableUXWUAccess';                          Value = 1 },
    @{ Path = $script:WuPolicyKey; Name = 'DoNotConnectToWindowsUpdateInternetLocations'; Value = 1 },
    @{ Path = $script:WuPolicyKey; Name = 'DeferQualityUpdates';                          Value = 1 },
    @{ Path = $script:WuPolicyKey; Name = 'DeferQualityUpdatesPeriodInDays';              Value = 30 },
    @{ Path = $script:WuPolicyKey; Name = 'DeferFeatureUpdates';                          Value = 1 },
    @{ Path = $script:WuPolicyKey; Name = 'DeferFeatureUpdatesPeriodInDays';              Value = 30 },
    @{ Path = $script:AuKey;       Name = 'NoAutoUpdate';                                 Value = 1 },
    @{ Path = $script:AuKey;       Name = 'AUOptions';                                    Value = 1 }
)
$script:WuSettingNames = @($script:WuSettings | ForEach-Object { $_.Name })
$script:SnapshotDirName = 'original-state'

# ---------------------------------------------------------------------------
# Architecture
# ---------------------------------------------------------------------------
# Windows reads these policies from the 64-bit registry view and the native
# System32. A 32-bit process on 64-bit Windows is redirected to WOW6432Node and
# SysWOW64, where Windows never looks, so it must not run there.
function Test-WuArchitectureSupported {
    return ((-not [Environment]::Is64BitOperatingSystem) -or [Environment]::Is64BitProcess)
}

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
function Write-WuLog {
    param(
        [string]$Message,
        [ValidateSet('INFO', 'WARN', 'ERROR')][string]$Level = 'INFO',
        [string]$BaseDir
    )

    if (-not $BaseDir) { $BaseDir = Join-Path $env:ProgramData 'WindowsUpdateManager' }
    try {
        if (-not (Test-Path $BaseDir)) { New-Item -ItemType Directory -Path $BaseDir -Force | Out-Null }
        $logPath = Join-Path $BaseDir 'manager.log'
        if ((Test-Path $logPath) -and ((Get-Item $logPath).Length -gt 1MB)) {
            Move-Item -Path $logPath -Destination (Join-Path $BaseDir 'manager.log.1') -Force -ErrorAction SilentlyContinue
        }
        $line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message
        Add-Content -Path $logPath -Value $line -Encoding UTF8
    } catch {
        # Logging must never break the actual operation.
    }
}

# ---------------------------------------------------------------------------
# Registry.pol parser / writer
# ---------------------------------------------------------------------------
function Get-PolEntries {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return @() }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8) { return @() }

    $list = New-Object System.Collections.ArrayList
    $pos = 8

    while ($pos -lt $bytes.Length) {
        if ($bytes[$pos] -ne 0x5B) { $pos++; continue }

        $pos += 2

        $ks = $pos
        while ($pos + 1 -lt $bytes.Length -and -not ($bytes[$pos] -eq 0 -and $bytes[$pos + 1] -eq 0)) { $pos += 2 }
        $key = [Text.Encoding]::Unicode.GetString($bytes, $ks, $pos - $ks)
        $pos += 2
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        $vs = $pos
        while ($pos + 1 -lt $bytes.Length -and -not ($bytes[$pos] -eq 0 -and $bytes[$pos + 1] -eq 0)) { $pos += 2 }
        $val = [Text.Encoding]::Unicode.GetString($bytes, $vs, $pos - $vs)
        $pos += 2
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        $type = [BitConverter]::ToUInt32($bytes, $pos)
        $pos += 4
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        $size = [BitConverter]::ToUInt32($bytes, $pos)
        $pos += 4
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        $data = New-Object byte[] ([int]$size)
        [Array]::Copy($bytes, $pos, $data, 0, [int]$size)
        $pos += [int]$size
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x5D) { $pos += 2 } else { break }

        [void]$list.Add([pscustomobject]@{
            Key   = $key
            Value = $val
            Type  = $type
            Data  = $data
        })
    }

    return $list
}

function Get-WuPolEntries {
    return @(Get-PolEntries -Path $script:PolPath | Where-Object {
        $_.Key -like 'Software\Policies\Microsoft\Windows\WindowsUpdate*'
    })
}

function Remove-WuEntriesFromPol {
    param(
        [string]$Path,
        [string[]]$OnlyValues
    )

    if (-not (Test-Path $Path)) { return 0 }
    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8) { return 0 }

    $out = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt 8; $i++) { $out.Add($bytes[$i]) }

    $pos = 8
    $removed = 0

    while ($pos -lt $bytes.Length) {
        if ($bytes[$pos] -ne 0x5B) { $pos++; continue }

        $entryStart = $pos
        $pos += 2

        $ks = $pos
        while ($pos + 1 -lt $bytes.Length -and -not ($bytes[$pos] -eq 0 -and $bytes[$pos + 1] -eq 0)) { $pos += 2 }
        $key = [Text.Encoding]::Unicode.GetString($bytes, $ks, $pos - $ks)
        $pos += 2
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        $vs = $pos
        while ($pos + 1 -lt $bytes.Length -and -not ($bytes[$pos] -eq 0 -and $bytes[$pos + 1] -eq 0)) { $pos += 2 }
        $val = [Text.Encoding]::Unicode.GetString($bytes, $vs, $pos - $vs)
        $pos += 2
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        $pos += 4
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        $size = [BitConverter]::ToUInt32($bytes, $pos)
        $pos += 4
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        $pos += [int]$size
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x5D) { $pos += 2 } else { break }

        $entryEnd = $pos

        $isWu = $key -like 'Software\Policies\Microsoft\Windows\WindowsUpdate*'
        $matches = $isWu
        if ($matches -and $OnlyValues -and $OnlyValues.Count -gt 0) {
            $matches = ($OnlyValues -contains $val)
        }

        if ($matches) {
            $removed++
        } else {
            for ($j = $entryStart; $j -lt $entryEnd; $j++) { $out.Add($bytes[$j]) }
        }
    }

    [IO.File]::WriteAllBytes($Path, $out.ToArray())
    return $removed
}

function Add-WuEntriesToPol {
    param([string]$Path, [object[]]$Entries)

    $bytes = [IO.File]::ReadAllBytes($Path)
    $out = New-Object System.Collections.Generic.List[byte]

    if ($bytes.Length -ge 8) {
        for ($i = 0; $i -lt 8; $i++) { $out.Add($bytes[$i]) }
        for ($i = 8; $i -lt $bytes.Length; $i++) { $out.Add($bytes[$i]) }
    } else {
        $hdr = [Text.Encoding]::ASCII.GetBytes('PReg') + [BitConverter]::GetBytes([uint32]1)
        foreach ($b in $hdr) { $out.Add($b) }
    }

    foreach ($e in $Entries) {
        $out.Add(0x5B); $out.Add(0x00)
        foreach ($b in [Text.Encoding]::Unicode.GetBytes($e.Key)) { $out.Add($b) }
        $out.Add(0x00); $out.Add(0x00)
        $out.Add(0x3B); $out.Add(0x00)
        foreach ($b in [Text.Encoding]::Unicode.GetBytes($e.Value)) { $out.Add($b) }
        $out.Add(0x00); $out.Add(0x00)
        $out.Add(0x3B); $out.Add(0x00)
        foreach ($b in [BitConverter]::GetBytes([uint32]$e.Type)) { $out.Add($b) }
        $out.Add(0x3B); $out.Add(0x00)
        $data = [byte[]]$e.Data
        foreach ($b in [BitConverter]::GetBytes([uint32]$data.Length)) { $out.Add($b) }
        $out.Add(0x3B); $out.Add(0x00)
        foreach ($b in $data) { $out.Add($b) }
        $out.Add(0x5D); $out.Add(0x00)
    }

    [IO.File]::WriteAllBytes($Path, $out.ToArray())
}

# ---------------------------------------------------------------------------
# Hide / show the Windows Update page in Settings
# ---------------------------------------------------------------------------
function Test-WuMenuHidden {
    $spv = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
    $legacy = (Get-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -ErrorAction SilentlyContinue).DisableWindowsUpdateAccess

    $hiddenBySpv = $false
    if ($spv) {
        if ($spv -match '^\s*hide\s*:\s*(.*)$') {
            $hiddenBySpv = (@(($matches[1] -split ';') | ForEach-Object { $_.Trim().ToLower() }) -contains $script:SettingsPageId)
        } elseif ($spv -match '^\s*show\s*:\s*(.*)$') {
            # With a show-list, a page is hidden unless it is listed.
            $hiddenBySpv = -not (@(($matches[1] -split ';') | ForEach-Object { $_.Trim().ToLower() }) -contains $script:SettingsPageId)
        }
    }

    return ($hiddenBySpv -or ($legacy -eq 1))
}

function Hide-WuMenu {
    # Save the originals once, so Enable can put them back untouched.
    if (-not (Test-Path $script:MarkerKey)) { New-Item -Path $script:MarkerKey -Force | Out-Null }
    $marker = Get-ItemProperty -Path $script:MarkerKey -ErrorAction SilentlyContinue

    if (-not ($marker -and $marker.MenuHidden -eq 1)) {
        $spv = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
        $savedSpv = $(if ([string]::IsNullOrEmpty($spv)) { '__NONE__' } else { $spv })

        $dwua = (Get-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -ErrorAction SilentlyContinue).DisableWindowsUpdateAccess
        $savedDwua = $(if ($null -eq $dwua) { '__NONE__' } else { [string]$dwua })

        New-ItemProperty -Path $script:MarkerKey -Name 'SavedSPV'  -Value $savedSpv  -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $script:MarkerKey -Name 'SavedDWUA' -Value $savedDwua -PropertyType String -Force | Out-Null
        New-ItemProperty -Path $script:MarkerKey -Name 'MenuHidden' -Value 1 -PropertyType DWord -Force | Out-Null
    }

    # Append our page id to the existing hide-list (keep every other entry).
    if (-not (Test-Path $script:ExplorerPolicyKey)) { New-Item -Path $script:ExplorerPolicyKey -Force | Out-Null }
    $cur = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility

    if ([string]::IsNullOrWhiteSpace($cur)) {
        $new = "hide:$($script:SettingsPageId)"
    } elseif ($cur -match '^\s*hide\s*:\s*(.*)$') {
        $tokens = @(($matches[1] -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
        if (-not (@($tokens | ForEach-Object { $_.ToLower() }) -contains $script:SettingsPageId)) { $tokens += $script:SettingsPageId }
        $new = 'hide:' + ($tokens -join ';')
    } elseif ($cur -match '^\s*show\s*:\s*(.*)$') {
        $tokens = @(($matches[1] -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $_.ToLower() -ne $script:SettingsPageId })
        $new = 'show:' + ($tokens -join ';')
    } else {
        $new = "hide:$($script:SettingsPageId)"
    }

    New-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -Value $new -PropertyType String -Force | Out-Null

    # Older Windows (8/8.1/10) hide the Windows Update links through this one.
    if (-not (Test-Path $script:LegacyWuPolicyKey)) { New-Item -Path $script:LegacyWuPolicyKey -Force | Out-Null }
    New-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -Value 1 -PropertyType DWord -Force | Out-Null
}

function Show-WuMenu {
    $marker = Get-ItemProperty -Path $script:MarkerKey -ErrorAction SilentlyContinue
    if (-not ($marker -and $marker.MenuHidden -eq 1)) { return }

    $savedSpv = $marker.SavedSPV
    if ([string]::IsNullOrEmpty($savedSpv) -or $savedSpv -eq '__NONE__') {
        if (Test-Path $script:ExplorerPolicyKey) {
            Remove-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -Force -ErrorAction SilentlyContinue
        }
    } else {
        if (-not (Test-Path $script:ExplorerPolicyKey)) { New-Item -Path $script:ExplorerPolicyKey -Force | Out-Null }
        New-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -Value $savedSpv -PropertyType String -Force | Out-Null
    }

    $savedDwua = $marker.SavedDWUA
    if ([string]::IsNullOrEmpty($savedDwua) -or $savedDwua -eq '__NONE__') {
        if (Test-Path $script:LegacyWuPolicyKey) {
            Remove-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -Force -ErrorAction SilentlyContinue
        }
    } else {
        if (-not (Test-Path $script:LegacyWuPolicyKey)) { New-Item -Path $script:LegacyWuPolicyKey -Force | Out-Null }
        New-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -Value ([int]$savedDwua) -PropertyType DWord -Force | Out-Null
    }

    foreach ($n in @('SavedSPV', 'SavedDWUA', 'MenuHidden')) {
        Remove-ItemProperty -Path $script:MarkerKey -Name $n -Force -ErrorAction SilentlyContinue
    }
}

# Best-effort un-hide used only when no snapshot and no marker exist. It removes
# the "windowsupdate" token this tool adds and leaves every other token alone.
function Remove-WuPageHiding {
    $cur = $null
    if (Test-Path $script:ExplorerPolicyKey) {
        $cur = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
    }

    if (-not [string]::IsNullOrWhiteSpace($cur)) {
        if ($cur -match '^\s*hide\s*:\s*(.*)$') {
            $tokens = @(($matches[1] -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' -and $_.ToLower() -ne $script:SettingsPageId })
            if ($tokens.Count -eq 0) {
                Remove-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -Force -ErrorAction SilentlyContinue
            } else {
                New-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -Value ('hide:' + ($tokens -join ';')) -PropertyType String -Force | Out-Null
            }
        } elseif ($cur -match '^\s*show\s*:\s*(.*)$') {
            $tokens = @(($matches[1] -split ';') | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' })
            if (-not (@($tokens | ForEach-Object { $_.ToLower() }) -contains $script:SettingsPageId)) {
                $tokens += $script:SettingsPageId
                New-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -Value ('show:' + ($tokens -join ';')) -PropertyType String -Force | Out-Null
            }
        }
    }

    $dwua = $null
    if (Test-Path $script:LegacyWuPolicyKey) {
        $dwua = (Get-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -ErrorAction SilentlyContinue).DisableWindowsUpdateAccess
    }
    if ($dwua -eq 1) {
        Remove-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -Force -ErrorAction SilentlyContinue
    }
}

function Set-WuPageVisibility {
    param(
        [object]$SettingsPageVisibility,
        [object]$DisableWindowsUpdateAccess,
        [bool]$ExplorerKeyExisted,
        [bool]$LegacyKeyExisted
    )

    if ($null -eq $SettingsPageVisibility -or [string]::IsNullOrEmpty([string]$SettingsPageVisibility)) {
        if (Test-Path $script:ExplorerPolicyKey) {
            Remove-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -Force -ErrorAction SilentlyContinue
        }
    } else {
        if (-not (Test-Path $script:ExplorerPolicyKey)) { New-Item -Path $script:ExplorerPolicyKey -Force | Out-Null }
        New-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -Value ([string]$SettingsPageVisibility) -PropertyType String -Force | Out-Null
    }

    if ($null -eq $DisableWindowsUpdateAccess -or [string]::IsNullOrEmpty([string]$DisableWindowsUpdateAccess)) {
        if (Test-Path $script:LegacyWuPolicyKey) {
            Remove-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -Force -ErrorAction SilentlyContinue
        }
    } else {
        if (-not (Test-Path $script:LegacyWuPolicyKey)) { New-Item -Path $script:LegacyWuPolicyKey -Force | Out-Null }
        New-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -Value ([int]$DisableWindowsUpdateAccess) -PropertyType DWord -Force | Out-Null
    }

    if (-not $ExplorerKeyExisted -and (Test-Path $script:ExplorerPolicyKey)) {
        $item = Get-Item -Path $script:ExplorerPolicyKey -ErrorAction SilentlyContinue
        if ($item -and $item.ValueCount -eq 0 -and @(Get-ChildItem -Path $script:ExplorerPolicyKey -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $script:ExplorerPolicyKey -Force -ErrorAction SilentlyContinue
        }
    }
    if (-not $LegacyKeyExisted -and (Test-Path $script:LegacyWuPolicyKey)) {
        $item = Get-Item -Path $script:LegacyWuPolicyKey -ErrorAction SilentlyContinue
        if ($item -and $item.ValueCount -eq 0 -and @(Get-ChildItem -Path $script:LegacyWuPolicyKey -ErrorAction SilentlyContinue).Count -eq 0) {
            Remove-Item $script:LegacyWuPolicyKey -Force -ErrorAction SilentlyContinue
        }
    }
}

# ---------------------------------------------------------------------------
# Backup
# ---------------------------------------------------------------------------
function Backup-WuState {
    param([string]$BaseDir)

    if (-not $BaseDir) { $BaseDir = $env:TEMP }
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
    $dir = Join-Path $BaseDir "backup-$stamp"
    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    if (Test-Path "Registry::$script:WuPolicyReg") {
        & reg.exe export $script:WuPolicyReg (Join-Path $dir 'WindowsUpdate-policy.reg') /y | Out-Null
    }
    if (Test-Path $script:PolPath) {
        Copy-Item $script:PolPath (Join-Path $dir 'Registry.pol.bak') -Force
    }
    if (Test-Path $script:UxKey) {
        & reg.exe export 'HKLM\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' (Join-Path $dir 'UX-Settings.reg') /y | Out-Null
    }
    if (Test-Path $script:ExplorerPolicyKey) {
        & reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\Explorer' (Join-Path $dir 'Explorer-policy.reg') /y | Out-Null
    }
    if (Test-Path $script:LegacyWuPolicyKey) {
        & reg.exe export 'HKLM\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\WindowsUpdate' (Join-Path $dir 'Legacy-WindowsUpdate-policy.reg') /y | Out-Null
    }
    if (Test-Path $script:MarkerKey) {
        & reg.exe export 'HKLM\SOFTWARE\WindowsUpdateManager' (Join-Path $dir 'Manager-state.reg') /y | Out-Null
    }

    return $dir
}

# ---------------------------------------------------------------------------
# Original-state snapshot
# ---------------------------------------------------------------------------
function Get-WuSnapshotDir {
    param([string]$BaseDir)
    if (-not $BaseDir) { $BaseDir = Join-Path $env:ProgramData 'WindowsUpdateManager' }
    return (Join-Path $BaseDir $script:SnapshotDirName)
}

function ConvertTo-RegistryPsPath {
    param([string]$Path)
    if ($Path -like 'Microsoft.PowerShell.Core\Registry::HKEY_LOCAL_MACHINE*') {
        return ($Path -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_LOCAL_MACHINE', 'HKLM:')
    }
    if ($Path -like 'Microsoft.PowerShell.Core\Registry::HKEY_CURRENT_USER*') {
        return ($Path -replace '^Microsoft\.PowerShell\.Core\\Registry::HKEY_CURRENT_USER', 'HKCU:')
    }
    return $Path
}

function Get-WuRegistrySnapshot {
    param([string]$RootPath)

    $keys = New-Object System.Collections.ArrayList
    $values = New-Object System.Collections.ArrayList

    if (-not (Test-Path $RootPath)) {
        return [pscustomobject]@{ Existed = $false; Keys = @(); Values = @() }
    }

    $all = @($RootPath)
    foreach ($child in @(Get-ChildItem -Path $RootPath -Recurse -ErrorAction SilentlyContinue)) {
        $all += (ConvertTo-RegistryPsPath -Path $child.PSPath)
    }

    foreach ($p in $all) {
        $norm = ConvertTo-RegistryPsPath -Path $p
        if (-not (Test-Path $norm)) { continue }
        [void]$keys.Add($norm)

        $item = Get-Item -Path $norm -ErrorAction SilentlyContinue
        if (-not $item) { continue }
        foreach ($name in $item.GetValueNames()) {
            $kind = $item.GetValueKind($name).ToString()
            # GetValue() expands REG_EXPAND_SZ by default; read it raw so an
            # exact restore does not bake in the current environment.
            if ($kind -eq 'ExpandString') {
                $raw = $item.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            } else {
                $raw = $item.GetValue($name)
            }
            $val = $null
            switch ($kind) {
                'Binary'      { $val = [Convert]::ToBase64String([byte[]]$raw) }
                'Unknown'     { $kind = 'Binary'; $val = [Convert]::ToBase64String([byte[]]$raw) }
                'MultiString' { $val = @($raw) }
                'DWord'       { $val = [string]([uint32]$raw) }
                'QWord'       { $val = [string]([uint64]$raw) }
                default       { $val = [string]$raw }
            }
            [void]$values.Add([pscustomobject]@{
                Path  = $norm
                Name  = $name
                Kind  = $kind
                Value = $val
            })
        }
    }

    return [pscustomobject]@{
        Existed = $true
        Keys    = @($keys)
        Values  = @($values)
    }
}

function Get-WuRegistryValue {
    param([string]$Path, [string]$Name)
    if (-not (Test-Path $Path)) { return $null }
    $item = Get-Item -Path $Path -ErrorAction SilentlyContinue
    if (-not $item) { return $null }
    if ($item.GetValueNames() -notcontains $Name) { return $null }
    if ($item.GetValueKind($Name).ToString() -eq 'ExpandString') {
        return $item.GetValue($Name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
    }
    return $item.GetValue($Name)
}

function Set-WuRegistryValue {
    param(
        [string]$Path,
        [string]$Name,
        [string]$Kind,
        [object]$Value
    )

    if (-not (Test-Path $Path)) { New-Item -Path $Path -Force | Out-Null }

    if ($Kind -eq 'Binary') {
        $converted = [byte[]][Convert]::FromBase64String([string]$Value)
    } elseif ($Kind -eq 'MultiString') {
        $converted = [string[]]@($Value)
    } elseif ($Kind -eq 'DWord') {
        $converted = [uint32]$Value
    } elseif ($Kind -eq 'QWord') {
        $converted = [uint64]$Value
    } else {
        $converted = [string]$Value
    }

    # Use the provider cmdlet instead of RegistryKey.SetValue: Get-Item hands
    # back a read-only key on some PowerShell builds, which makes SetValue throw
    # "Cannot write to the registry key." New-ItemProperty always has write access.
    New-ItemProperty -Path $Path -Name $Name -Value $converted -PropertyType $Kind -Force | Out-Null
}

function Set-WuRegistrySnapshot {
    param([object]$Snapshot)

    if (-not $Snapshot -or -not $Snapshot.Existed) {
        if (Test-Path "Registry::$script:WuPolicyReg") {
            Remove-Item "Registry::$script:WuPolicyReg" -Recurse -Force
        }
        return
    }

    if (Test-Path "Registry::$script:WuPolicyReg") {
        Remove-Item "Registry::$script:WuPolicyReg" -Recurse -Force
    }

    foreach ($k in @($Snapshot.Keys)) {
        if ([string]::IsNullOrEmpty($k)) { continue }
        if (-not (Test-Path $k)) { New-Item -Path $k -Force | Out-Null }
    }

    foreach ($v in @($Snapshot.Values)) {
        if (-not $v -or [string]::IsNullOrEmpty($v.Path)) { continue }
        Set-WuRegistryValue -Path $v.Path -Name $v.Name -Kind $v.Kind -Value $v.Value
    }
}

function Test-WuCurrentlyDisabled {
    # A marker means this tool hid the page. A far-future pause or the complete
    # set of our policy values means the machine is already in the state this
    # tool creates, so saving it as "original" would be wrong.
    $marker = Get-ItemProperty -Path $script:MarkerKey -ErrorAction SilentlyContinue
    if ($marker -and $marker.MenuHidden -eq 1) { return $true }

    if (Test-Path $script:UxKey) {
        $expiry = (Get-ItemProperty -Path $script:UxKey -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
        if ($expiry) {
            try {
                if (([datetime]::Parse($expiry)).ToUniversalTime() -gt (Get-Date).AddYears(50).ToUniversalTime()) { return $true }
            } catch { }
        }
    }

    $ours = 0
    foreach ($s in $script:WuSettings) {
        if (Test-Path $s.Path) {
            $v = Get-WuRegistryValue -Path $s.Path -Name $s.Name
            if ($null -ne $v -and [string]$v -eq [string]$s.Value) { $ours++ }
        }
    }
    if ($ours -eq $script:WuSettings.Count) { return $true }

    return $false
}

function Save-WuOriginalState {
    param([string]$BaseDir)

    $dir = Get-WuSnapshotDir -BaseDir $BaseDir
    $statePath = Join-Path $dir 'state.json'
    if (Test-Path $statePath) { return $dir }

    # Never snapshot a state this tool created (or a far-future pause that is
    # indistinguishable from one). Otherwise Enable would restore "disabled".
    if (Test-WuCurrentlyDisabled) { return $null }

    New-Item -ItemType Directory -Path $dir -Force | Out-Null

    $policy = Get-WuRegistrySnapshot -RootPath $script:WuPolicyKey
    if ($policy.Existed) {
        & reg.exe export $script:WuPolicyReg (Join-Path $dir 'WindowsUpdate-policy.reg') /y 2>$null | Out-Null
        if ($LASTEXITCODE -ne 0) {
            throw 'Could not export the existing Windows Update policy key; nothing was changed.'
        }
    }

    $ux = [ordered]@{}
    foreach ($n in @($script:PauseAllNames + $script:ReleasePinNames)) {
        $v = $null
        if (Test-Path $script:UxKey) {
            $v = (Get-ItemProperty -Path $script:UxKey -Name $n -ErrorAction SilentlyContinue).$n
        }
        $ux[$n] = $(if ($null -eq $v) { $null } else { [string]$v })
    }

    $polExisted = Test-Path $script:PolPath
    $polEntries = @()
    if ($polExisted) {
        $polEntries = @(Get-WuPolEntries | ForEach-Object {
            [pscustomobject]@{
                Key        = $_.Key
                Value      = $_.Value
                Type       = [int]$_.Type
                DataBase64 = [Convert]::ToBase64String([byte[]]$_.Data)
            }
        })
    }

    $spv = $null
    if (Test-Path $script:ExplorerPolicyKey) {
        $spv = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
    }
    $dwua = $null
    if (Test-Path $script:LegacyWuPolicyKey) {
        $dwua = (Get-ItemProperty -Path $script:LegacyWuPolicyKey -Name 'DisableWindowsUpdateAccess' -ErrorAction SilentlyContinue).DisableWindowsUpdateAccess
    }

    $state = [ordered]@{
        version                     = 1
        created                     = (Get-Date).ToString('o')
        policy                      = $policy
        uxKeyExisted                = (Test-Path $script:UxKey)
        ux                          = $ux
        polExisted                  = [bool]$polExisted
        polEntries                  = @($polEntries)
        explorerKeyExisted          = (Test-Path $script:ExplorerPolicyKey)
        settingsPageVisibility      = $(if ($null -eq $spv) { $null } else { [string]$spv })
        legacyKeyExisted            = (Test-Path $script:LegacyWuPolicyKey)
        disableWindowsUpdateAccess  = $(if ($null -eq $dwua) { $null } else { [string]$dwua })
    }

    $state | ConvertTo-Json -Depth 10 | Set-Content -Path $statePath -Encoding UTF8
    Write-WuLog -Message "Saved original state snapshot to $dir" -BaseDir $BaseDir
    return $dir
}

function Restore-WuOriginalState {
    param([string]$BaseDir)

    $dir = Get-WuSnapshotDir -BaseDir $BaseDir
    $statePath = Join-Path $dir 'state.json'
    if (-not (Test-Path $statePath)) { return $null }

    $state = $null
    try {
        $state = Get-Content -Path $statePath -Raw -ErrorAction Stop | ConvertFrom-Json -ErrorAction Stop
        if (-not $state.PSObject.Properties['policy']) { throw 'snapshot is missing the policy section' }
        if (-not $state.PSObject.Properties['ux']) { throw 'snapshot is missing the UX section' }
        if (-not $state.PSObject.Properties['polEntries']) { throw 'snapshot is missing the Registry.pol section' }
    } catch {
        $bad = "$dir.corrupt-" + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Move-Item -Path $dir -Destination $bad -Force -ErrorAction SilentlyContinue
        Write-WuLog -Message "Snapshot could not be read ($($_.Exception.Message)); moved to $bad" -Level 'ERROR' -BaseDir $BaseDir
        return $null
    }

    # 1) Windows Update policy key, exactly as it was.
    Set-WuRegistrySnapshot -Snapshot $state.policy

    # 2) Registry.pol: remove every WU entry, then put the original WU entries back.
    if (Test-Path $script:PolPath) {
        [void](Remove-WuEntriesFromPol -Path $script:PolPath)
        $entries = @($state.polEntries)
        if ($entries.Count -gt 0) {
            $restore = foreach ($e in $entries) {
                [pscustomobject]@{
                    Key   = $e.Key
                    Value = $e.Value
                    Type  = [uint32]$e.Type
                    Data  = [Convert]::FromBase64String([string]$e.DataBase64)
                }
            }
            Add-WuEntriesToPol -Path $script:PolPath -Entries $restore
        }
    }

    # 3) Pause + release pins.
    if (Test-Path $script:UxKey) {
        foreach ($n in @($script:PauseAllNames + $script:ReleasePinNames)) {
            Remove-ItemProperty -Path $script:UxKey -Name $n -Force -ErrorAction SilentlyContinue
        }
        foreach ($p in $state.ux.PSObject.Properties) {
            $val = $p.Value
            if ($null -ne $val -and [string]$val -ne '') {
                New-ItemProperty -Path $script:UxKey -Name $p.Name -Value ([string]$val) -PropertyType String -Force | Out-Null
            }
        }
        if (-not $state.uxKeyExisted) {
            $item = Get-Item -Path $script:UxKey -ErrorAction SilentlyContinue
            if ($item -and $item.ValueCount -eq 0 -and @(Get-ChildItem -Path $script:UxKey -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item $script:UxKey -Force -ErrorAction SilentlyContinue
            }
        }
    }

    # 4) Settings page visibility + legacy value.
    Set-WuPageVisibility `
        -SettingsPageVisibility $state.settingsPageVisibility `
        -DisableWindowsUpdateAccess $state.disableWindowsUpdateAccess `
        -ExplorerKeyExisted ([bool]$state.explorerKeyExisted) `
        -LegacyKeyExisted ([bool]$state.legacyKeyExisted)

    # 5) Clear our marker.
    foreach ($n in @('SavedSPV', 'SavedDWUA', 'MenuHidden')) {
        Remove-ItemProperty -Path $script:MarkerKey -Name $n -Force -ErrorAction SilentlyContinue
    }

    # 6) Delete the snapshot only after everything succeeded.
    Remove-Item -Path $dir -Recurse -Force -ErrorAction SilentlyContinue
    Write-WuLog -Message 'Restored the exact original state from the snapshot.' -BaseDir $BaseDir

    return [pscustomobject]@{
        Restored    = $true
        Snapshot    = $state
        SnapshotDir = $dir
    }
}

# ---------------------------------------------------------------------------
# State
# ---------------------------------------------------------------------------
function Get-WuState {
    $policy = Test-Path "Registry::$script:WuPolicyReg"

    $expiry = $null
    $paused = $false
    if (Test-Path $script:UxKey) {
        $expiry = (Get-ItemProperty -Path $script:UxKey -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
        if ($expiry) {
            try { $paused = ([datetime]::Parse($expiry)).ToUniversalTime() -gt (Get-Date).ToUniversalTime() } catch { }
        }
    }

    $polCount = @(Get-WuPolEntries).Count
    $hidden   = Test-WuMenuHidden

    [pscustomobject]@{
        State        = $(if ($policy -or $paused) { 'Disabled' } else { 'Enabled' })
        PolicyKey    = $policy
        Paused       = $paused
        PauseExpiry  = $expiry
        PolWuEntries = $polCount
        MenuHidden   = $hidden
    }
}

# ---------------------------------------------------------------------------
# Managed-device detection
# ---------------------------------------------------------------------------
function Test-WuManagedDevice {
    $reasons = New-Object System.Collections.ArrayList

    # dsregcmd is the authoritative, cheap answer on Windows 8.1+.
    $dsreg = Join-Path $env:SystemRoot 'System32\dsregcmd.exe'
    if (Test-Path $dsreg) {
        try {
            foreach ($line in @(& $dsreg /status 2>$null)) {
                if ($line -match '^\s*DomainJoined\s*:\s*(\S+)' -and $matches[1] -eq 'YES') {
                    [void]$reasons.Add('domain joined')
                }
                if ($line -match '^\s*AzureAdJoined\s*:\s*(\S+)' -and $matches[1] -eq 'YES') {
                    [void]$reasons.Add('Azure AD joined')
                }
                if ($line -match '^\s*EnterpriseJoined\s*:\s*(\S+)' -and $matches[1] -eq 'YES') {
                    [void]$reasons.Add('Enterprise joined')
                }
                if ($line -match '^\s*MdmUrl\s*:\s*(\S+)' -and $matches[1]) {
                    [void]$reasons.Add("MDM: $($matches[1])")
                }
            }
        } catch { }
    }

    # Registry fallback for Windows 8 and for cases where dsregcmd is missing.
    $domain = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Services\Tcpip\Parameters' -Name 'Domain' -ErrorAction SilentlyContinue).Domain
    if ($domain -and $domain -ne 'WORKGROUP' -and -not ($reasons -contains 'domain joined')) {
        [void]$reasons.Add("domain: $domain")
    }

    # Built-in enrollment stubs (Deploy/Cloud/Local Authority) are not MDM.
    $enrollRoot = 'HKLM:\SOFTWARE\Microsoft\Enrollments'
    if (Test-Path $enrollRoot) {
        foreach ($k in @(Get-ChildItem -Path $enrollRoot -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if (-not $p -or $p.EnrollmentState -ne 1) { continue }
            if ($p.MdmUrl -or $p.ProviderName) {
                [void]$reasons.Add("MDM: $($p.ProviderName)")
                break
            }
            if ($p.ProviderID -and $p.ProviderID -notmatch 'Authority$') {
                [void]$reasons.Add("MDM: $($p.ProviderID)")
                break
            }
        }
    }

    $omadmRoot = 'HKLM:\SOFTWARE\Microsoft\Provisioning\OMADM\Accounts'
    if (Test-Path $omadmRoot) {
        foreach ($k in @(Get-ChildItem -Path $omadmRoot -ErrorAction SilentlyContinue)) {
            $p = Get-ItemProperty -Path $k.PSPath -ErrorAction SilentlyContinue
            if ($p -and @($p.PSObject.Properties).Count -gt 0) {
                [void]$reasons.Add('OMA-DM enrollment')
                break
            }
        }
    }

    $joinRoot = 'HKLM:\SYSTEM\CurrentControlSet\Control\CloudDomainJoin\JoinInfo'
    if (Test-Path $joinRoot) {
        $children = @(Get-ChildItem -Path $joinRoot -ErrorAction SilentlyContinue)
        if ($children.Count -gt 0 -and -not ($reasons -contains 'Azure AD joined')) {
            [void]$reasons.Add('Azure AD joined')
        }
    }

    $reasons = @($reasons | Select-Object -Unique)
    return [pscustomobject]@{
        Managed = ($reasons.Count -gt 0)
        Reasons = @($reasons)
    }
}

# ---------------------------------------------------------------------------
# Read-back verification
# ---------------------------------------------------------------------------
function Test-WuApplied {
    param(
        [ValidateSet('Disabled', 'Enabled')][string]$Expected,
        [object]$SnapshotState,
        [string]$BaseDir
    )

    $checks = New-Object System.Collections.ArrayList
    $add = {
        param($name, $ok, $detail)
        [void]$checks.Add([pscustomobject]@{
            Name   = $name
            Ok     = [bool]$ok
            Detail = [string]$detail
        })
    }

    if ($Expected -eq 'Disabled') {
        foreach ($s in $script:WuSettings) {
            $v = Get-WuRegistryValue -Path $s.Path -Name $s.Name
            $ok = ($null -ne $v -and [string]$v -eq [string]$s.Value)
            & $add "$($s.Name)=$($s.Value)" $ok "got '$v'"
        }

        $polNames = @(Get-WuPolEntries | ForEach-Object { $_.Value })
        $polOk = $true
        foreach ($s in $script:WuSettings) {
            if (-not ($polNames -contains $s.Name)) { $polOk = $false }
        }
        & $add 'Registry.pol mirrors the 8 tool values' ($polOk -and $polNames.Count -eq 8) "($($polNames.Count) WU entries)"

        & $add 'Settings page hidden' (Test-WuMenuHidden)

        $expiry = $null
        if (Test-Path $script:UxKey) {
            $expiry = (Get-ItemProperty -Path $script:UxKey -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
        }
        $far = $false
        if ($expiry) {
            try { $far = ([datetime]::Parse($expiry)).ToUniversalTime() -gt (Get-Date).AddYears(1).ToUniversalTime() } catch { }
        }
        & $add 'Pause expiry is far in the future' $far "($expiry)"
        & $add 'State reports Disabled' ((Get-WuState).State -eq 'Disabled')
    } else {
        if ($SnapshotState) {
            $snapPolicy = $SnapshotState.policy
            $policyExists = Test-Path "Registry::$script:WuPolicyReg"
            & $add 'Policy key existence matches original' ($policyExists -eq [bool]$snapPolicy.Existed) "(exists=$policyExists, original=$($snapPolicy.Existed))"

            if ($snapPolicy.Existed) {
                $missing = 0
                $mismatched = 0
                foreach ($v in @($snapPolicy.Values)) {
                    $cur = Get-WuRegistryValue -Path $v.Path -Name $v.Name
                    if ($null -eq $cur) { $missing++; continue }
                    $want = $v.Value
                    switch ($v.Kind) {
                        'Binary'      { $curStr = [Convert]::ToBase64String([byte[]]$cur) }
                        'MultiString' { $curStr = (@($cur) -join "`n"); $want = (@($want) -join "`n") }
                        'DWord'       { $curStr = [string]([uint64]$cur) }
                        'QWord'       { $curStr = [string]([uint64]$cur) }
                        default       { $curStr = [string]$cur }
                    }
                    if ($curStr -ne [string]$want) { $mismatched++ }
                }
                & $add 'Original policy values restored' (($missing -eq 0) -and ($mismatched -eq 0)) "(missing=$missing, mismatched=$mismatched)"
            }

            $origPol = @($SnapshotState.polEntries)
            $curPol = @(Get-WuPolEntries)
            $polMatch = ($origPol.Count -eq $curPol.Count)
            if ($polMatch) {
                for ($i = 0; $i -lt $origPol.Count; $i++) {
                    if ($origPol[$i].Key -ne $curPol[$i].Key -or
                        $origPol[$i].Value -ne $curPol[$i].Value -or
                        [int]$origPol[$i].Type -ne [int]$curPol[$i].Type -or
                        $origPol[$i].DataBase64 -ne [Convert]::ToBase64String([byte[]]$curPol[$i].Data)) {
                        $polMatch = $false
                        break
                    }
                }
            }
            & $add 'Original Registry.pol entries restored' $polMatch "(original=$($origPol.Count), now=$($curPol.Count))"

            $uxOk = $true
            foreach ($p in $SnapshotState.ux.PSObject.Properties) {
                $cur = $null
                if (Test-Path $script:UxKey) {
                    $cur = (Get-ItemProperty -Path $script:UxKey -Name $p.Name -ErrorAction SilentlyContinue).$($p.Name)
                }
                $want = $p.Value
                if ($null -eq $want -or [string]$want -eq '') {
                    if ($null -ne $cur) { $uxOk = $false }
                } elseif ([string]$cur -ne [string]$want) {
                    $uxOk = $false
                }
            }
            & $add 'Original pause / release values restored' $uxOk

            $spv = $null
            if (Test-Path $script:ExplorerPolicyKey) {
                $spv = (Get-ItemProperty -Path $script:ExplorerPolicyKey -Name 'SettingsPageVisibility' -ErrorAction SilentlyContinue).SettingsPageVisibility
            }
            $wantSpv = $SnapshotState.settingsPageVisibility
            & $add 'Original SettingsPageVisibility restored' ([string]$spv -eq [string]$wantSpv) "(got '$spv', want '$wantSpv')"
        } else {
            $left = @()
            foreach ($s in $script:WuSettings) {
                $v = Get-WuRegistryValue -Path $s.Path -Name $s.Name
                if ($null -ne $v) { $left += $s.Name }
            }
            & $add 'No tool policy values left behind' ($left.Count -eq 0) "($($left -join ', '))"

            $polNames = @(Get-WuPolEntries | ForEach-Object { $_.Value })
            $ourLeft = @($polNames | Where-Object { $script:WuSettingNames -contains $_ })
            & $add 'No tool Registry.pol entries left behind' ($ourLeft.Count -eq 0) "($($ourLeft -join ', '))"

            $expiry = $null
            if (Test-Path $script:UxKey) {
                $expiry = (Get-ItemProperty -Path $script:UxKey -Name 'PauseUpdatesExpiryTime' -ErrorAction SilentlyContinue).PauseUpdatesExpiryTime
            }
            $far = $false
            if ($expiry) {
                try { $far = ([datetime]::Parse($expiry)).ToUniversalTime() -gt (Get-Date).AddYears(1).ToUniversalTime() } catch { }
            }
            & $add 'Pause cleared' (-not $far) "($expiry)"
        }

        $marker = Get-ItemProperty -Path $script:MarkerKey -ErrorAction SilentlyContinue
        & $add 'Menu marker cleared' (-not ($marker -and $marker.MenuHidden -eq 1))
    }

    $failed = @($checks | Where-Object { -not $_.Ok })
    $ok = ($failed.Count -eq 0)
    $summary = if ($ok) {
        "All $($checks.Count) checks passed."
    } else {
        "$($failed.Count) of $($checks.Count) checks failed: " + (($failed | ForEach-Object { $_.Name }) -join '; ')
    }

    Write-WuLog -Message "Verification ($Expected): $summary" -Level $(if ($ok) { 'INFO' } else { 'WARN' }) -BaseDir $BaseDir

    return [pscustomobject]@{
        Expected = $Expected
        Ok       = $ok
        Checks   = @($checks)
        Summary  = $summary
    }
}

# ---------------------------------------------------------------------------
# Disable
# ---------------------------------------------------------------------------
function Disable-WuFast {
    param([string]$BaseDir)

    $snapshotDir = Save-WuOriginalState -BaseDir $BaseDir
    $backup = Backup-WuState -BaseDir $BaseDir

    # 1) Pause updates far in the future. This is the switch that actually stops
    #    Windows Update from scanning/downloading/installing.
    if (-not (Test-Path $script:UxKey)) { New-Item -Path $script:UxKey -Force | Out-Null }
    $now = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    $far = '2099-12-31T23:59:59Z'
    foreach ($n in $script:PauseStartNames) {
        New-ItemProperty -Path $script:UxKey -Name $n -Value $now -PropertyType String -Force | Out-Null
    }
    foreach ($n in $script:PauseEndNames) {
        New-ItemProperty -Path $script:UxKey -Name $n -Value $far -PropertyType String -Force | Out-Null
    }

    # 2) Policy values. Only create missing keys: New-Item -Force on an existing
    #    registry key deletes every value in it, which would destroy pre-existing
    #    policy (for example TargetReleaseVersion) that Enable could not restore
    #    when no snapshot exists.
    if (-not (Test-Path $script:WuPolicyKey)) { New-Item -Path $script:WuPolicyKey -Force | Out-Null }
    if (-not (Test-Path $script:AuKey)) { New-Item -Path $script:AuKey -Force | Out-Null }

    foreach ($s in $script:WuSettings) {
        New-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value -PropertyType DWord -Force | Out-Null
    }

    # 3) Mirror into Registry.pol so Group Policy keeps it after reboot/refresh.
    if (Test-Path $script:PolPath) {
        [void](Remove-WuEntriesFromPol -Path $script:PolPath)
        $entries = foreach ($s in $script:WuSettings) {
            [pscustomobject]@{
                Key   = ($s.Path -replace '^HKLM:\\', '')
                Value = $s.Name
                Type  = 4
                Data  = [BitConverter]::GetBytes([uint32]$s.Value)
            }
        }
        Add-WuEntriesToPol -Path $script:PolPath -Entries $entries
    }

    # 4) Hide the Windows Update page in Settings (removed again by Enable).
    Hide-WuMenu

    # 5) Deliberately do NOT stop or disable any service. Microsoft Store depends
    #    on wuauserv / UsoSvc / DoSvc, so Disable only applies policy + pause.
    $verify = Test-WuApplied -Expected Disabled -BaseDir $BaseDir
    Write-WuLog -Message "Disable complete. Backup: $backup; Snapshot: $snapshotDir" -BaseDir $BaseDir

    return [pscustomobject]@{
        BackupDir    = $backup
        SnapshotDir  = $snapshotDir
        Verification = $verify
    }
}

# ---------------------------------------------------------------------------
# Services (start only; never disable)
# ---------------------------------------------------------------------------
function Start-WuServices {
    foreach ($name in @('bits', 'cryptsvc', 'wuauserv', 'DoSvc', 'UsoSvc')) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if ($svc -and $svc.Status -ne 'Running') {
            try { Start-Service -Name $name -ErrorAction Stop } catch { }
        }
    }
}

function Remove-EmptyWuPolicyKeys {
    foreach ($k in @($script:AuKey, $script:WuPolicyKey)) {
        if (Test-Path $k) {
            $item = Get-Item -Path $k -ErrorAction SilentlyContinue
            if ($item -and $item.ValueCount -eq 0 -and @(Get-ChildItem -Path $k -ErrorAction SilentlyContinue).Count -eq 0) {
                Remove-Item $k -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ---------------------------------------------------------------------------
# Enable
# ---------------------------------------------------------------------------
function Enable-WuFast {
    param([string]$BaseDir)

    $backup = Backup-WuState -BaseDir $BaseDir
    $restored = Restore-WuOriginalState -BaseDir $BaseDir
    $mode = 'snapshot'

    if (-not $restored) {
        $mode = 'fallback'

        # No snapshot: remove only the values this tool owns. Anything that was
        # already on the machine (for example TargetReleaseVersion) is left alone.
        foreach ($s in $script:WuSettings) {
            if (Test-Path $s.Path) {
                Remove-ItemProperty -Path $s.Path -Name $s.Name -Force -ErrorAction SilentlyContinue
            }
        }

        # Remove only our named entries from Registry.pol.
        if (Test-Path $script:PolPath) {
            [void](Remove-WuEntriesFromPol -Path $script:PolPath -OnlyValues $script:WuSettingNames)
        }

        # Clear the pause values we set, but leave release pins untouched.
        if (Test-Path $script:UxKey) {
            foreach ($n in $script:PauseAllNames) {
                Remove-ItemProperty -Path $script:UxKey -Name $n -Force -ErrorAction SilentlyContinue
            }
        }

        $marker = Get-ItemProperty -Path $script:MarkerKey -ErrorAction SilentlyContinue
        if ($marker -and $marker.MenuHidden -eq 1) {
            Show-WuMenu
        } else {
            Remove-WuPageHiding
        }

        Remove-EmptyWuPolicyKeys
        Write-WuLog -Message 'No snapshot found; used the safe fallback removal.' -Level 'WARN' -BaseDir $BaseDir
    }

    # Restore normal service start types and start the essentials.
    $services = [ordered]@{
        wuauserv  = 'Manual'
        bits      = 'Automatic'
        cryptsvc  = 'Automatic'
        UsoSvc    = 'Manual'
        DoSvc     = 'Manual'
        msiserver = 'Manual'
    }
    foreach ($name in $services.Keys) {
        $svc = Get-Service -Name $name -ErrorAction SilentlyContinue
        if (-not $svc) { continue }
        try {
            Set-Service -Name $name -StartupType $services[$name] -ErrorAction Stop
        } catch { }
    }

    Start-WuServices

    $verify = Test-WuApplied -Expected Enabled -SnapshotState $(if ($restored) { $restored.Snapshot } else { $null }) -BaseDir $BaseDir
    Write-WuLog -Message "Enable complete ($mode). Backup: $backup" -BaseDir $BaseDir

    return [pscustomobject]@{
        BackupDir    = $backup
        Mode         = $mode
        Verification = $verify
    }
}
