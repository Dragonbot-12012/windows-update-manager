<#
.SYNOPSIS
    Shared Windows Update enable/disable core used by the GUI and the tests.

.DESCRIPTION
    Disable does four things that actually stop Windows Update:
      1. Pauses updates far in the future (the real switch Settings > Pause uses)
      2. Applies the local policy blocks + mirrors them into Registry.pol
      3. Hides the Windows Update page in Settings (restores it on Enable)
      4. Leaves all services running so Microsoft Store keeps working

    Enable reverses all of it and restores normal service start types.

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
    param([string]$Path)

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

        while ($pos + 1 -lt $bytes.Length -and -not ($bytes[$pos] -eq 0 -and $bytes[$pos + 1] -eq 0)) { $pos += 2 }
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

        if ($key -like 'Software\Policies\Microsoft\Windows\WindowsUpdate*') {
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
# Disable
# ---------------------------------------------------------------------------
function Disable-WuFast {
    param([string]$BaseDir)

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

    # 2) Policy values.
    New-Item -Path $script:WuPolicyKey -Force | Out-Null
    New-Item -Path $script:AuKey -Force | Out-Null

    $settings = @(
        @{ Path = $script:WuPolicyKey; Name = 'SetDisableUXWUAccess';                          Value = 1 },
        @{ Path = $script:WuPolicyKey; Name = 'DoNotConnectToWindowsUpdateInternetLocations'; Value = 1 },
        @{ Path = $script:WuPolicyKey; Name = 'DeferQualityUpdates';                          Value = 1 },
        @{ Path = $script:WuPolicyKey; Name = 'DeferQualityUpdatesPeriodInDays';              Value = 30 },
        @{ Path = $script:WuPolicyKey; Name = 'DeferFeatureUpdates';                          Value = 1 },
        @{ Path = $script:WuPolicyKey; Name = 'DeferFeatureUpdatesPeriodInDays';              Value = 30 },
        @{ Path = $script:AuKey;       Name = 'NoAutoUpdate';                                 Value = 1 },
        @{ Path = $script:AuKey;       Name = 'AUOptions';                                    Value = 1 }
    )

    foreach ($s in $settings) {
        New-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value -PropertyType DWord -Force | Out-Null
    }

    # 3) Mirror into Registry.pol so Group Policy keeps it after reboot/refresh.
    if (Test-Path $script:PolPath) {
        [void](Remove-WuEntriesFromPol -Path $script:PolPath)
        $entries = foreach ($s in $settings) {
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
    return $backup
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

# ---------------------------------------------------------------------------
# Enable
# ---------------------------------------------------------------------------
function Enable-WuFast {
    param([string]$BaseDir)

    $backup = Backup-WuState -BaseDir $BaseDir

    # 1) Remove policy key.
    if (Test-Path "Registry::$script:WuPolicyReg") {
        Remove-Item "Registry::$script:WuPolicyReg" -Recurse -Force
    }

    # 2) Clean Registry.pol.
    if (Test-Path $script:PolPath) {
        [void](Remove-WuEntriesFromPol -Path $script:PolPath)
    }

    # 3) Clear pause + release pins.
    if (Test-Path $script:UxKey) {
        foreach ($n in @($script:PauseAllNames + @('TargetReleaseVersion', 'TargetReleaseVersionInfo'))) {
            Remove-ItemProperty -Path $script:UxKey -Name $n -Force -ErrorAction SilentlyContinue
        }
    }

    # 4) Show the Windows Update page in Settings again.
    Show-WuMenu

    # 5) Restore normal service start types and start the essentials.
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

    return $backup
}
