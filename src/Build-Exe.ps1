<#
.SYNOPSIS
    Builds "Windows Update Manager" into self-contained .exe files (x64 and x86).

.DESCRIPTION
    - Inlines WuCore.ps1 into the GUI script (no side files needed at runtime)
    - Embeds assets/logo.png as base64 inside the executable
    - Generates assets/logo.ico from the same PNG
    - Stamps the build version into the GUI footer
    - Compiles with ps2exe into one .exe per architecture, each requesting admin and using STA
    - Verifies the produced PE machine type so a wrong-arch build can never slip through

    Requires the ps2exe module:
        Install-Module ps2exe -Scope CurrentUser

.PARAMETER Architecture
    x64, x86, or Both (default). Both writes
    dist\Windows-Update-Manager-x64.exe and dist\Windows-Update-Manager-x86.exe.

.PARAMETER OutputPath
    Where to write the .exe. Only valid when building a single architecture.

.PARAMETER Version
    Four-part file version. Defaults to 1.0.1.0. The GUI footer shows the first
    three parts (for example v1.0.1).

.EXAMPLE
    .\src\Build-Exe.ps1
    .\src\Build-Exe.ps1 -Architecture x86
    .\src\Build-Exe.ps1 -Architecture x64 -OutputPath "$env:TEMP\WUM.exe"
#>
[CmdletBinding()]
param(
    [ValidateSet('x64', 'x86', 'Both')]
    [string]$Architecture = 'Both',

    [string]$OutputPath,

    [string]$Version = '1.0.1.0'
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

foreach ($f in @($corePath, $guiPath, $logoPng)) {
    if (-not (Test-Path $f)) { throw "Missing required file: $f" }
}
if (-not (Test-Path $distDir)) { New-Item -ItemType Directory -Path $distDir -Force | Out-Null }

$targets = switch ($Architecture) {
    'Both'  { @('x64', 'x86') }
    default { @($Architecture) }
}
if ($OutputPath -and $targets.Count -ne 1) {
    throw '-OutputPath can only be used when building a single architecture.'
}

# 1.0.1.0 -> 1.0.1 for the GUI footer
$shortVersion = ((($Version -split '\.') + @('0', '0', '0'))[0..2]) -join '.'

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
# 2) Combine core + GUI, embed the logo, stamp the version
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
$logoPlaceholder = "`$logoBase64 = '__LOGO_BASE64__'"
if (-not $gui.Contains($logoPlaceholder)) { throw 'Could not find the logo placeholder in the GUI script.' }
$gui = $gui.Replace($logoPlaceholder, "`$logoBase64 = '$b64'")

$versionPlaceholder = "`$appVersion = '__APP_VERSION__'"
if (-not $gui.Contains($versionPlaceholder)) { throw 'Could not find the version placeholder in the GUI script.' }
$gui = $gui.Replace($versionPlaceholder, "`$appVersion = '$shortVersion'")

$combined = $core.TrimEnd() + "`r`n`r`n" + $gui
$src = Join-Path $env:TEMP 'wu-manager-exe-src.ps1'
Set-Content -Path $src -Value $combined -Encoding UTF8

# ---------------------------------------------------------------------------
# 3) Compile each target and verify its PE machine type
# ---------------------------------------------------------------------------
Set-ExecutionPolicy -Scope Process -ExecutionPolicy Bypass -Force
Import-Module ps2exe -Force

function Get-PeMachine {
    param([string]$Path)

    $fs = [IO.File]::OpenRead($Path)
    try {
        $br = New-Object IO.BinaryReader($fs)
        $fs.Position = 0x3C
        $peOffset = $br.ReadInt32()
        if ($peOffset -le 0 -or ($peOffset + 6) -ge $fs.Length) { throw "Invalid PE header in $Path" }
        $fs.Position = $peOffset + 4
        return [int]$br.ReadUInt16()
    } finally {
        $fs.Dispose()
    }
}

$built = @()
foreach ($arch in $targets) {
    $out = if ($OutputPath) { $OutputPath } else { Join-Path $distDir "Windows-Update-Manager-$arch.exe" }
    if (Test-Path $out) { Remove-Item $out -Force }

    $params = @{
        inputFile    = $src
        outputFile   = $out
        noConsole    = $true
        STA          = $true
        requireAdmin = $true
        supportOS    = $true
        iconFile     = $logoIco
        version      = $Version
        title        = 'Windows Update Manager'
        product      = 'Windows Update Manager'
        company      = 'dragonbot'
        description  = 'Enable or disable Windows Update by policy. Microsoft Store keeps working.'
        copyright    = 'made by dragonbot'
    }
    if ($arch -eq 'x64') { $params['x64'] = $true } else { $params['x86'] = $true }

    Write-Host "Compiling $arch ..."
    Invoke-PS2EXE @params

    if (-not (Test-Path $out)) { throw "Compilation did not produce $out" }

    # 0x8664 = AMD64, 0x014C = i386
    $expected = if ($arch -eq 'x64') { 0x8664 } else { 0x014C }
    $actual   = Get-PeMachine $out
    if ($actual -ne $expected) {
        throw ('Architecture check failed for {0}: expected 0x{1:X4}, got 0x{2:X4}' -f $out, $expected, $actual)
    }

    $built += Get-Item $out
}

Write-Host ""
Write-Host "Built $($built.Count) executable(s):"
foreach ($exe in $built) {
    Write-Host "  $($exe.FullName)"
    Write-Host "    size    : $([math]::Round($exe.Length / 1KB, 0)) KB"
    Write-Host "    version : $Version"
    Write-Host "    sha256  : $((Get-FileHash $exe.FullName -Algorithm SHA256).Hash.ToLower())"
}

return $built
