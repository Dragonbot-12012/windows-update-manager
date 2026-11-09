<#
.SYNOPSIS
    Disables Windows Update on Windows 10 / 11 (Home, Pro, Enterprise, Education).

.DESCRIPTION
    Applies local registry policies that block Windows Update and hide the update
    UI. This is reversible: run Enable-WindowsUpdate.ps1 to turn updates back on.

    This script does NOT use gpedit.msc, so it also works on Windows Home.
    It does not disable any services, so Microsoft Store app updates keep working.

.PARAMETER NoPause
    Do not wait for a key press at the end (useful for automation).

.NOTES
    WARNING: Turning Windows Update off is a security risk. Keep this only if you
    really need to. Run as Administrator (the script will ask for elevation).
    A .reg backup is saved in a "backup-<timestamp>" folder next to this script.
#>

[CmdletBinding()]
param(
    [switch]$NoPause
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
    if ($NoPause) { $argList += '-NoPause' }
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

$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$base  = $PSScriptRoot
if (-not $base) { $base = $env:TEMP }
$backupDir = Join-Path $base "backup-$stamp"
New-Item -ItemType Directory -Path $backupDir -Force | Out-Null

Write-Host "=========================================================" -ForegroundColor White
Write-Host "  Windows Update - DISABLE" -ForegroundColor White
Write-Host "  Backup folder: $backupDir" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor White

$wu = 'HKLM:\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate'
$au = Join-Path $wu 'AU'

# ---------------------------------------------------------------------------
# 1. Back up current state
# ---------------------------------------------------------------------------
Write-Step "Backing up current policy"
if (Test-Path $wu) {
    & reg.exe export 'HKLM\SOFTWARE\Policies\Microsoft\Windows\WindowsUpdate' (Join-Path $backupDir 'WindowsUpdate-policy.reg') /y | Out-Null
    Write-Ok "Exported current policy"
} else {
    Write-Ok "No existing policy to back up."
}

# ---------------------------------------------------------------------------
# 2. Remove any existing WU entries from the local GPO file, so gpupdate
#    cannot overwrite the values we are about to write (Pro/Enterprise).
# ---------------------------------------------------------------------------
function Remove-WuEntriesFromPol {
    param([string]$Path)

    $bytes = [IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 8) { return 0 }

    $out = New-Object System.Collections.Generic.List[byte]
    for ($i = 0; $i -lt 8; $i++) { $out.Add($bytes[$i]) }

    $pos = 8
    $removed = 0

    while ($pos -lt $bytes.Length) {
        if ($bytes[$pos] -ne 0x5B) { $pos++; continue }   # '['

        $entryStart = $pos
        $pos += 2

        $keyStart = $pos
        while ($pos + 1 -lt $bytes.Length -and -not ($bytes[$pos] -eq 0 -and $bytes[$pos + 1] -eq 0)) { $pos += 2 }
        $key = [Text.Encoding]::Unicode.GetString($bytes, $keyStart, $pos - $keyStart)
        $pos += 2
        if ($pos + 1 -lt $bytes.Length -and $bytes[$pos] -eq 0x3B) { $pos += 2 } else { break }

        $valStart = $pos
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
        $out.Add(0x5B); $out.Add(0x00)          # '['
        foreach ($b in [Text.Encoding]::Unicode.GetBytes($e.Key)) { $out.Add($b) }
        $out.Add(0x00); $out.Add(0x00)          # NUL terminator
        $out.Add(0x3B); $out.Add(0x00)          # ';'
        foreach ($b in [Text.Encoding]::Unicode.GetBytes($e.Value)) { $out.Add($b) }
        $out.Add(0x00); $out.Add(0x00)          # NUL terminator
        $out.Add(0x3B); $out.Add(0x00)          # ';'
        foreach ($b in [BitConverter]::GetBytes([uint32]$e.Type)) { $out.Add($b) }
        $out.Add(0x3B); $out.Add(0x00)          # ';'
        $data = [byte[]]$e.Data
        foreach ($b in [BitConverter]::GetBytes([uint32]$data.Length)) { $out.Add($b) }
        $out.Add(0x3B); $out.Add(0x00)          # ';'
        foreach ($b in $data) { $out.Add($b) }
        $out.Add(0x5D); $out.Add(0x00)          # ']'
    }

    [IO.File]::WriteAllBytes($Path, $out.ToArray())
}

$polPath = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Registry.pol'
if (Test-Path $polPath) {
    try {
        $removed = Remove-WuEntriesFromPol -Path $polPath
        Write-Ok "Removed $removed old Windows Update entries from Registry.pol"
    } catch {
        Write-Warn2 "Could not clean Registry.pol: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 3. Apply blocking policies
# ---------------------------------------------------------------------------
Write-Step "Applying Windows Update blocks"

New-Item -Path $wu -Force | Out-Null
New-Item -Path $au -Force | Out-Null

$settings = @(
    @{ Path = $wu; Name = 'SetDisableUXWUAccess';                          Value = 1 },
    @{ Path = $wu; Name = 'DoNotConnectToWindowsUpdateInternetLocations'; Value = 1 },
    @{ Path = $wu; Name = 'DeferQualityUpdates';                          Value = 1 },
    @{ Path = $wu; Name = 'DeferQualityUpdatesPeriodInDays';              Value = 30 },
    @{ Path = $wu; Name = 'DeferFeatureUpdates';                          Value = 1 },
    @{ Path = $wu; Name = 'DeferFeatureUpdatesPeriodInDays';              Value = 30 },
    @{ Path = $au; Name = 'NoAutoUpdate';                                 Value = 1 },
    @{ Path = $au; Name = 'AUOptions';                                    Value = 1 }
)

foreach ($s in $settings) {
    try {
        New-ItemProperty -Path $s.Path -Name $s.Name -Value $s.Value -PropertyType DWord -Force -ErrorAction Stop | Out-Null
        Write-Ok "$($s.Name) = $($s.Value)"
    } catch {
        Write-Warn2 "Failed to set $($s.Name): $($_.Exception.Message)"
    }
}

# Also write the same values into Registry.pol so Group Policy keeps them on
# Pro/Enterprise (Home ignores this file and uses the live values above).
if (Test-Path $polPath) {
    try {
        $polEntries = foreach ($s in $settings) {
            [pscustomobject]@{
                Key   = ($s.Path -replace '^HKLM:\\', '')
                Value = $s.Name
                Type  = 4
                Data  = [BitConverter]::GetBytes([uint32]$s.Value)
            }
        }
        Add-WuEntriesToPol -Path $polPath -Entries $polEntries
        Write-Ok "Wrote $($polEntries.Count) entries to Registry.pol"
    } catch {
        Write-Warn2 "Could not write Registry.pol: $($_.Exception.Message)"
    }
}

# ---------------------------------------------------------------------------
# 4. Refresh policy
# ---------------------------------------------------------------------------
Write-Step "Refreshing Group Policy"
try {
    & gpupdate.exe /force | Out-Null
    Write-Ok "gpupdate completed"
} catch {
    Write-Warn2 "gpupdate failed: $($_.Exception.Message)"
}

Write-Host "`n=========================================================" -ForegroundColor White
Write-Host "  DONE. Windows Update is now blocked." -ForegroundColor Yellow
Write-Host "  Settings > Windows Update may show a policy message." -ForegroundColor Yellow
Write-Host "  To turn it back on, run Enable-WindowsUpdate.ps1" -ForegroundColor Green
Write-Host "  Backup: $backupDir" -ForegroundColor DarkGray
Write-Host "=========================================================" -ForegroundColor White

if (-not $NoPause) {
    Write-Host "`nPress Enter to close..."
    [void][Console]::ReadLine()
}
