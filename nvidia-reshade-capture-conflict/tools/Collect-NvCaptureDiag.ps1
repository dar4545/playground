<#
.SYNOPSIS
    Collects diagnostic data for troubleshooting NVIDIA App / NvFBC in-game overlay
    capture conflicts with ReShade on multi-monitor (portrait + landscape) setups.

.DESCRIPTION
    Read-only diagnostic collector. Makes NO changes to the system. Everything is
    wrapped in per-section try/catch so a single failure never aborts the run.
    Writes a full PowerShell transcript plus individual report files to -OutDir.

.PARAMETER GameDir
    Path to the game folder containing the game .exe and the ReShade proxy DLL(s).
    Mandatory.

.PARAMETER OutDir
    Output directory for the diagnostic bundle. Defaults to
    .\nvcapture-diag-<yyyyMMdd-HHmmss> in the current directory.

.PARAMETER GameExe
    Optional. Name of the game executable (with or without .exe) to inspect for
    loaded modules if the process is currently running.

.EXAMPLE
    .\Collect-NvCaptureDiag.ps1 -GameDir "D:\Games\MyGame" -GameExe "MyGame.exe"

.EXAMPLE
    .\Collect-NvCaptureDiag.ps1 -GameDir "D:\Games\MyGame" -OutDir "C:\diag\run1"

.NOTES
    PowerShell 5.1 and 7.x compatible. Does not require elevation, but detects and
    reports whether the current session is elevated.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$GameDir,

    [Parameter(Mandatory = $false)]
    [string]$OutDir = (Join-Path -Path (Get-Location) -ChildPath ("nvcapture-diag-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))),

    [Parameter(Mandatory = $false)]
    [string]$GameExe
)

# ----------------------------------------------------------------------------
# Setup
# ----------------------------------------------------------------------------

$ErrorActionPreference = 'Continue'

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "==== $Title ====" -ForegroundColor Cyan
}

function Write-Ok   { param([string]$Msg) Write-Host "[OK]   $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red }

try {
    if (-not (Test-Path -LiteralPath $OutDir)) {
        New-Item -ItemType Directory -Path $OutDir -Force | Out-Null
    }
    $OutDir = (Resolve-Path -LiteralPath $OutDir).ProviderPath
} catch {
    Write-Error "Could not create/resolve OutDir '$OutDir': $($_.Exception.Message)"
    return
}

$LogsDir = Join-Path $OutDir 'logs'
try {
    if (-not (Test-Path -LiteralPath $LogsDir)) {
        New-Item -ItemType Directory -Path $LogsDir -Force | Out-Null
    }
} catch {
    Write-Warn "Could not create logs subfolder: $($_.Exception.Message)"
}

$TranscriptPath = Join-Path $OutDir 'transcript.txt'
$TranscriptStarted = $false
try {
    Start-Transcript -Path $TranscriptPath -Force | Out-Null
    $TranscriptStarted = $true
} catch {
    Write-Warn "Start-Transcript failed: $($_.Exception.Message). Continuing without transcript."
}

Write-Host "Collect-NvCaptureDiag.ps1 starting at $(Get-Date -Format 'u')"
Write-Host "GameDir: $GameDir"
Write-Host "OutDir : $OutDir"

# Elevation check (never fatal)
$IsElevated = $false
try {
    $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
    $IsElevated = $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {
    Write-Warn "Could not determine elevation state: $($_.Exception.Message)"
}
if ($IsElevated) {
    Write-Ok "Running elevated (Administrator)."
} else {
    Write-Warn "Not running elevated. Some module/log collection (esp. section f) may be limited."
}

# Summary state, populated as sections run
$Summary = [ordered]@{
    PrimaryDisplay        = $null
    DisplayOrientations   = @()
    ReShadeFound          = $false
    ReShadeModuleName     = $null
    DwmEnabledFound       = $false
    DwmEnabledValue       = $null
    DwmEnabledUserFound   = $false
    DwmEnabledUserValue   = $null
    CaptureCoreLogFound   = $false
}

# ----------------------------------------------------------------------------
# a) system.txt
# ----------------------------------------------------------------------------
Write-Section "a) System / driver / NVIDIA App info"
try {
    $sysLines = New-Object System.Collections.Generic.List[string]
    $sysLines.Add("=== OS Version ===")

    try {
        $ci = Get-ComputerInfo -Property OsVersion, OsBuildNumber, OsName -ErrorAction Stop
        $sysLines.Add("OsName        : $($ci.OsName)")
        $sysLines.Add("OsVersion     : $($ci.OsVersion)")
        $sysLines.Add("OsBuildNumber : $($ci.OsBuildNumber)")
    } catch {
        $sysLines.Add("Get-ComputerInfo failed: $($_.Exception.Message)")
        try {
            $curVer = Get-ItemProperty -Path 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction Stop
            $sysLines.Add("CurrentBuild  : $($curVer.CurrentBuild)")
            $sysLines.Add("UBR           : $($curVer.UBR)")
            $sysLines.Add("ProductName   : $($curVer.ProductName)")
            $sysLines.Add("DisplayVersion: $($curVer.DisplayVersion)")
        } catch {
            $sysLines.Add("Registry OS version fallback also failed: $($_.Exception.Message)")
        }
    }

    $sysLines.Add("")
    $sysLines.Add("=== NVIDIA Video Controller(s) (Win32_VideoController) ===")
    try {
        $vcs = Get-CimInstance -ClassName Win32_VideoController -ErrorAction Stop
        foreach ($vc in $vcs) {
            $sysLines.Add("Name                          : $($vc.Name)")
            $sysLines.Add("DriverVersion                 : $($vc.DriverVersion)")
            $sysLines.Add("VideoModeDescription          : $($vc.VideoModeDescription)")
            $sysLines.Add("CurrentHorizontalResolution   : $($vc.CurrentHorizontalResolution)")
            $sysLines.Add("CurrentVerticalResolution     : $($vc.CurrentVerticalResolution)")
            $sysLines.Add("---")
        }
    } catch {
        $sysLines.Add("Get-CimInstance Win32_VideoController failed: $($_.Exception.Message)")
    }

    $sysLines.Add("")
    $sysLines.Add("=== NVIDIA App / GeForce Experience (Uninstall registry) ===")
    try {
        $uninstallPaths = @(
            'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*',
            'HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*'
        )
        $found = $false
        foreach ($p in $uninstallPaths) {
            try {
                $entries = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like '*NVIDIA*' }
                foreach ($e in $entries) {
                    $found = $true
                    $sysLines.Add("DisplayName    : $($e.DisplayName)")
                    $sysLines.Add("DisplayVersion : $($e.DisplayVersion)")
                    $sysLines.Add("Publisher      : $($e.Publisher)")
                    $sysLines.Add("InstallLocation: $($e.InstallLocation)")
                    $sysLines.Add("RegistryPath   : $p")
                    $sysLines.Add("---")
                }
            } catch {
                $sysLines.Add("Query failed for $p : $($_.Exception.Message)")
            }
        }
        if (-not $found) {
            $sysLines.Add("No NVIDIA* entries found under scanned Uninstall keys.")
        }
    } catch {
        $sysLines.Add("Uninstall registry scan failed: $($_.Exception.Message)")
    }

    $sysLines.Add("")
    $sysLines.Add("=== Running NVIDIA processes ===")
    try {
        $nvProcNames = @('nvcontainer', 'nvsphelper64', 'NVIDIA app', 'NVIDIA App', 'NVDisplay.Container', 'nvcplui', 'nvtray')
        $anyProc = $false
        foreach ($pn in $nvProcNames) {
            $procs = Get-Process -Name $pn -ErrorAction SilentlyContinue
            foreach ($p in $procs) {
                $anyProc = $true
                $sysLines.Add("Name: $($p.Name)  Id: $($p.Id)  Path: $($p.Path)")
            }
        }
        # Also catch-all pattern match on nvidia/nvcontainer/nvdisplay
        try {
            $allProcs = Get-Process -ErrorAction SilentlyContinue | Where-Object {
                $_.Name -match '(?i)nvidia|nvcontainer|nvdisplay|nvsphelper'
            }
            foreach ($p in $allProcs) {
                $line = "Name: $($p.Name)  Id: $($p.Id)"
                if (-not ($sysLines -contains $line -or ($sysLines | Where-Object { $_ -like "Name: $($p.Name)*" }))) {
                    $anyProc = $true
                    $sysLines.Add("Name: $($p.Name)  Id: $($p.Id)  Path: $($p.Path)")
                }
            }
        } catch {
            $sysLines.Add("Broad NVIDIA process scan failed: $($_.Exception.Message)")
        }
        if (-not $anyProc) {
            $sysLines.Add("No NVIDIA-related processes currently running.")
        }
    } catch {
        $sysLines.Add("Process enumeration failed: $($_.Exception.Message)")
    }

    $sysLines | Out-File -FilePath (Join-Path $OutDir 'system.txt') -Encoding UTF8
    Write-Ok "system.txt written."
} catch {
    Write-Fail "Section (a) system.txt failed entirely: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# b) displays.txt - P/Invoke display topology
# ----------------------------------------------------------------------------
Write-Section "b) Display topology"
try {
    $displayTypeDef = @"
using System;
using System.Runtime.InteropServices;
using System.Text;

public class NvDiagDisplayNative
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DISPLAY_DEVICE
    {
        [MarshalAs(UnmanagedType.U4)]
        public int cb;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string DeviceName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceString;
        [MarshalAs(UnmanagedType.U4)]
        public int StateFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceID;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 128)]
        public string DeviceKey;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct POINTL
    {
        public int x;
        public int y;
    }

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct DEVMODE
    {
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmDeviceName;
        public short dmSpecVersion;
        public short dmDriverVersion;
        public short dmSize;
        public short dmDriverExtra;
        public int dmFields;

        public int dmPositionX;
        public int dmPositionY;
        public int dmDisplayOrientation;
        public int dmDisplayFixedOutput;

        public short dmColor;
        public short dmDuplex;
        public short dmYResolution;
        public short dmTTOption;
        public short dmCollate;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string dmFormName;
        public short dmLogPixels;
        public int dmBitsPerPel;
        public int dmPelsWidth;
        public int dmPelsHeight;
        public int dmDisplayFlags;
        public int dmDisplayFrequency;
        public int dmICMMethod;
        public int dmICMIntent;
        public int dmMediaType;
        public int dmDitherType;
        public int dmReserved1;
        public int dmReserved2;
        public int dmPanningWidth;
        public int dmPanningHeight;
    }

    public const int ENUM_CURRENT_SETTINGS = -1;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettingsEx(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode, uint dwFlags);

    [StructLayout(LayoutKind.Sequential)]
    public struct RECT
    {
        public int Left;
        public int Top;
        public int Right;
        public int Bottom;
    }

    [StructLayout(LayoutKind.Sequential)]
    public struct MONITORINFOEX
    {
        public int cbSize;
        public RECT rcMonitor;
        public RECT rcWork;
        public uint dwFlags;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 32)]
        public string szDevice;
    }

    public delegate bool MonitorEnumDelegate(IntPtr hMonitor, IntPtr hdcMonitor, ref RECT lprcMonitor, IntPtr dwData);

    [DllImport("user32.dll")]
    public static extern bool EnumDisplayMonitors(IntPtr hdc, IntPtr lprcClip, MonitorEnumDelegate lpfnEnum, IntPtr dwData);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool GetMonitorInfo(IntPtr hMonitor, ref MONITORINFOEX lpmi);
}
"@

    try {
        Add-Type -TypeDefinition $displayTypeDef -ErrorAction Stop
    } catch {
        Write-Warn "Add-Type for display P/Invoke failed (type may already be loaded): $($_.Exception.Message)"
    }

    $dispLines = New-Object System.Collections.Generic.List[string]

    # EnumDisplayDevices + EnumDisplaySettingsEx
    $dispLines.Add("=== EnumDisplayDevices / EnumDisplaySettingsEx ===")
    try {
        $devIndex = 0
        $orientationMap = @{ 0 = 'Landscape (0)'; 1 = 'Rotated 90 (1)'; 2 = 'Rotated 180 (2)'; 3 = 'Rotated 270 (3)' }
        while ($true) {
            $dd = New-Object NvDiagDisplayNative+DISPLAY_DEVICE
            $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dd)
            $ok = [NvDiagDisplayNative]::EnumDisplayDevices($null, $devIndex, [ref]$dd, 0)
            if (-not $ok) { break }

            $isPrimary  = (($dd.StateFlags -band 0x4) -ne 0)   # DISPLAY_DEVICE_PRIMARY_DEVICE
            $isAttached = (($dd.StateFlags -band 0x1) -ne 0)   # DISPLAY_DEVICE_ATTACHED_TO_DESKTOP

            $dispLines.Add("--- Device #$devIndex ---")
            $dispLines.Add("DeviceName   : $($dd.DeviceName)")
            $dispLines.Add("DeviceString : $($dd.DeviceString)")
            $dispLines.Add("StateFlags   : 0x$('{0:X}' -f $dd.StateFlags) (Primary=$isPrimary, Attached=$isAttached)")
            $dispLines.Add("DeviceID     : $($dd.DeviceID)")

            if ($isAttached) {
                if ($isPrimary) { $Summary.PrimaryDisplay = $dd.DeviceName }

                $dm = New-Object NvDiagDisplayNative+DEVMODE
                $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
                try {
                    $okSettings = [NvDiagDisplayNative]::EnumDisplaySettingsEx($dd.DeviceName, [NvDiagDisplayNative]::ENUM_CURRENT_SETTINGS, [ref]$dm, 0)
                    if ($okSettings) {
                        $orientText = if ($orientationMap.ContainsKey($dm.dmDisplayOrientation)) { $orientationMap[$dm.dmDisplayOrientation] } else { "Unknown ($($dm.dmDisplayOrientation))" }
                        $dispLines.Add("Position     : x=$($dm.dmPositionX), y=$($dm.dmPositionY)")
                        $dispLines.Add("Resolution   : $($dm.dmPelsWidth) x $($dm.dmPelsHeight)")
                        $dispLines.Add("Orientation  : $orientText")
                        $dispLines.Add("FixedOutput  : $($dm.dmDisplayFixedOutput)")
                        $dispLines.Add("RefreshRate  : $($dm.dmDisplayFrequency) Hz")
                        $dispLines.Add("BitsPerPel   : $($dm.dmBitsPerPel)")
                        $Summary.DisplayOrientations += "$($dd.DeviceName): $orientText, $($dm.dmPelsWidth)x$($dm.dmPelsHeight)$(if ($isPrimary) { ' [PRIMARY]' })"
                    } else {
                        $dispLines.Add("EnumDisplaySettingsEx returned false for this device.")
                    }
                } catch {
                    $dispLines.Add("EnumDisplaySettingsEx failed: $($_.Exception.Message)")
                }
            } else {
                $dispLines.Add("(Not attached to desktop - skipping settings query)")
            }

            $devIndex++
            if ($devIndex -gt 32) { break } # safety cap
        }
    } catch {
        $dispLines.Add("EnumDisplayDevices loop failed: $($_.Exception.Message)")
    }

    # System.Windows.Forms.Screen.AllScreens
    $dispLines.Add("")
    $dispLines.Add("=== System.Windows.Forms.Screen.AllScreens ===")
    try {
        Add-Type -AssemblyName System.Windows.Forms -ErrorAction Stop
        foreach ($scr in [System.Windows.Forms.Screen]::AllScreens) {
            $dispLines.Add("DeviceName: $($scr.DeviceName)  Bounds: $($scr.Bounds)  Primary: $($scr.Primary)  WorkingArea: $($scr.WorkingArea)")
        }
    } catch {
        $dispLines.Add("Screen.AllScreens failed: $($_.Exception.Message)")
    }

    # EnumDisplayMonitors / GetMonitorInfo
    $dispLines.Add("")
    $dispLines.Add("=== EnumDisplayMonitors / GetMonitorInfo (HMONITOR list) ===")
    try {
        $monList = New-Object System.Collections.Generic.List[string]
        $callback = {
            param($hMonitor, $hdcMonitor, [ref]$lprcMonitor, $dwData)
            try {
                $mi = New-Object NvDiagDisplayNative+MONITORINFOEX
                $mi.cbSize = [System.Runtime.InteropServices.Marshal]::SizeOf($mi)
                $ok = [NvDiagDisplayNative]::GetMonitorInfo($hMonitor, [ref]$mi)
                if ($ok) {
                    $isPrimaryMon = (($mi.dwFlags -band 0x1) -ne 0) # MONITORINFOF_PRIMARY
                    $monList.Add("HMONITOR=$hMonitor  Device=$($mi.szDevice)  rcMonitor=($($mi.rcMonitor.Left),$($mi.rcMonitor.Top))-($($mi.rcMonitor.Right),$($mi.rcMonitor.Bottom))  Primary=$isPrimaryMon")
                } else {
                    $monList.Add("HMONITOR=$hMonitor  GetMonitorInfo failed")
                }
            } catch {
                $monList.Add("HMONITOR=$hMonitor  callback error: $($_.Exception.Message)")
            }
            return $true
        }
        $delegate = [NvDiagDisplayNative+MonitorEnumDelegate]$callback
        [NvDiagDisplayNative]::EnumDisplayMonitors([IntPtr]::Zero, [IntPtr]::Zero, $delegate, [IntPtr]::Zero) | Out-Null
        foreach ($l in $monList) { $dispLines.Add($l) }
        if ($monList.Count -eq 0) { $dispLines.Add("No monitors enumerated or callback produced no output.") }
    } catch {
        $dispLines.Add("EnumDisplayMonitors failed: $($_.Exception.Message)")
    }

    # WMI monitor identification
    $dispLines.Add("")
    $dispLines.Add("=== root\wmi WmiMonitorID / WmiMonitorBasicDisplayParams ===")
    try {
        $monIds = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorID -ErrorAction Stop
        foreach ($m in $monIds) {
            try {
                $mfg = ($m.ManufacturerName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ''
                $name = ($m.UserFriendlyName | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ''
                $serial = ($m.SerialNumberID | Where-Object { $_ -ne 0 } | ForEach-Object { [char]$_ }) -join ''
                $dispLines.Add("InstanceName: $($m.InstanceName)  Manufacturer: $mfg  FriendlyName: $name  Serial: $serial")
            } catch {
                $dispLines.Add("WmiMonitorID decode failed for one entry: $($_.Exception.Message)")
            }
        }
    } catch {
        $dispLines.Add("WmiMonitorID query failed (may require elevation or WMI provider unavailable): $($_.Exception.Message)")
    }

    try {
        $bdp = Get-CimInstance -Namespace root\wmi -ClassName WmiMonitorBasicDisplayParams -ErrorAction Stop
        foreach ($b in $bdp) {
            $dispLines.Add("InstanceName: $($b.InstanceName)  MaxHorizontalImageSize: $($b.MaxHorizontalImageSize)  MaxVerticalImageSize: $($b.MaxVerticalImageSize)")
        }
    } catch {
        $dispLines.Add("WmiMonitorBasicDisplayParams query failed: $($_.Exception.Message)")
    }

    $dispLines | Out-File -FilePath (Join-Path $OutDir 'displays.txt') -Encoding UTF8
    Write-Ok "displays.txt written."
} catch {
    Write-Fail "Section (b) displays.txt failed entirely: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# c) nvidia-registry.txt
# ----------------------------------------------------------------------------
Write-Section "c) NVIDIA registry (ShadowPlay / NvContainer)"
try {
    $regLines = New-Object System.Collections.Generic.List[string]

    function Format-BinaryValue {
        param([byte[]]$Bytes)
        if ($null -eq $Bytes) { return "<null>" }
        $hex = ($Bytes | ForEach-Object { $_.ToString('X2') }) -join ' '
        $result = "hex=[$hex]"
        if ($Bytes.Length -eq 4) {
            try {
                $uint32 = [BitConverter]::ToUInt32($Bytes, 0)
                $result += "  uint32(LE)=$uint32"
            } catch {
                $result += "  uint32(LE)=<decode error>"
            }
        }
        return $result
    }

    $regLines.Add("=== HKCU:\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS ===")
    try {
        $nvspcapsPath = 'HKCU:\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS'
        if (Test-Path -LiteralPath $nvspcapsPath) {
            $key = Get-Item -LiteralPath $nvspcapsPath -ErrorAction Stop
            foreach ($valName in $key.GetValueNames()) {
                $val = $key.GetValue($valName, $null, 'DoNotExpandEnvironmentNames')
                $kind = $key.GetValueKind($valName)
                if ($kind -eq 'Binary') {
                    $regLines.Add("$valName ($kind): $(Format-BinaryValue -Bytes $val)")
                    if ($valName -eq 'DwmEnabled') {
                        $Summary.DwmEnabledFound = $true
                        $Summary.DwmEnabledValue = Format-BinaryValue -Bytes $val
                    }
                    if ($valName -eq 'DwmEnabledUser') {
                        $Summary.DwmEnabledUserFound = $true
                        $Summary.DwmEnabledUserValue = Format-BinaryValue -Bytes $val
                    }
                } else {
                    $regLines.Add("$valName ($kind): $val")
                }
            }
            if ($key.GetValueNames().Count -eq 0) {
                $regLines.Add("(key exists but has no values)")
            }
        } else {
            $regLines.Add("Key not found: $nvspcapsPath")
        }
    } catch {
        $regLines.Add("Error reading NVSPCAPS: $($_.Exception.Message)")
    }

    $regLines.Add("")
    $regLines.Add("=== HKCU:\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay (recursive) ===")
    try {
        $shadowPlayPath = 'HKCU:\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay'
        if (Test-Path -LiteralPath $shadowPlayPath) {
            function Dump-RegKeyRecursive {
                param([string]$Path, [System.Collections.Generic.List[string]]$Lines, [int]$Depth = 0)
                try {
                    $indent = '  ' * $Depth
                    $item = Get-Item -LiteralPath $Path -ErrorAction Stop
                    $Lines.Add("$indent[$Path]")
                    foreach ($valName in $item.GetValueNames()) {
                        try {
                            $kind = $item.GetValueKind($valName)
                            $val = $item.GetValue($valName, $null, 'DoNotExpandEnvironmentNames')
                            if ($kind -eq 'Binary') {
                                $Lines.Add("$indent  $valName ($kind): $(Format-BinaryValue -Bytes $val)")
                            } else {
                                $Lines.Add("$indent  $valName ($kind): $val")
                            }
                        } catch {
                            $Lines.Add("$indent  $valName : <error reading value: $($_.Exception.Message)>")
                        }
                    }
                    $subKeys = Get-ChildItem -LiteralPath $Path -ErrorAction SilentlyContinue
                    foreach ($sk in $subKeys) {
                        Dump-RegKeyRecursive -Path $sk.PSPath -Lines $Lines -Depth ($Depth + 1)
                    }
                } catch {
                    $Lines.Add("Error reading key '$Path': $($_.Exception.Message)")
                }
            }
            Dump-RegKeyRecursive -Path $shadowPlayPath -Lines $regLines
        } else {
            $regLines.Add("Key not found: $shadowPlayPath")
        }
    } catch {
        $regLines.Add("Error walking ShadowPlay key: $($_.Exception.Message)")
    }

    $regLines.Add("")
    $regLines.Add("=== HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvContainer ===")
    try {
        $nvContainerPath = 'HKLM:\SOFTWARE\NVIDIA Corporation\Global\NvContainer'
        if (Test-Path -LiteralPath $nvContainerPath) {
            $key = Get-Item -LiteralPath $nvContainerPath -ErrorAction Stop
            foreach ($valName in $key.GetValueNames()) {
                $val = $key.GetValue($valName)
                $kind = $key.GetValueKind($valName)
                $regLines.Add("$valName ($kind): $val")
            }
        } else {
            $regLines.Add("Key not present (not found, this is not necessarily an error): $nvContainerPath")
        }
    } catch {
        $regLines.Add("Error reading NvContainer key: $($_.Exception.Message)")
    }

    $regLines | Out-File -FilePath (Join-Path $OutDir 'nvidia-registry.txt') -Encoding UTF8
    Write-Ok "nvidia-registry.txt written."
} catch {
    Write-Fail "Section (c) nvidia-registry.txt failed entirely: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# d) logs\ - copy NVIDIA + ReShade logs
# ----------------------------------------------------------------------------
Write-Section "d) Log collection"
$ManifestEntries = New-Object System.Collections.Generic.List[string]
try {
    function Copy-IfExists {
        param(
            [string]$SourcePath,
            [string]$DestDir,
            [System.Collections.Generic.List[string]]$Manifest
        )
        try {
            if (Test-Path -LiteralPath $SourcePath -PathType Leaf) {
                $destName = Split-Path -Leaf $SourcePath
                $destPath = Join-Path $DestDir $destName
                # avoid collisions by prefixing with a hash of source dir if needed
                if (Test-Path -LiteralPath $destPath) {
                    $prefix = [Math]::Abs($SourcePath.GetHashCode()).ToString('x8')
                    $destPath = Join-Path $DestDir ("$prefix`_$destName")
                }
                Copy-Item -LiteralPath $SourcePath -Destination $destPath -Force -ErrorAction Stop
                $Manifest.Add("$SourcePath  ->  $destPath")
                return $true
            }
        } catch {
            $Manifest.Add("$SourcePath  ->  COPY FAILED: $($_.Exception.Message)")
        }
        return $false
    }

    # ShadowPlay logs
    try {
        $spDir = 'C:\ProgramData\NVIDIA Corporation\ShadowPlay'
        Copy-IfExists -SourcePath (Join-Path $spDir 'CaptureCore.log') -DestDir $LogsDir -Manifest $ManifestEntries | Out-Null
        if (Test-Path -LiteralPath $spDir) {
            $spFiles = Get-ChildItem -LiteralPath $spDir -Include '*.log', '*.txt' -Recurse -File -ErrorAction SilentlyContinue
            foreach ($f in $spFiles) {
                Copy-IfExists -SourcePath $f.FullName -DestDir $LogsDir -Manifest $ManifestEntries | Out-Null
            }
        } else {
            $ManifestEntries.Add("$spDir : not found")
        }
    } catch {
        $ManifestEntries.Add("ShadowPlay log collection error: $($_.Exception.Message)")
    }

    # NVIDIA App (LOCALAPPDATA), recursive max depth 3, filtered by ext + size
    try {
        $localAppData = $env:LOCALAPPDATA
        if ([string]::IsNullOrEmpty($localAppData)) {
            $ManifestEntries.Add("LOCALAPPDATA env var not set - skipping NVIDIA App log scan.")
        } else {
            $nvAppDir = Join-Path $localAppData 'NVIDIA Corporation\NVIDIA App'
            if (Test-Path -LiteralPath $nvAppDir) {
                $maxSizeBytes = 20MB
                $baseDepth = ($nvAppDir -split '[\\/]').Count
                $allFiles = Get-ChildItem -LiteralPath $nvAppDir -Recurse -File -ErrorAction SilentlyContinue
                foreach ($f in $allFiles) {
                    try {
                        $depth = (($f.FullName -split '[\\/]').Count) - $baseDepth
                        if ($depth -gt 3) { continue }
                        if ($f.Extension -notin @('.log', '.txt', '.json')) { continue }
                        if ($f.Length -ge $maxSizeBytes) {
                            $ManifestEntries.Add("$($f.FullName) : SKIPPED (>= 20MB, size=$($f.Length))")
                            continue
                        }
                        Copy-IfExists -SourcePath $f.FullName -DestDir $LogsDir -Manifest $ManifestEntries | Out-Null
                    } catch {
                        $ManifestEntries.Add("$($f.FullName) : error during filter/copy: $($_.Exception.Message)")
                    }
                }
            } else {
                $ManifestEntries.Add("$nvAppDir : not found")
            }

            # GeForce Experience
            $gfeDir = Join-Path $localAppData 'NVIDIA Corporation\NVIDIA GeForce Experience'
            if (Test-Path -LiteralPath $gfeDir) {
                $gfeFiles = Get-ChildItem -LiteralPath $gfeDir -Filter '*.log' -File -ErrorAction SilentlyContinue
                foreach ($f in $gfeFiles) {
                    Copy-IfExists -SourcePath $f.FullName -DestDir $LogsDir -Manifest $ManifestEntries | Out-Null
                }
            } else {
                $ManifestEntries.Add("$gfeDir : not found")
            }

            # NvBackend
            $nvBackendDir = Join-Path $localAppData 'NVIDIA\NvBackend'
            if (Test-Path -LiteralPath $nvBackendDir) {
                $nbFiles = Get-ChildItem -LiteralPath $nvBackendDir -Filter '*.log' -File -ErrorAction SilentlyContinue
                foreach ($f in $nbFiles) {
                    Copy-IfExists -SourcePath $f.FullName -DestDir $LogsDir -Manifest $ManifestEntries | Out-Null
                }
            } else {
                $ManifestEntries.Add("$nvBackendDir : not found")
            }

            # NvNode
            $nvNodeDir = Join-Path $localAppData 'NVIDIA Corporation\NvNode'
            if (Test-Path -LiteralPath $nvNodeDir) {
                $nnFiles = Get-ChildItem -LiteralPath $nvNodeDir -Filter '*.log' -File -ErrorAction SilentlyContinue
                foreach ($f in $nnFiles) {
                    Copy-IfExists -SourcePath $f.FullName -DestDir $LogsDir -Manifest $ManifestEntries | Out-Null
                }
            } else {
                $ManifestEntries.Add("$nvNodeDir : not found")
            }
        }
    } catch {
        $ManifestEntries.Add("NVIDIA App/GFE/NvBackend/NvNode log collection error: $($_.Exception.Message)")
    }

    # Game dir logs/inis
    try {
        if (Test-Path -LiteralPath $GameDir) {
            $gameFilesToCopy = @('ReShade.log', 'dxgi.log', 'd3d11.log', 'd3d12.log', 'ReShade.ini', 'dxgi.ini', 'd3d11.ini', 'd3d12.ini')
            foreach ($fname in $gameFilesToCopy) {
                $full = Join-Path $GameDir $fname
                Copy-IfExists -SourcePath $full -DestDir $LogsDir -Manifest $ManifestEntries | Out-Null
            }
        } else {
            $ManifestEntries.Add("GameDir not found: $GameDir")
            Write-Warn "GameDir '$GameDir' does not exist."
        }
    } catch {
        $ManifestEntries.Add("GameDir log collection error: $($_.Exception.Message)")
    }

    $ManifestEntries | Out-File -FilePath (Join-Path $LogsDir 'manifest.txt') -Encoding UTF8
    Write-Ok "Log collection complete. See logs\manifest.txt for source->dest mapping."

    if (Test-Path -LiteralPath (Join-Path $LogsDir 'CaptureCore.log')) {
        $Summary.CaptureCoreLogFound = $true
    } else {
        # could have been renamed on collision; check manifest text
        $ccMatches = $ManifestEntries | Where-Object { $_ -match 'CaptureCore\.log\s+->' -and $_ -notmatch 'FAILED' }
        if ($ccMatches) { $Summary.CaptureCoreLogFound = $true }
    }
} catch {
    Write-Fail "Section (d) log collection failed entirely: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# e) reshade.txt
# ----------------------------------------------------------------------------
Write-Section "e) ReShade / DLL inventory in GameDir"
try {
    $reshadeLines = New-Object System.Collections.Generic.List[string]
    $reshadeHeuristicNames = @('dxgi.dll', 'd3d11.dll', 'd3d12.dll', 'opengl32.dll', 'reshade64.dll', 'reshade32.dll')

    if (Test-Path -LiteralPath $GameDir) {
        $reshadeLines.Add("=== DLLs in $GameDir ===")
        try {
            $dlls = Get-ChildItem -LiteralPath $GameDir -Filter '*.dll' -File -ErrorAction Stop
            foreach ($dll in $dlls) {
                try {
                    $fvi = $dll.VersionInfo
                    $isReshadeByFvi = ($fvi.ProductName -and $fvi.ProductName -match '(?i)reshade')
                    $isReshadeByName = ($reshadeHeuristicNames -contains $dll.Name.ToLower())
                    $flagged = $isReshadeByFvi -or $isReshadeByName

                    $reshadeLines.Add("--- $($dll.Name) ---")
                    $reshadeLines.Add("Size          : $($dll.Length) bytes")
                    $reshadeLines.Add("LastWriteTime : $($dll.LastWriteTime)")
                    $reshadeLines.Add("ProductName   : $($fvi.ProductName)")
                    $reshadeLines.Add("FileVersion   : $($fvi.FileVersion)")
                    $reshadeLines.Add("ProductVersion: $($fvi.ProductVersion)")
                    $reshadeLines.Add("CompanyName   : $($fvi.CompanyName)")
                    $reshadeLines.Add("ReShade?      : $flagged  (FileVersionInfo match=$isReshadeByFvi, filename heuristic match=$isReshadeByName)")
                    $reshadeLines.Add("")

                    if ($flagged) {
                        $Summary.ReShadeFound = $true
                        if (-not $Summary.ReShadeModuleName) { $Summary.ReShadeModuleName = $dll.Name }
                        else { $Summary.ReShadeModuleName += ", $($dll.Name)" }
                    }
                } catch {
                    $reshadeLines.Add("Error reading info for $($dll.Name): $($_.Exception.Message)")
                }
            }
        } catch {
            $reshadeLines.Add("Get-ChildItem for DLLs failed: $($_.Exception.Message)")
        }

        # addon files
        $reshadeLines.Add("=== ReShade addon files (*.addon64 / *.addon) in GameDir ===")
        try {
            $addons = Get-ChildItem -LiteralPath $GameDir -Include '*.addon64', '*.addon' -File -Recurse -ErrorAction SilentlyContinue
            if ($addons) {
                foreach ($a in $addons) { $reshadeLines.Add($a.FullName) }
            } else {
                $reshadeLines.Add("(none found)")
            }
        } catch {
            $reshadeLines.Add("Addon enumeration in GameDir failed: $($_.Exception.Message)")
        }

        # Parse ReShade.ini for [APP],[GENERAL],[ADDON],[INSTALL],[PROXY], and any AddonPath
        $reshadeLines.Add("")
        $reshadeLines.Add("=== ReShade.ini sections ===")
        $addonPathFromIni = $null
        try {
            $iniPath = Join-Path $GameDir 'ReShade.ini'
            if (Test-Path -LiteralPath $iniPath) {
                $iniContent = Get-Content -LiteralPath $iniPath -ErrorAction Stop
                $wantedSections = @('APP', 'GENERAL', 'ADDON', 'INSTALL', 'PROXY')
                $currentSection = $null
                $printing = $false
                foreach ($line in $iniContent) {
                    $trimmed = $line.Trim()
                    if ($trimmed -match '^\[(.+)\]$') {
                        $currentSection = $Matches[1]
                        $printing = ($wantedSections -contains $currentSection.ToUpper())
                        if ($printing) { $reshadeLines.Add("[$currentSection]") }
                        continue
                    }
                    if ($printing) {
                        $reshadeLines.Add($line)
                        if ($trimmed -match '^AddonPath\s*=\s*(.+)$') {
                            $addonPathFromIni = $Matches[1].Trim()
                        }
                    }
                }
            } else {
                $reshadeLines.Add("ReShade.ini not found in GameDir.")
            }
        } catch {
            $reshadeLines.Add("Error parsing ReShade.ini: $($_.Exception.Message)")
        }

        if ($addonPathFromIni) {
            $reshadeLines.Add("")
            $reshadeLines.Add("=== Addon files under AddonPath from ReShade.ini: $addonPathFromIni ===")
            try {
                $resolvedAddonPath = $addonPathFromIni
                if (-not [System.IO.Path]::IsPathRooted($resolvedAddonPath)) {
                    $resolvedAddonPath = Join-Path $GameDir $resolvedAddonPath
                }
                if (Test-Path -LiteralPath $resolvedAddonPath) {
                    $addonFiles2 = Get-ChildItem -LiteralPath $resolvedAddonPath -Include '*.addon64', '*.addon' -File -Recurse -ErrorAction SilentlyContinue
                    if ($addonFiles2) {
                        foreach ($a in $addonFiles2) { $reshadeLines.Add($a.FullName) }
                    } else {
                        $reshadeLines.Add("(none found in resolved AddonPath)")
                    }
                } else {
                    $reshadeLines.Add("Resolved AddonPath does not exist: $resolvedAddonPath")
                }
            } catch {
                $reshadeLines.Add("Error scanning AddonPath: $($_.Exception.Message)")
            }
        }
    } else {
        $reshadeLines.Add("GameDir not found: $GameDir")
    }

    $reshadeLines | Out-File -FilePath (Join-Path $OutDir 'reshade.txt') -Encoding UTF8
    Write-Ok "reshade.txt written."
} catch {
    Write-Fail "Section (e) reshade.txt failed entirely: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# f) Loaded modules of the running game process (optional)
# ----------------------------------------------------------------------------
Write-Section "f) Running process module inspection"
if ($GameExe) {
    try {
        $procName = [System.IO.Path]::GetFileNameWithoutExtension($GameExe)
        $procs = Get-Process -Name $procName -ErrorAction SilentlyContinue
        if (-not $procs) {
            Write-Warn "Process '$procName' is not currently running - skipping module inspection."
            "Process '$procName' not running at collection time." | Out-File -FilePath (Join-Path $OutDir 'process-modules.txt') -Encoding UTF8
        } else {
            $modLines = New-Object System.Collections.Generic.List[string]
            $pattern = '(?i)dxgi|d3d1|reshade|nvspcap|nvwgf2|nvngx|overlay|rtss|specialk|streamline|sl\.interposer|nvapi'
            foreach ($proc in $procs) {
                $modLines.Add("=== Process $($proc.Name) (PID $($proc.Id)) ===")
                try {
                    $modules = $proc.Modules
                    foreach ($m in $modules) {
                        if ($m.ModuleName -match $pattern -or $m.FileName -match $pattern) {
                            $modLines.Add("$($m.ModuleName)  =>  $($m.FileName)  (FileVersion: $($m.FileVersionInfo.FileVersion))")
                        }
                    }
                } catch {
                    $modLines.Add("Could not enumerate modules for PID $($proc.Id): $($_.Exception.Message)")
                    $modLines.Add("This commonly requires the script to run elevated (Administrator), or run as the same user/architecture as the target process (32-bit script cannot inspect a 64-bit process module list and vice versa).")
                }
            }
            $modLines | Out-File -FilePath (Join-Path $OutDir 'process-modules.txt') -Encoding UTF8
            Write-Ok "process-modules.txt written."
        }
    } catch {
        Write-Fail "Section (f) process module inspection failed: $($_.Exception.Message)"
    }
} else {
    Write-Warn "GameExe not supplied - skipping section (f)."
    "GameExe parameter not supplied - section skipped." | Out-File -FilePath (Join-Path $OutDir 'process-modules.txt') -Encoding UTF8
}

# ----------------------------------------------------------------------------
# g) Keyword grep across collected logs + console summary
# ----------------------------------------------------------------------------
Write-Section "g) Keyword scan of collected logs"
try {
    $keywords = @('NVFBC', 'CaptureFrame', 'Current Res', 'INVALIDATED', 'PID', 'Output', 'monitor')
    $pattern = ($keywords | ForEach-Object { [regex]::Escape($_) }) -join '|'
    $hits = New-Object System.Collections.Generic.List[string]

    try {
        $filesToScan = Get-ChildItem -LiteralPath $LogsDir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Extension -in @('.log', '.txt') }
        foreach ($f in $filesToScan) {
            try {
                $lineNum = 0
                $reader = [System.IO.File]::OpenText($f.FullName)
                try {
                    while (-not $reader.EndOfStream) {
                        $line = $reader.ReadLine()
                        $lineNum++
                        if ($line -match $pattern) {
                            $hits.Add("$($f.Name):${lineNum}: $line")
                        }
                    }
                } finally {
                    $reader.Close()
                }
            } catch {
                $hits.Add("$($f.Name): ERROR reading file: $($_.Exception.Message)")
            }
        }
    } catch {
        $hits.Add("Keyword scan enumeration failed: $($_.Exception.Message)")
    }

    $hits | Out-File -FilePath (Join-Path $LogsDir 'keyword-hits.txt') -Encoding UTF8
    Write-Ok "logs\keyword-hits.txt written ($($hits.Count) matching lines)."
} catch {
    Write-Fail "Section (g) keyword scan failed entirely: $($_.Exception.Message)"
}

# ----------------------------------------------------------------------------
# Console summary
# ----------------------------------------------------------------------------
Write-Section "SUMMARY"
try {
    Write-Host "Primary display        : $(if ($Summary.PrimaryDisplay) { $Summary.PrimaryDisplay } else { '<not determined>' })"
    Write-Host "Display orientations    :"
    if ($Summary.DisplayOrientations.Count -gt 0) {
        foreach ($d in $Summary.DisplayOrientations) { Write-Host "    $d" }
    } else {
        Write-Host "    <none collected>"
    }
    Write-Host "ReShade found in GameDir: $($Summary.ReShadeFound)  Module(s): $(if ($Summary.ReShadeModuleName) { $Summary.ReShadeModuleName } else { '<none>' })"
    Write-Host "NVSPCAPS DwmEnabled     : found=$($Summary.DwmEnabledFound)  value=$(if ($Summary.DwmEnabledValue) { $Summary.DwmEnabledValue } else { '<n/a>' })"
    Write-Host "NVSPCAPS DwmEnabledUser : found=$($Summary.DwmEnabledUserFound)  value=$(if ($Summary.DwmEnabledUserValue) { $Summary.DwmEnabledUserValue } else { '<n/a>' })"
    Write-Host "CaptureCore.log found   : $($Summary.CaptureCoreLogFound)"
    Write-Host ""
    Write-Host "Diagnostic bundle written to: $OutDir"
} catch {
    Write-Fail "Failed to print summary: $($_.Exception.Message)"
}

if ($TranscriptStarted) {
    try { Stop-Transcript | Out-Null } catch { Write-Warn "Stop-Transcript failed: $($_.Exception.Message)" }
}
