<#
.SYNOPSIS
    Builds "Windows Update Manager" into a single self-contained .exe.

.DESCRIPTION
    - Inlines WuCore.ps1 into the GUI script (no side files needed at runtime)
    - Embeds assets/logo.png as base64 inside the executable
    - Generates assets/logo.ico from the same PNG
    - Compiles with ps2exe into one .exe that requests admin and uses STA

    Requires the ps2exe module:
        Install-Module ps2exe -Scope CurrentUser

.PARAMETER OutputPath
    Where to write the .exe. Defaults to dist\Windows Update Manager.exe
    in the repository root.

.PARAMETER Version
    Four-part file version. Defaults to 1.0.0.0.

.EXAMPLE
    .\src\Build-Exe.ps1
    .\src\Build-Exe.ps1 -Version 1.0.1.0
#>
[CmdletBinding()]
param(
    [string]$OutputPath,
    [string]$Version = '1.0.0.0'
)

$ErrorActionPreference = 'Stop'

$srcDir   = $PSScriptRoot
if (-not $srcDir) { $srcDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repoRoot = Split-Path -Parent $srcDir

$corePath = Join-Path $srcDir  'WuCore.ps1'
$guiPath  = Join-Path $srcDir  'WindowsUpdateManager.ps1'
$logoPng  = Join-Path $repoRoot 'assets\logo.png'
$logoIco  = Join-Path $repoRoot 'assets\logo.ico'
$distDir  = Join-Path $repoRoot 'dist'
if (-not $OutputPath) { $OutputPath = Join-Path $distDir 'Windows Update Manager.exe' }

foreach ($f in @($corePath, $guiPath, $logoPng)) {
    if (-not (Test-Path $f)) { throw "Missing required file: $f" }
}
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

# ---------------------------------------------------------------------------
# 1) Build a 256x256 PNG-compressed .ico from the logo
# ---------------------------------------------------------------------------
$pngBytes = [IO.File]::ReadAllBytes($logoPng)

$icoStream = New-Object IO.MemoryStream
$bw = New-Object IO.BinaryWriter($icoStream)
$bw.Write([UInt16]0)      # reserved
$bw.Write([UInt16]1)      # type = icon
$bw.Write([UInt16]1)      # image count
$bw.Write([Byte]0)        # width 256 (0 means 256)
$bw.Write([Byte]0)        # height 256
$bw.Write([Byte]0)        # palette
$bw.Write([Byte]0)        # reserved
$bw.Write([UInt16]1)      # planes
$bw.Write([UInt16]32)     # bits per pixel
$bw.Write([UInt32]$pngBytes.Length)
$bw.Write([UInt32]22)     # data offset
$bw.Write($pngBytes)
$bw.Flush()
[IO.File]::WriteAllBytes($logoIco, $icoStream.ToArray())
$bw.Dispose(); $icoStream.Dispose()

# ---------------------------------------------------------------------------
# 2) Combine core + GUI and embed the logo
# ---------------------------------------------------------------------------
$core = Get-Content $corePath -Raw
$gui  = Get-Content $guiPath  -Raw

$oldBlock = @'
# ---------------------------------------------------------------------------
# Paths + shared core
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    # In a ps2exe build both $PSScriptRoot and the command path are empty,
    # so only resolve a parent directory when there actually is a path.
    $cmdPath = $MyInvocation.MyCommand.Path
    if ($cmdPath) { $scriptDir = Split-Path -Parent $cmdPath }
}

# Backups always go to ProgramData so nothing is written next to the app.
$base = Join-Path $env:ProgramData 'WindowsUpdateManager'
New-Item -ItemType Directory -Path $base -Force | Out-Null

$core = Join-Path $scriptDir 'WuCore.ps1'
if (-not (Test-Path $core)) {
    [System.Windows.MessageBox]::Show("WuCore.ps1 is missing next to this script.`n`nExpected: $core", 'Windows Update Manager', 'OK', 'Error') | Out-Null
    exit 1
}
. $core
'@

$newBlock = @'
# ---------------------------------------------------------------------------
# Paths (the core is inlined in the compiled build)
# ---------------------------------------------------------------------------
$scriptDir = $PSScriptRoot
if (-not $scriptDir) {
    # ps2exe leaves both $PSScriptRoot and the command path empty. This block
    # must never call Split-Path with a null path, or startup throws.
    $cmdPath = $MyInvocation.MyCommand.Path
    if ($cmdPath) { $scriptDir = Split-Path -Parent $cmdPath }
}

# Backups always go to ProgramData so nothing is written next to the app.
$base = Join-Path $env:ProgramData 'WindowsUpdateManager'
New-Item -ItemType Directory -Path $base -Force | Out-Null
'@

if (-not $gui.Contains($oldBlock)) { throw 'Could not find the shared-core block in the GUI script.' }
$gui = $gui.Replace($oldBlock, $newBlock)

$b64 = [Convert]::ToBase64String($pngBytes)
$placeholder = "`$logoBase64 = '__LOGO_BASE64__'"
if (-not $gui.Contains($placeholder)) { throw 'Could not find the logo placeholder in the GUI script.' }
$gui = $gui.Replace($placeholder, "`$logoBase64 = '$b64'")

$combined = $core.TrimEnd() + "`r`n`r`n" + $gui
$src = Join-Path $env:TEMP 'wu-manager-exe-src.ps1'
Set-Content -Path $src -Value $combined -Encoding UTF8

# ---------------------------------------------------------------------------
# 3) Compile
# ---------------------------------------------------------------------------
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Import-Module ps2exe -Force

if (Test-Path $OutputPath) { Remove-Item $OutputPath -Force }

Invoke-PS2EXE `
    -inputFile $src `
    -outputFile $OutputPath `
    -noConsole `
    -STA `
    -requireAdmin `
    -x64 `
    -supportOS `
    -iconFile $logoIco `
    -version $Version `
    -title 'Windows Update Manager' `
    -product 'Windows Update Manager' `
    -company 'dragonbot' `
    -description 'Enable or disable Windows Update by policy. Microsoft Store keeps working.' `
    -copyright 'made by dragonbot'

if (-not (Test-Path $OutputPath)) { throw 'Compilation did not produce an executable.' }

$exe = Get-Item $OutputPath
Write-Host ""
Write-Host "Built: $($exe.FullName)"
Write-Host "Size : $([math]::Round($exe.Length / 1KB, 0)) KB"
Write-Host "Ver  : $Version"
