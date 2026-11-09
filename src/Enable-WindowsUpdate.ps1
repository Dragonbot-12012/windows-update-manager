<#
.SYNOPSIS
    Re-enables Windows Update on Windows 10 / 11 (Home, Pro, Enterprise, Education).

.DESCRIPTION
    Removes the local Group Policy / registry blocks that stop Windows Update from
    working, resets the update components, and starts a new update scan.

    This script does NOT use gpedit.msc, so it also works on Windows Home.

.PARAMETER SkipComponentReset
    Do not rename SoftwareDistribution / catroot2 (keeps the download cache).

.PARAMETER NoPause
    Do not wait for a key press at the end (useful for automation).

.NOTES
    Must be run as Administrator. The script will ask for elevation automatically.
    A backup of the current policy is saved in a "backup-<timestamp>" folder next
    to this script before anything is changed.
#>

[CmdletBinding()]
param(
    [switch]$SkipComponentReset,
    [switch]$NoPause,
    [switch]$NoSettings
)

# ---------------------------------------------------------------------------
# Self-elevate
# ---------------------------------------------------------------------------
$principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Write-Host "Requesting administrator rights..." -ForegroundColor Yellow
    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$self`"")
    if ($SkipComponentReset) { $argList += '-SkipComponentReset' }
    if ($NoPause) { $argList += '-NoPause' }
    if ($NoSettings) { $argList += '-NoSettings' }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList
    } catch {
        Write-Host "Elevation was cancelled. Nothing was changed." -ForegroundColor Red
        Start-Sleep -Seconds 3
    }
    exit
}

$ErrorActionPreference = 'Continue'

function Write-Step($msg) { Write-Host "`n[*] $msg" -ForegroundColor Cyan }
function Write-Ok($msg)   { Write-Host "    OK: $msg" -ForegroundColor Green }
function Write-Warn2($msg){ Write-Host "    WARN: $msg" -ForegroundColor Yellow }
function Write-Err2($msg) { Write-Host "    ERROR: $msg" -ForegroundColor Red }

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$base  = $PSScriptRoot
if (-not $base) { $base = $env:TEMP }
$backupDir = Join-Path $base "backup-$stamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

Write-Host "=========================================================" -ForegroundColor White
Write-Host "  Windows Update - ENABLE / REPAIR" -ForegroundColor White
Write-Host "  Backup folder: $backupDir" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor White

# ---------------------------------------------------------------------------
# 1. Back up current policy
# ---------------------------------------------------------------------------
Write-Step "Backing up current policy"

$wuPolicy = 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$polPath  = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Registry.pol'

if (Test-Path "Registry::$wuPolicy") {
    & reg.exe export $wuPolicy (Join-Path $backupDir 'WindowsUpdate-policy.reg') /y | Out-Null
    Write-Ok "Exported $wuPolicy"
} else {
    Write-Warn2 "No Windows Update policy key found (already clean)."
}

if (Test-Path $polPath) {
    Copy-Item $polPath (Join-Path $backupDir 'Registry.pol.bak') -Force
    Write-Ok "Copied Registry.pol"
}

# ---------------------------------------------------------------------------
# 2. Remove live policy registry values
# ---------------------------------------------------------------------------
Write-Step "Removing Windows Update policy values"

if (Test-Path "Registry::$wuPolicy") {
    try {
        Remove-Item "Registry::$wuPolicy" -Recurse -Force -ErrorAction Stop
        Write-Ok "Deleted $wuPolicy"
    } catch {
        Write-Err2 "Could not delete policy key: $($_.Exception.Message)"
    }
} else {
    Write-Ok "Nothing to delete."
}

# ---------------------------------------------------------------------------
# 3. Remove Windows Update entries from the local GPO file (Pro/Enterprise)
# ---------------------------------------------------------------------------
function Remove-WuEntriesFromPol {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8) { return 0 }

    # PReg header: "PReg" + 4-byte version
    $out = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt 8; $i++) { $out.Add($bytes[$i]) }

    $pos = 8
    $removed = 0

    while ($pos -lt $bytes.Length) {
        if ($bytes[$pos] -ne 0x5B) { $pos++; continue }   # '['

        $entryStart = $pos
        $pos += 2

        # Key name (UTF-16LE, NUL-terminated)
        $keyStart = $pos
        while ($pos + 1 -lt $bytes.Length -and -not ($bytes[$pos] -eq 0 -and $bytes[$pos + 1] -eq 0)) { $pos += 2 }
        $key = [Text.Encoding]::Unicode.GetString($bytes, $keyStart, $pos - $keyStart)
        $pos += 2
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        # Value name (UTF-16LE, NUL-terminated)
        $valStart = $pos
        while ($pos + 1 -lt $bytes.Length -and -not ($bytes[$pos] -eq 0 -and $bytes[$pos + 1] -eq 0)) { $pos += 2 }
        $pos += 2
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        # Type (DWORD)
        $pos += 4
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        # Size (DWORD)
        $size = [BitConverter]::ToUInt32($bytes, $pos)
        $pos += 4
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        # Data
        $pos += [int]$size
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x5D) { $pos += 2 } else { break }   # ']'

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

Write-Step "Cleaning local Group Policy file"
if (Test-Path $polPath) {
    try {
        $removed = Remove-WuEntriesFromPol -Path $polPath
        Write-Ok "Removed $removed Windows Update entries from Registry.pol"
    } catch {
        Write-Err2 "Could not rewrite Registry.pol: $($_.Exception.Message)"
        Write-Warn2 "Falling back to deleting it (backup already saved)."
        try { Remove-Item $polPath -Force -ErrorAction Stop; Write-Ok "Deleted Registry.pol" }
        catch { Write-Err2 "Could not delete Registry.pol: $($_.Exception.Message)" }
    }
} else {
    Write-Ok "No local machine policy file (normal on Windows Home)."
}

# ---------------------------------------------------------------------------
# 4. Clear any pause / deferral state
# ---------------------------------------------------------------------------
Write-Step "Clearing pause / deferral state"

$uxKey = 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings'
$pauseNames = @(
    'PauseUpdatesExpiryTime',
    'PauseFeatureUpdatesStartTime',
    'PauseQualityUpdatesStartTime',
    'PauseFeatureUpdatesEndTime',
    'PauseQualityUpdatesEndTime'
)
foreach ($n in $pauseNames) {
    if ($null -ne (Get-ItemProperty -Path $uxKey -Name $n -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -Path $uxKey -Name $n -Force -ErrorAction SilentlyContinue
        Write-Ok "Cleared $n"
    }
}

# Also remove the old "TargetReleaseVersion" pin, if present under UX
foreach ($n in @('TargetReleaseVersion', 'TargetReleaseVersionInfo')) {
    if ($null -ne (Get-ItemProperty -Path $uxKey -Name $n -ErrorAction SilentlyContinue)) {
        Remove-ItemProperty -Path $uxKey -Name $n -Force -ErrorAction SilentlyContinue
        Write-Ok "Cleared $n"
    }
}

# ---------------------------------------------------------------------------
# 5. Make sure services are not disabled
# ---------------------------------------------------------------------------
Write-Step "Checking Windows Update services"

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
    if ($svc) {
        try {
            Set-Service -Name $name -StartupType $services[$name] -ErrorAction Stop
            if ($svc.Status -ne 'Running' -and $name -in @('bits', 'cryptsvc')) {
                Start-Service -Name $name -ErrorAction SilentlyContinue
            }
            Write-Ok "$name -> $($services[$name])"
        } catch {
            Write-Warn2 "$name could not be changed: $($_.Exception.Message)"
        }
    }
}

# ---------------------------------------------------------------------------
# 6. Refresh policy
# ---------------------------------------------------------------------------
Write-Step "Refreshing Group Policy"
try {
    & gpupdate.exe /force | Out-Null
    Write-Ok "gpupdate completed"
} catch {
    Write-Warn2 "gpupdate failed: $($_.Exception.Message)"
}

# ---------------------------------------------------------------------------
# 7. Reset update components (optional)
# ---------------------------------------------------------------------------
if (-not $SkipComponentReset) {
    Write-Step "Resetting Windows Update components"

    $stopList = @('wuauserv', 'bits', 'cryptsvc', 'UsoSvc', 'DoSvc')
    foreach ($s in $stopList) {
        Stop-Service -Name $s -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 2

    $sd = Join-Path $env:SystemRoot 'SoftwareDistribution'
    if (Test-Path $sd) {
        try {
            Rename-Item -Path $sd -NewName "SoftwareDistribution.old-$stamp" -ErrorAction Stop
            Write-Ok "Renamed SoftwareDistribution"
        } catch {
            Write-Warn2 "Could not rename SoftwareDistribution (in use)."
        }
    }

    $cr = Join-Path $env:SystemRoot 'System32\catroot2'
    if (Test-Path $cr) {
        try {
            Rename-Item -Path $cr -NewName "catroot2.old-$stamp" -ErrorAction Stop
            Write-Ok "Renamed catroot2"
        } catch {
            Write-Warn2 "Could not rename catroot2 (in use)."
        }
    }

    foreach ($s in $stopList) {
        Start-Service -Name $s -ErrorAction SilentlyContinue
    }
} else {
    Write-Step "Skipping component reset (-SkipComponentReset)"
}

# ---------------------------------------------------------------------------
# 8. Start a scan and open Settings
# ---------------------------------------------------------------------------
Write-Step "Starting an update scan"
try {
    $au = New-Object -ComObject Microsoft.Update.AutoUpdate
    $au.DetectNow()
    Write-Ok "Update scan requested"
} catch {
    Write-Warn2 "Could not trigger COM scan: $($_.Exception.Message)"
}
try {
    Start-Process -FilePath 'UsoClient.exe' -ArgumentList 'StartScan' -NoNewWindow -ErrorAction Stop
    Write-Ok "UsoClient StartScan sent"
} catch {
    Write-Warn2 "UsoClient not available on this build."
}

Write-Host "`n=========================================================" -ForegroundColor White
Write-Host "  DONE. Windows Update should now be available." -ForegroundColor Green
Write-Host "  Open: Settings > Windows Update" -ForegroundColor Green
Write-Host "  A reboot is recommended before installing updates." -ForegroundColor Yellow
Write-Host "  Backup: $backupDir" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor White

if (-not $NoSettings) {
    try { Start-Process 'ms-settings:windowsupdate' } catch { }
}

if (-not $NoPause) {
    Write-Host "`nPress Enter to close..."
    [void][Console]::ReadLine()
}
