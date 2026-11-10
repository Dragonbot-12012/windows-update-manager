<#
.SYNOPSIS
    Windows Update Manager - fast, modern GUI toggle.

.DESCRIPTION
    Two buttons:
      Enable  -> removes the Windows Update policy blocks, pause and page hiding
      Disable -> pauses Windows Update, applies the blocks and hides its Settings page

    Services are never stopped or disabled, so Microsoft Store keeps working.

    The heavy lifting lives in WuCore.ps1 so the same code is used by the tests.

.NOTES
    Windows 8 - 11. Requests administrator rights automatically.
#>

$ErrorActionPreference = 'Stop'

# Replaced with the real version at build time (see src/Build-Exe.ps1).
# Script mode keeps the fallback below.
$appVersion = '__APP_VERSION__'
if ($appVersion -like '__*') { $appVersion = '1.0.1' }

# ---------------------------------------------------------------------------
# Ensure elevated + STA
# ---------------------------------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$isSTA   = ([System.Threading.Thread]::CurrentThread.GetApartmentState() -eq [System.Threading.ApartmentState]::STA)

if (-not $isAdmin -or -not $isSTA) {
    # Compiled .exe? Relaunch itself elevated instead of powershell.exe.
    $procPath = $null
    try { $procPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }
    if ($procPath -and $procPath -notmatch 'powershell\.exe$') {
        try { Start-Process -FilePath $procPath -Verb RunAs } catch { }
        exit
    }

    $self = $PSCommandPath
    if (-not $self) { $self = $MyInvocation.MyCommand.Path }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$self`"")
    $verb = 'Open'
    if (-not $isAdmin) { $verb = 'RunAs' }
    try { Start-Process -FilePath 'powershell.exe' -Verb $verb -WindowStyle Hidden -ArgumentList $argList } catch { }
    exit
}

Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName WindowsBase

# Filled in with the logo PNG at build time. Left as a placeholder in script mode,
# where logo.png next to the script is used instead.
$logoBase64 = '__LOGO_BASE64__'

# Dark title bar on Windows 10/11 (harmless on Windows 8)
Add-Type @"
using System;
using System.Runtime.InteropServices;
public class DwmApi {
    [DllImport("dwmapi.dll")]
    public static extern int DwmSetWindowAttribute(IntPtr hwnd, int attr, ref int value, int size);
}
"@

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

# ---------------------------------------------------------------------------
# Architecture guard
# ---------------------------------------------------------------------------
# The 32-bit build is correct on 32-bit Windows. On 64-bit Windows a 32-bit
# process would write to WOW6432Node and SysWOW64, so refuse instead of
# silently doing nothing. Offer the x64 binary when it sits next to us.
if (-not (Test-WuArchitectureSupported)) {
    $selfPath = $null
    try { $selfPath = [System.Diagnostics.Process]::GetCurrentProcess().MainModule.FileName } catch { }

    $x64Path = $null
    if ($selfPath) {
        $selfDir = Split-Path -Parent $selfPath
        foreach ($name in @('Windows-Update-Manager-x64.exe', 'Windows Update Manager.exe')) {
            $candidate = Join-Path $selfDir $name
            if ($candidate -ne $selfPath -and (Test-Path $candidate)) { $x64Path = $candidate; break }
        }
    }

    if ($x64Path) {
        try { Start-Process -FilePath $x64Path; exit 0 } catch { }
    }

    Add-Type -AssemblyName System.Windows.Forms
    [System.Windows.Forms.MessageBox]::Show(
        "This is the 32-bit build, but Windows is 64-bit.`n`nWindows only reads these policies from the 64-bit registry, so the 32-bit build cannot change them here.`n`nUse Windows-Update-Manager-x64.exe, or run the source with 64-bit PowerShell.",
        'Windows Update Manager', 'OK', 'Warning') | Out-Null
    exit 1
}

# ---------------------------------------------------------------------------
# Window (normal frame -> OS default rounded corners)
# ---------------------------------------------------------------------------
[xml]$xaml = @'
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation"
        xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="Windows Update Manager"
        Width="460" SizeToContent="Height"
        ResizeMode="CanMinimize"
        Background="#1B1B2A"
        WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" SnapsToDevicePixels="True" UseLayoutRounding="True"
        TextOptions.TextFormattingMode="Display">
  <Window.Resources>
    <SolidColorBrush x:Key="OkBrush"    Color="#A6E3A1"/>
    <SolidColorBrush x:Key="ErrBrush"   Color="#F38BA8"/>
    <SolidColorBrush x:Key="InfoBrush"  Color="#89B4FA"/>
    <SolidColorBrush x:Key="MutedBrush" Color="#9399B2"/>

    <Style x:Key="ActionButton" TargetType="Button">
      <Setter Property="Foreground" Value="#FFFFFF"/>
      <Setter Property="FontSize" Value="16"/>
      <Setter Property="FontWeight" Value="SemiBold"/>
      <Setter Property="Cursor" Value="Hand"/>
      <Setter Property="BorderThickness" Value="0"/>
      <Setter Property="Template">
        <Setter.Value>
          <ControlTemplate TargetType="Button">
            <Border x:Name="bd" CornerRadius="9" Background="{TemplateBinding Background}">
              <ContentPresenter HorizontalAlignment="Center" VerticalAlignment="Center"/>
            </Border>
            <ControlTemplate.Triggers>
              <Trigger Property="IsMouseOver" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.86"/>
              </Trigger>
              <Trigger Property="IsPressed" Value="True">
                <Setter TargetName="bd" Property="Opacity" Value="0.72"/>
              </Trigger>
              <Trigger Property="IsEnabled" Value="False">
                <Setter TargetName="bd" Property="Opacity" Value="0.35"/>
              </Trigger>
            </ControlTemplate.Triggers>
          </ControlTemplate>
        </Setter.Value>
      </Setter>
    </Style>
  </Window.Resources>

  <Grid Margin="26,16,26,14">
    <Grid.RowDefinitions>
      <RowDefinition Height="*"/>
      <RowDefinition Height="Auto"/>
    </Grid.RowDefinitions>

    <StackPanel Grid.Row="0">
      <TextBlock Text="*supported windows 8-11*" Foreground="{StaticResource InfoBrush}"
                 FontSize="11" HorizontalAlignment="Center" Opacity="0.9"/>

      <Image x:Name="imgLogo" Width="92" Height="92" Stretch="Uniform"
             Margin="0,14,0,0" HorizontalAlignment="Center"
             RenderOptions.BitmapScalingMode="HighQuality"/>

      <TextBlock Text="Windows Update Manager" Foreground="#CDD6F4" FontSize="18"
                 FontWeight="SemiBold" HorizontalAlignment="Center" Margin="0,10,0,0"/>

      <TextBlock x:Name="lblStatus" Text="Checking state..." Foreground="{StaticResource MutedBrush}"
                 FontSize="12" HorizontalAlignment="Center" Margin="0,6,0,0"/>

      <Grid Margin="0,16,0,0">
        <Grid.ColumnDefinitions>
          <ColumnDefinition Width="*"/>
          <ColumnDefinition Width="14"/>
          <ColumnDefinition Width="*"/>
        </Grid.ColumnDefinitions>
        <Button x:Name="btnEnable" Grid.Column="0" Content="Enable" Height="54"
                Background="#2F9E44" Style="{StaticResource ActionButton}"/>
        <Button x:Name="btnDisable" Grid.Column="2" Content="Disable" Height="54"
                Background="#E03131" Style="{StaticResource ActionButton}"/>
      </Grid>

      <TextBlock Text="Enable restores Windows Update and its Settings page. Disable hides it; Microsoft Store keeps working."
                 Foreground="#585B70" FontSize="10.5" HorizontalAlignment="Center"
                 TextAlignment="Center" TextWrapping="Wrap" Margin="0,10,0,0"/>
    </StackPanel>

    <Grid Grid.Row="1" Margin="0,12,0,0">
      <TextBlock Text="made by dragonbot" Foreground="#585B70" FontSize="11"
                 HorizontalAlignment="Left" VerticalAlignment="Bottom"/>
      <TextBlock x:Name="lblVersion" Text="v1.0.1" Foreground="#45475A" FontSize="10"
                 HorizontalAlignment="Right" VerticalAlignment="Bottom"/>
    </Grid>
  </Grid>
</Window>
'@

$reader = New-Object System.Xml.XmlNodeReader $xaml
$window = [Windows.Markup.XamlReader]::Load($reader)
$script:window = $window

$script:btnEnable  = $window.FindName('btnEnable')
$script:btnDisable = $window.FindName('btnDisable')
$script:lblStatus  = $window.FindName('lblStatus')
$script:imgLogo    = $window.FindName('imgLogo')
$script:lblVersion = $window.FindName('lblVersion')

# Keep the footer in sync with the build version.
$script:lblVersion.Text = "v$appVersion"

# Logo: embedded base64 in the compiled build, or logo.png next to the script.
try {
    $logoBytes = $null
    if ($logoBase64 -and $logoBase64 -notlike '__*') {
        $logoBytes = [Convert]::FromBase64String($logoBase64)
    } elseif ($scriptDir) {
        # Script mode: look next to the script, then in the repo's assets folder.
        foreach ($candidate in @(
            (Join-Path $scriptDir 'logo.png'),
            (Join-Path (Split-Path -Parent $scriptDir) 'assets\logo.png')
        )) {
            if (Test-Path $candidate) { $logoBytes = [IO.File]::ReadAllBytes($candidate); break }
        }
    }
    if ($logoBytes) {
        $ms = New-Object System.IO.MemoryStream(,$logoBytes)
        $bi = New-Object System.Windows.Media.Imaging.BitmapImage
        $bi.BeginInit()
        $bi.CacheOption = [System.Windows.Media.Imaging.BitmapCacheOption]::OnLoad
        $bi.StreamSource = $ms
        $bi.EndInit()
        $bi.Freeze()
        $script:imgLogo.Source = $bi
    }
} catch { }

# Dark title bar to match the dark content (Win10 1809+ / Win11)
$window.Add_SourceInitialized({
    try {
        $helper = New-Object System.Windows.Interop.WindowInteropHelper($script:window)
        $hwnd = $helper.Handle
        $dark = 1
        try { [void][DwmApi]::DwmSetWindowAttribute($hwnd, 20, [ref]$dark, 4) } catch { }
        try { [void][DwmApi]::DwmSetWindowAttribute($hwnd, 19, [ref]$dark, 4) } catch { }
    } catch { }
})

function Set-Status {
    param([string]$Text, [string]$Kind)
    $script:lblStatus.Text = $Text
    switch ($Kind) {
        'ok'   { $script:lblStatus.Foreground = $script:window.FindResource('OkBrush') }
        'err'  { $script:lblStatus.Foreground = $script:window.FindResource('ErrBrush') }
        default { $script:lblStatus.Foreground = $script:window.FindResource('MutedBrush') }
    }
}

function Update-StateLabel {
    try {
        $st = Get-WuState
        if ($st.State -eq 'Disabled') {
            Set-Status 'Currently: Disabled (paused, page hidden)' 'err'
        } else {
            Set-Status 'Currently: Enabled' 'ok'
        }
    } catch {
        Set-Status 'Ready' 'default'
    }
}

# ---------------------------------------------------------------------------
# Fast button actions
# ---------------------------------------------------------------------------
$script:btnEnable.Add_Click({
    try {
        $script:window.Cursor = [System.Windows.Input.Cursors]::Wait
        [void](Enable-WuFast -BaseDir $base)
        Update-StateLabel
        Set-Status 'Windows Update enabled.' 'ok'
    } catch {
        Set-Status "Failed: $($_.Exception.Message)" 'err'
    } finally {
        $script:window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
})

$script:btnDisable.Add_Click({
    $answer = [System.Windows.MessageBox]::Show(
        "Disable Windows Update?`n`nUpdates will be paused and blocked by policy, and the Windows Update page will be hidden from Settings. Windows Update services are left running so Microsoft Store keeps working.`n`nThis is reversible, but the PC will not receive security updates until you enable it again.",
        'Confirm', 'YesNo', 'Warning'
    )
    if ($answer -ne 'Yes') { return }
    try {
        $script:window.Cursor = [System.Windows.Input.Cursors]::Wait
        [void](Disable-WuFast -BaseDir $base)
        Update-StateLabel
        Set-Status 'Windows Update disabled (updates paused).' 'ok'
    } catch {
        Set-Status "Failed: $($_.Exception.Message)" 'err'
    } finally {
        $script:window.Cursor = [System.Windows.Input.Cursors]::Arrow
    }
})

Update-StateLabel
[void]$window.ShowDialog()
