<#
.SYNOPSIS
    Applies or reverts individual, independent workarounds for the NVIDIA App /
    NvFBC in-game overlay capture conflict with ReShade on portrait+landscape
    multi-monitor setups.

.DESCRIPTION
    Switch-driven. Each workaround is applied independently based on which
    parameters you pass. Every state-changing action backs up what it is about
    to touch (registry .reg export and/or file copies) into
    .\nvcapture-backup-<timestamp>\ before making any change, and supports
    -WhatIf / -Confirm via SupportsShouldProcess. Nothing is downloaded
    automatically. Nothing changes on disk or in the registry unless you pass
    an action parameter.

.PARAMETER DesktopCapture
    'On' or 'Off'. Toggles HKCU ShadowPlay\NVSPCAPS DwmEnabled / DwmEnabledUser
    (REG_BINARY 4-byte 01 00 00 00 = On, 00 00 00 00 = Off).

.PARAMETER SetPrimaryDisplay
    Target display, e.g. '\\.\DISPLAY2' or a 1-based index into the attached
    display list. Makes it the Windows primary display and repositions all
    displays so the new primary sits at (0,0).

.PARAMETER RenameReShade
    'd3d11' | 'd3d12' | 'dxgi' | 'restore'. Renames the detected ReShade proxy
    DLL (and its matching .ini/.log) in -GameDir to the requested proxy name,
    or restores from the most recent backup manifest when 'restore' is given.

.PARAMETER InstallReShadeVersion
    A version string, e.g. '6.5.1'. Prints manual installation guidance only;
    does not download or run anything.

.PARAMETER CaptureResolution
    e.g. '3840x2160' or 'InGame'. Prints guidance only; does not edit any
    NVIDIA App configuration.

.PARAMETER RestartNvidiaOverlay
    Stops overlay-related NVIDIA processes and relaunches the NVIDIA App.

.PARAMETER Force
    When combined with -RestartNvidiaOverlay, also restarts the
    NvContainerLocalSystem service (requires elevation).

.PARAMETER Revert
    Reverts all changes recorded in the most recent .\nvcapture-backup-*
    folder (registry re-import + renamed files restored).

.PARAMETER GameDir
    Required for -RenameReShade and -InstallReShadeVersion.

.EXAMPLE
    .\Set-NvCaptureWorkaround.ps1 -DesktopCapture Off -WhatIf

.EXAMPLE
    .\Set-NvCaptureWorkaround.ps1 -SetPrimaryDisplay '\\.\DISPLAY2'

.EXAMPLE
    .\Set-NvCaptureWorkaround.ps1 -RenameReShade d3d12 -GameDir 'D:\Games\MyGame'

.EXAMPLE
    .\Set-NvCaptureWorkaround.ps1 -RestartNvidiaOverlay

.EXAMPLE
    .\Set-NvCaptureWorkaround.ps1 -Revert

.NOTES
    PowerShell 5.1 and 7.x compatible. Does not require elevation for most
    actions; registry export/import of NvContainer keys and service restarts
    may need an elevated session.
#>

[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [Parameter(Mandatory = $false)]
    [ValidateSet('On', 'Off')]
    [string]$DesktopCapture,

    [Parameter(Mandatory = $false)]
    [string]$SetPrimaryDisplay,

    [Parameter(Mandatory = $false)]
    [ValidateSet('d3d11', 'd3d12', 'dxgi', 'restore')]
    [string]$RenameReShade,

    [Parameter(Mandatory = $false)]
    [string]$InstallReShadeVersion,

    [Parameter(Mandatory = $false)]
    [string]$CaptureResolution,

    [Parameter(Mandatory = $false)]
    [switch]$RestartNvidiaOverlay,

    [Parameter(Mandatory = $false)]
    [switch]$Force,

    [Parameter(Mandatory = $false)]
    [switch]$Revert,

    [Parameter(Mandatory = $false)]
    [string]$GameDir
)

$ErrorActionPreference = 'Continue'

function Write-Ok   { param([string]$Msg) Write-Host "[OK]   $Msg" -ForegroundColor Green }
function Write-Warn { param([string]$Msg) Write-Host "[WARN] $Msg" -ForegroundColor Yellow }
function Write-Fail { param([string]$Msg) Write-Host "[FAIL] $Msg" -ForegroundColor Red }
function Write-Info { param([string]$Msg) Write-Host "[INFO] $Msg" -ForegroundColor Cyan }

$AnyActionRequested = $DesktopCapture -or $SetPrimaryDisplay -or $RenameReShade -or $InstallReShadeVersion -or $CaptureResolution -or $RestartNvidiaOverlay -or $Revert
if (-not $AnyActionRequested) {
    Write-Warn "No action parameter was supplied. Use -DesktopCapture, -SetPrimaryDisplay, -RenameReShade, -InstallReShadeVersion, -CaptureResolution, -RestartNvidiaOverlay, or -Revert."
    Write-Host "Run with -? or open this file to see full usage examples in the comment header."
    return
}

$BackupRoot = $null
function Get-BackupRoot {
    if (-not $script:BackupRoot) {
        $script:BackupRoot = Join-Path (Get-Location) ("nvcapture-backup-{0}" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
        try {
            New-Item -ItemType Directory -Path $script:BackupRoot -Force | Out-Null
            Write-Info "Backup folder: $script:BackupRoot"
        } catch {
            Write-Fail "Could not create backup folder '$script:BackupRoot': $($_.Exception.Message)"
        }
    }
    return $script:BackupRoot
}

function Get-LatestBackupRoot {
    try {
        $candidates = Get-ChildItem -Path (Get-Location) -Directory -Filter 'nvcapture-backup-*' -ErrorAction SilentlyContinue |
            Sort-Object Name -Descending
        if ($candidates -and $candidates.Count -gt 0) {
            return $candidates[0].FullName
        }
    } catch {
        Write-Fail "Failed to locate a previous backup folder: $($_.Exception.Message)"
    }
    return $null
}

function Test-IsElevated {
    try {
        $currentIdentity = [System.Security.Principal.WindowsIdentity]::GetCurrent()
        $principal = New-Object System.Security.Principal.WindowsPrincipal($currentIdentity)
        return $principal.IsInRole([System.Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch {
        return $false
    }
}

# ----------------------------------------------------------------------------
# -DesktopCapture On|Off
# ----------------------------------------------------------------------------
if ($DesktopCapture) {
    Write-Info "=== -DesktopCapture $DesktopCapture ==="
    try {
        $nvspcapsPath = 'HKCU:\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS'
        if (-not (Test-Path -LiteralPath $nvspcapsPath)) {
            Write-Warn "Registry key not found: $nvspcapsPath. It may be created by the NVIDIA App on first run. Creating it now."
            if ($PSCmdlet.ShouldProcess($nvspcapsPath, "Create registry key")) {
                try {
                    New-Item -Path $nvspcapsPath -Force | Out-Null
                } catch {
                    Write-Fail "Could not create key: $($_.Exception.Message)"
                }
            }
        }

        $backupDir = Get-BackupRoot
        $regBackupFile = Join-Path $backupDir 'NVSPCAPS.reg'
        try {
            $regExportKey = 'HKCU\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS'
            $regExe = "$env:WINDIR\System32\reg.exe"
            if (Test-Path -LiteralPath $regExe) {
                & $regExe export $regExportKey $regBackupFile /y 2>$null | Out-Null
                if (Test-Path -LiteralPath $regBackupFile) {
                    Write-Ok "Backed up NVSPCAPS to $regBackupFile"
                } else {
                    Write-Warn "reg export did not produce a backup file (key may not have existed yet)."
                }
            } else {
                Write-Warn "reg.exe not found at expected path; skipping .reg backup (non-Windows or unusual layout)."
            }
        } catch {
            Write-Warn "reg export backup failed: $($_.Exception.Message)"
        }

        $bytes = if ($DesktopCapture -eq 'On') { [byte[]](1, 0, 0, 0) } else { [byte[]](0, 0, 0, 0) }

        foreach ($valName in @('DwmEnabled', 'DwmEnabledUser')) {
            try {
                $target = "$nvspcapsPath\$valName"
                if ($PSCmdlet.ShouldProcess($target, "Set REG_BINARY to $($bytes -join ',')")) {
                    Set-ItemProperty -LiteralPath $nvspcapsPath -Name $valName -Value $bytes -Type Binary -Force -ErrorAction Stop
                    Write-Ok "Set $valName = $($bytes -join ' ') (hex) under NVSPCAPS."
                }
            } catch {
                Write-Fail "Failed to set $valName : $($_.Exception.Message)"
            }
        }

        Write-Warn "The NVIDIA App overlay must be restarted for this to take effect: either restart 'nvcontainer' (or sign out/in of Windows), or use -RestartNvidiaOverlay."
        Write-Info "The supported UI path for this same setting is: NVIDIA App overlay (Alt+Z) > Settings > Privacy control > Desktop capture."
    } catch {
        Write-Fail "-DesktopCapture action failed: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# -SetPrimaryDisplay
# ----------------------------------------------------------------------------
if ($SetPrimaryDisplay) {
    Write-Info "=== -SetPrimaryDisplay $SetPrimaryDisplay ==="
    try {
        $primaryTypeDef = @"
using System;
using System.Runtime.InteropServices;

public class NvDiagPrimaryNative
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
    public const uint CDS_UPDATEREGISTRY = 0x00000001;
    public const uint CDS_NORESET = 0x10000000;
    public const uint CDS_SET_PRIMARY = 0x00000010;
    public const int DM_POSITION = 0x00000020;

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplayDevices(string lpDevice, uint iDevNum, ref DISPLAY_DEVICE lpDisplayDevice, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern bool EnumDisplaySettingsEx(string lpszDeviceName, int iModeNum, ref DEVMODE lpDevMode, uint dwFlags);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, ref DEVMODE lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    public static extern int ChangeDisplaySettingsEx(string lpszDeviceName, IntPtr lpDevMode, IntPtr hwnd, uint dwflags, IntPtr lParam);
}
"@
        try {
            Add-Type -TypeDefinition $primaryTypeDef -ErrorAction Stop
        } catch {
            Write-Warn "Add-Type for primary-display P/Invoke failed (type may already be loaded): $($_.Exception.Message)"
        }

        # Enumerate attached displays
        $displays = New-Object System.Collections.Generic.List[psobject]
        $devIndex = 0
        while ($true) {
            $dd = New-Object NvDiagPrimaryNative+DISPLAY_DEVICE
            $dd.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dd)
            $ok = [NvDiagPrimaryNative]::EnumDisplayDevices($null, $devIndex, [ref]$dd, 0)
            if (-not $ok) { break }
            $isAttached = (($dd.StateFlags -band 0x1) -ne 0)
            $isPrimary = (($dd.StateFlags -band 0x4) -ne 0)
            if ($isAttached) {
                $dm = New-Object NvDiagPrimaryNative+DEVMODE
                $dm.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm)
                [NvDiagPrimaryNative]::EnumDisplaySettingsEx($dd.DeviceName, [NvDiagPrimaryNative]::ENUM_CURRENT_SETTINGS, [ref]$dm, 0) | Out-Null
                $displays.Add([pscustomobject]@{
                    DeviceName = $dd.DeviceName
                    IsPrimary  = $isPrimary
                    DevMode    = $dm
                })
            }
            $devIndex++
            if ($devIndex -gt 32) { break }
        }

        if ($displays.Count -eq 0) {
            Write-Fail "No attached displays enumerated; cannot proceed."
        } else {
            Write-Info "Before:"
            foreach ($d in $displays) {
                Write-Host "    $($d.DeviceName)  pos=($($d.DevMode.dmPositionX),$($d.DevMode.dmPositionY))  $($d.DevMode.dmPelsWidth)x$($d.DevMode.dmPelsHeight)  Primary=$($d.IsPrimary)"
            }

            # Resolve target
            $target = $null
            if ($SetPrimaryDisplay -match '^\d+$') {
                $idx = [int]$SetPrimaryDisplay
                if ($idx -ge 1 -and $idx -le $displays.Count) {
                    $target = $displays[$idx - 1]
                } else {
                    Write-Fail "Index $idx out of range (1..$($displays.Count))."
                }
            } else {
                $target = $displays | Where-Object { $_.DeviceName -eq $SetPrimaryDisplay } | Select-Object -First 1
                if (-not $target) {
                    Write-Fail "Display '$SetPrimaryDisplay' not found among attached displays."
                }
            }

            if ($target) {
                if ($target.IsPrimary) {
                    Write-Ok "$($target.DeviceName) is already the primary display. No change needed."
                } else {
                    $offsetX = -$target.DevMode.dmPositionX
                    $offsetY = -$target.DevMode.dmPositionY

                    if ($PSCmdlet.ShouldProcess($target.DeviceName, "Set as primary display and reposition all displays (offset $offsetX,$offsetY)")) {
                        $applyFailed = $false
                        foreach ($d in $displays) {
                            try {
                                $dm2 = $d.DevMode
                                $dm2.dmPositionX = $dm2.dmPositionX + $offsetX
                                $dm2.dmPositionY = $dm2.dmPositionY + $offsetY
                                $dm2.dmFields = [NvDiagPrimaryNative]::DM_POSITION

                                $flags = [NvDiagPrimaryNative]::CDS_UPDATEREGISTRY -bor [NvDiagPrimaryNative]::CDS_NORESET
                                if ($d.DeviceName -eq $target.DeviceName) {
                                    $flags = $flags -bor [NvDiagPrimaryNative]::CDS_SET_PRIMARY
                                }

                                $result = [NvDiagPrimaryNative]::ChangeDisplaySettingsEx($d.DeviceName, [ref]$dm2, [IntPtr]::Zero, $flags, [IntPtr]::Zero)
                                if ($result -ne 0) {
                                    Write-Warn "ChangeDisplaySettingsEx for $($d.DeviceName) returned code $result (0=success)."
                                    $applyFailed = $true
                                } else {
                                    Write-Ok "Repositioned $($d.DeviceName) to ($($dm2.dmPositionX),$($dm2.dmPositionY))$(if ($d.DeviceName -eq $target.DeviceName) { ' [now primary]' })."
                                }
                            } catch {
                                Write-Fail "Failed to update $($d.DeviceName): $($_.Exception.Message)"
                                $applyFailed = $true
                            }
                        }

                        try {
                            $applyResult = [NvDiagPrimaryNative]::ChangeDisplaySettingsEx($null, [IntPtr]::Zero, [IntPtr]::Zero, 0, [IntPtr]::Zero)
                            if ($applyResult -eq 0) {
                                Write-Ok "Applied display changes (final ChangeDisplaySettingsEx call succeeded)."
                            } else {
                                Write-Warn "Final apply call returned code $applyResult."
                            }
                        } catch {
                            Write-Fail "Final ChangeDisplaySettingsEx apply call failed: $($_.Exception.Message)"
                        }

                        if (-not $applyFailed) {
                            Write-Ok "$($target.DeviceName) should now be the primary display."
                        }

                        Write-Info "After (re-querying):"
                        $devIndex = 0
                        while ($true) {
                            $dd2 = New-Object NvDiagPrimaryNative+DISPLAY_DEVICE
                            $dd2.cb = [System.Runtime.InteropServices.Marshal]::SizeOf($dd2)
                            $ok2 = [NvDiagPrimaryNative]::EnumDisplayDevices($null, $devIndex, [ref]$dd2, 0)
                            if (-not $ok2) { break }
                            if ((($dd2.StateFlags -band 0x1) -ne 0)) {
                                $dm3 = New-Object NvDiagPrimaryNative+DEVMODE
                                $dm3.dmSize = [System.Runtime.InteropServices.Marshal]::SizeOf($dm3)
                                [NvDiagPrimaryNative]::EnumDisplaySettingsEx($dd2.DeviceName, [NvDiagPrimaryNative]::ENUM_CURRENT_SETTINGS, [ref]$dm3, 0) | Out-Null
                                $isPrimary2 = (($dd2.StateFlags -band 0x4) -ne 0)
                                Write-Host "    $($dd2.DeviceName)  pos=($($dm3.dmPositionX),$($dm3.dmPositionY))  $($dm3.dmPelsWidth)x$($dm3.dmPelsHeight)  Primary=$isPrimary2"
                            }
                            $devIndex++
                            if ($devIndex -gt 32) { break }
                        }
                    }
                }
            }
        }
    } catch {
        Write-Fail "-SetPrimaryDisplay action failed: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# -RenameReShade
# ----------------------------------------------------------------------------
if ($RenameReShade) {
    Write-Info "=== -RenameReShade $RenameReShade ==="
    try {
        if (-not $GameDir) {
            Write-Fail "-GameDir is required with -RenameReShade."
        } elseif (-not (Test-Path -LiteralPath $GameDir)) {
            Write-Fail "GameDir not found: $GameDir"
        } else {
            $backupDir = Get-BackupRoot
            $renameManifestPath = Join-Path $backupDir 'rename-manifest.txt'

            if ($RenameReShade -eq 'restore') {
                $latestBackup = Get-LatestBackupRoot
                if (-not $latestBackup) {
                    Write-Fail "No previous backup folder found to restore from."
                } else {
                    $manifestFile = Join-Path $latestBackup 'rename-manifest.txt'
                    if (-not (Test-Path -LiteralPath $manifestFile)) {
                        Write-Fail "No rename-manifest.txt found in latest backup ($latestBackup)."
                    } else {
                        $entries = Get-Content -LiteralPath $manifestFile
                        foreach ($entry in $entries) {
                            $parts = $entry -split '\|'
                            if ($parts.Count -eq 2) {
                                $origPath = $parts[0]
                                $renamedPath = $parts[1]
                                try {
                                    if (Test-Path -LiteralPath $renamedPath) {
                                        if ($PSCmdlet.ShouldProcess($renamedPath, "Restore to $origPath")) {
                                            Move-Item -LiteralPath $renamedPath -Destination $origPath -Force -ErrorAction Stop
                                            Write-Ok "Restored $renamedPath -> $origPath"
                                        }
                                    } else {
                                        Write-Warn "Renamed file no longer present, cannot restore: $renamedPath"
                                    }
                                } catch {
                                    Write-Fail "Failed to restore $renamedPath -> $origPath : $($_.Exception.Message)"
                                }
                            }
                        }
                    }
                }
            } else {
                # Detect which proxy DLL currently is ReShade
                $candidateNames = @('dxgi.dll', 'd3d11.dll', 'd3d12.dll')
                $detected = $null
                foreach ($cn in $candidateNames) {
                    $full = Join-Path $GameDir $cn
                    if (Test-Path -LiteralPath $full) {
                        try {
                            $fvi = (Get-Item -LiteralPath $full).VersionInfo
                            if ($fvi.ProductName -match '(?i)reshade') {
                                $detected = $cn
                                break
                            }
                        } catch {
                            Write-Warn "Could not read version info for $full : $($_.Exception.Message)"
                        }
                    }
                }

                if (-not $detected) {
                    Write-Fail "Could not detect a ReShade proxy DLL (dxgi.dll/d3d11.dll/d3d12.dll with ProductName containing 'ReShade') in $GameDir."
                } else {
                    $targetName = "$RenameReShade.dll"
                    if ($detected -eq $targetName) {
                        Write-Ok "ReShade is already loaded as $targetName. Nothing to do."
                    } else {
                        $targetFull = Join-Path $GameDir $targetName
                        if (Test-Path -LiteralPath $targetFull) {
                            try {
                                $existingFvi = (Get-Item -LiteralPath $targetFull).VersionInfo
                                if ($existingFvi.ProductName -notmatch '(?i)reshade') {
                                    Write-Fail "Refusing to overwrite existing non-ReShade file: $targetFull"
                                    return
                                }
                            } catch {
                                Write-Fail "Target $targetFull exists and its type could not be verified; refusing to overwrite."
                                return
                            }
                        }

                        $detectedBase = [System.IO.Path]::GetFileNameWithoutExtension($detected)
                        $targetBase = $RenameReShade
                        $renameManifest = New-Object System.Collections.Generic.List[string]

                        $extPairs = @(
                            @{ Ext = '.dll'; Src = "$detectedBase.dll"; Dst = "$targetBase.dll" },
                            @{ Ext = '.ini'; Src = "$detectedBase.ini"; Dst = "$targetBase.ini" },
                            @{ Ext = '.log'; Src = "$detectedBase.log"; Dst = "$targetBase.log" }
                        )

                        foreach ($pair in $extPairs) {
                            $srcFull = Join-Path $GameDir $pair.Src
                            $dstFull = Join-Path $GameDir $pair.Dst
                            if (Test-Path -LiteralPath $srcFull) {
                                try {
                                    # backup a copy first
                                    $backupCopy = Join-Path $backupDir $pair.Src
                                    Copy-Item -LiteralPath $srcFull -Destination $backupCopy -Force -ErrorAction Stop

                                    if ($PSCmdlet.ShouldProcess($srcFull, "Rename to $dstFull")) {
                                        Move-Item -LiteralPath $srcFull -Destination $dstFull -Force -ErrorAction Stop
                                        Write-Ok "Renamed $($pair.Src) -> $($pair.Dst)"
                                        $renameManifest.Add("$srcFull|$dstFull")
                                    }
                                } catch {
                                    Write-Fail "Failed to rename $($pair.Src): $($_.Exception.Message)"
                                }
                            }
                        }

                        $renameManifest | Out-File -FilePath $renameManifestPath -Append -Encoding UTF8
                        Write-Ok "Rename manifest recorded at $renameManifestPath"
                    }
                }
            }
        }
    } catch {
        Write-Fail "-RenameReShade action failed: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# -InstallReShadeVersion (guidance only)
# ----------------------------------------------------------------------------
if ($InstallReShadeVersion) {
    Write-Info "=== -InstallReShadeVersion $InstallReShadeVersion (guidance only, no download performed) ==="
    try {
        if (-not $GameDir) {
            Write-Warn "-GameDir not supplied; showing generic guidance."
        }

        $currentVersionInfo = "not detected"
        if ($GameDir -and (Test-Path -LiteralPath $GameDir)) {
            foreach ($cn in @('dxgi.dll', 'd3d11.dll', 'd3d12.dll', 'opengl32.dll')) {
                $full = Join-Path $GameDir $cn
                if (Test-Path -LiteralPath $full) {
                    try {
                        $fvi = (Get-Item -LiteralPath $full).VersionInfo
                        if ($fvi.ProductName -match '(?i)reshade') {
                            $currentVersionInfo = "$cn -> ProductVersion=$($fvi.ProductVersion) FileVersion=$($fvi.FileVersion)"
                            break
                        }
                    } catch {
                        Write-Warn "Could not read version info for $full : $($_.Exception.Message)"
                    }
                }
            }
        }

        $downloadUrl = "https://reshade.me/downloads/ReShade_Setup_$InstallReShadeVersion.exe"
        $archiveUrl = "https://reshade.me/releases"

        Write-Host ""
        Write-Host "Manual steps to install ReShade $InstallReShadeVersion :"
        Write-Host "  1. Current detected ReShade DLL version in GameDir: $currentVersionInfo"
        Write-Host "  2. Back up GameDir's existing ReShade files first (this script does not do that for you"
        Write-Host "     under this action -- use -RenameReShade or a manual copy of dxgi.dll/d3d11.dll/d3d12.dll,"
        Write-Host "     ReShade.ini, ReShade64.dll if present, and the ReShadePreset*.ini / reshade-shaders folder)."
        Write-Host "  3. Download the installer from:"
        Write-Host "       $downloadUrl"
        Write-Host "     If that exact version is not listed, browse the archive at:"
        Write-Host "       $archiveUrl"
        Write-Host "  4. Run the downloaded ReShade_Setup_$InstallReShadeVersion.exe, point it at the game executable"
        Write-Host "     in: $GameDir"
        Write-Host "  5. The setup tool will overwrite the proxy DLL (dxgi.dll/d3d11.dll/d3d12.dll/opengl32.dll,"
        Write-Host "     whichever API you select) IN PLACE in GameDir -- it does not create a differently-named file."
        Write-Host "  6. Re-run Collect-NvCaptureDiag.ps1 -GameDir '$GameDir' afterward to confirm the new ProductVersion."
        Write-Host ""
        Write-Warn "This script does not download, execute, or verify any installer. You must do steps 3-4 yourself."
    } catch {
        Write-Fail "-InstallReShadeVersion guidance failed to print: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# -CaptureResolution (guidance only)
# ----------------------------------------------------------------------------
if ($CaptureResolution) {
    Write-Info "=== -CaptureResolution $CaptureResolution (guidance only) ==="
    try {
        Write-Host ""
        Write-Host "To change the NVIDIA App in-game recording resolution to '$CaptureResolution':"
        Write-Host "  1. Open the NVIDIA App overlay (Alt+Z) or the NVIDIA App itself."
        Write-Host "  2. Go to Settings > Video capture (or Recordings)."
        Write-Host "  3. Set 'Resolution' to '$CaptureResolution' (use 'In-game resolution' for native capture,"
        Write-Host "     or an explicit resolution like 3840x2160 to force downscale/match a specific output)."
        Write-Host ""
        Write-Warn "This script does not edit NVIDIA App configuration files directly -- use the UI path above."
    } catch {
        Write-Fail "-CaptureResolution guidance failed to print: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# -RestartNvidiaOverlay
# ----------------------------------------------------------------------------
if ($RestartNvidiaOverlay) {
    Write-Info "=== -RestartNvidiaOverlay ==="
    try {
        $isElevated = Test-IsElevated
        Write-Host "Elevated session: $isElevated"

        $processNames = @('nvsphelper64', 'NVIDIA app', 'NVIDIA App', 'NVIDIA Overlay')
        foreach ($pn in $processNames) {
            try {
                $procs = Get-Process -Name $pn -ErrorAction SilentlyContinue
                foreach ($p in $procs) {
                    if ($PSCmdlet.ShouldProcess("$($p.Name) (PID $($p.Id))", "Stop process")) {
                        try {
                            Stop-Process -Id $p.Id -Force -ErrorAction Stop
                            Write-Ok "Stopped process $($p.Name) (PID $($p.Id))."
                        } catch {
                            Write-Fail "Failed to stop $($p.Name) (PID $($p.Id)): $($_.Exception.Message)"
                        }
                    }
                }
                if (-not $procs) {
                    Write-Info "Process '$pn' was not running."
                }
            } catch {
                Write-Warn "Error while checking/stopping '$pn': $($_.Exception.Message)"
            }
        }

        if ($Force) {
            Write-Warn "-Force specified: attempting to restart NvContainerLocalSystem service (requires elevation)."
            try {
                if (-not $isElevated) {
                    Write-Warn "Session is not elevated; Restart-Service will likely fail. Re-run this script as Administrator for -Force to work."
                }
                if ($PSCmdlet.ShouldProcess('NvContainerLocalSystem', 'Restart-Service')) {
                    Restart-Service -Name 'NvContainerLocalSystem' -Force -ErrorAction Stop
                    Write-Ok "Restarted service NvContainerLocalSystem."
                }
            } catch {
                Write-Fail "Failed to restart NvContainerLocalSystem service: $($_.Exception.Message)"
            }
        } else {
            Write-Info "NvContainerLocalSystem service was NOT restarted (pass -Force to restart it; requires elevation)."
        }

        # Find NVIDIA App install location and relaunch
        try {
            $installLocation = $null
            $uninstallPaths = @(
                'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*',
                'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*'
            )
            foreach ($p in $uninstallPaths) {
                $entry = Get-ItemProperty -Path $p -ErrorAction SilentlyContinue |
                    Where-Object { $_.DisplayName -like '*NVIDIA App*' } | Select-Object -First 1
                if ($entry -and $entry.InstallLocation) {
                    $installLocation = $entry.InstallLocation
                    break
                }
            }

            if ($installLocation) {
                $exePath = Join-Path $installLocation 'NVIDIA app.exe'
                if (-not (Test-Path -LiteralPath $exePath)) {
                    $exePath = Join-Path $installLocation 'CEF\NVIDIA App.exe'
                }
                if (Test-Path -LiteralPath $exePath) {
                    if ($PSCmdlet.ShouldProcess($exePath, "Start process")) {
                        Start-Process -FilePath $exePath -ErrorAction Stop
                        Write-Ok "Relaunched NVIDIA App from $exePath"
                    }
                } else {
                    Write-Warn "Found install location '$installLocation' but could not locate the executable. Please launch the NVIDIA App manually from the Start Menu."
                }
            } else {
                Write-Warn "Could not determine NVIDIA App install location from the registry. Please launch it manually from the Start Menu."
            }
        } catch {
            Write-Fail "Failed to relaunch NVIDIA App: $($_.Exception.Message)"
        }
    } catch {
        Write-Fail "-RestartNvidiaOverlay action failed: $($_.Exception.Message)"
    }
}

# ----------------------------------------------------------------------------
# -Revert
# ----------------------------------------------------------------------------
if ($Revert) {
    Write-Info "=== -Revert ==="
    try {
        $latestBackup = Get-LatestBackupRoot
        if (-not $latestBackup) {
            Write-Fail "No backup folder (nvcapture-backup-*) found in the current directory."
        } else {
            Write-Info "Reverting from: $latestBackup"

            # Registry .reg files
            try {
                $regFiles = Get-ChildItem -LiteralPath $latestBackup -Filter '*.reg' -File -ErrorAction SilentlyContinue
                if ($regFiles) {
                    $regExe = "$env:WINDIR\System32\reg.exe"
                    foreach ($rf in $regFiles) {
                        try {
                            if ($PSCmdlet.ShouldProcess($rf.FullName, "reg import")) {
                                if (Test-Path -LiteralPath $regExe) {
                                    & $regExe import $rf.FullName 2>$null
                                    Write-Ok "Imported $($rf.Name)"
                                } else {
                                    Write-Warn "reg.exe not available; cannot import $($rf.Name)."
                                }
                            }
                        } catch {
                            Write-Fail "Failed to import $($rf.Name): $($_.Exception.Message)"
                        }
                    }
                } else {
                    Write-Info "No .reg backups found in $latestBackup."
                }
            } catch {
                Write-Fail "Registry revert step failed: $($_.Exception.Message)"
            }

            # Renamed files
            try {
                $manifestFile = Join-Path $latestBackup 'rename-manifest.txt'
                if (Test-Path -LiteralPath $manifestFile) {
                    $entries = Get-Content -LiteralPath $manifestFile
                    foreach ($entry in $entries) {
                        $parts = $entry -split '\|'
                        if ($parts.Count -eq 2) {
                            $origPath = $parts[0]
                            $renamedPath = $parts[1]
                            try {
                                if (Test-Path -LiteralPath $renamedPath) {
                                    if ($PSCmdlet.ShouldProcess($renamedPath, "Restore to $origPath")) {
                                        Move-Item -LiteralPath $renamedPath -Destination $origPath -Force -ErrorAction Stop
                                        Write-Ok "Restored $renamedPath -> $origPath"
                                    }
                                } else {
                                    Write-Warn "Renamed file no longer present, cannot restore: $renamedPath"
                                }
                            } catch {
                                Write-Fail "Failed to restore $renamedPath -> $origPath : $($_.Exception.Message)"
                            }
                        }
                    }
                } else {
                    Write-Info "No rename-manifest.txt found in $latestBackup."
                }
            } catch {
                Write-Fail "File-rename revert step failed: $($_.Exception.Message)"
            }

            Write-Ok "Revert from $latestBackup complete (see [WARN]/[FAIL] lines above for any partial failures)."
        }
    } catch {
        Write-Fail "-Revert action failed: $($_.Exception.Message)"
    }
}

Write-Host ""
Write-Info "Set-NvCaptureWorkaround.ps1 finished."
