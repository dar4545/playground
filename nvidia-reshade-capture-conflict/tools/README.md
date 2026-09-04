# NVIDIA App / ReShade capture-conflict tools

Two PowerShell scripts (5.1 and 7.x compatible) for troubleshooting NVIDIA
App in-game overlay recording (NvFBC / Alt+F9) failing when ReShade is
injected into a game on a portrait primary monitor + landscape secondary
monitor setup (symptoms: `NVFBC_ERROR_INVALIDATED_SESSION`, "Failed to fetch
Current Res").

## Collect-NvCaptureDiag.ps1

**Read-only.** Makes no changes to the system or registry. Gathers OS/driver
info, full display topology (position, resolution, orientation, primary
flag), the relevant NVIDIA `ShadowPlay\NVSPCAPS` registry values, NVIDIA and
ReShade log files, and a DLL/addon inventory of the game folder, into a
timestamped output directory. Every section runs in its own try/catch so one
failure (e.g. a missing WMI provider, no elevation) does not stop the rest
of the collection. A full transcript is written to `transcript.txt`.

```powershell
.\Collect-NvCaptureDiag.ps1 -GameDir "D:\Games\MyGame" -GameExe "MyGame.exe"
.\Collect-NvCaptureDiag.ps1 -GameDir "D:\Games\MyGame" -OutDir "C:\diag\run1"
```

Parameters:
- `-GameDir` (mandatory): folder containing the game exe and ReShade files.
- `-OutDir` (optional): defaults to `.\nvcapture-diag-<timestamp>`.
- `-GameExe` (optional): if the process is currently running, its loaded
  modules matching `dxgi|d3d1|reshade|nvspcap|nvwgf2|nvngx|overlay|rtss|
  specialk|streamline|sl.interposer|nvapi` are listed. Module enumeration of
  a running process commonly requires an elevated session.

Output: `system.txt`, `displays.txt`, `nvidia-registry.txt`, `reshade.txt`,
`process-modules.txt`, `logs\` (copied log/ini files plus `manifest.txt` and
`keyword-hits.txt`), `transcript.txt`. A short summary (primary display,
per-display orientation, whether a ReShade module was detected and its
name, NVSPCAPS `DwmEnabled`/`DwmEnabledUser` decoded values, whether
`CaptureCore.log` was found) is printed to the console at the end.

## Set-NvCaptureWorkaround.ps1

Applies or reverts individual workarounds, one switch/parameter per
workaround, all independent of each other. **Nothing is changed without a
backup first** (`.\nvcapture-backup-<timestamp>\`: `.reg` exports for
registry changes, file copies for renames). Supports `-WhatIf`/`-Confirm`
(`SupportsShouldProcess`). Nothing is downloaded automatically at any point.

```powershell
# Preview only, changes nothing:
.\Set-NvCaptureWorkaround.ps1 -DesktopCapture Off -WhatIf

# Turn NVIDIA App desktop/overlay capture off, then restart the overlay:
.\Set-NvCaptureWorkaround.ps1 -DesktopCapture Off
.\Set-NvCaptureWorkaround.ps1 -RestartNvidiaOverlay

# Make the landscape monitor primary instead of the portrait one:
.\Set-NvCaptureWorkaround.ps1 -SetPrimaryDisplay '\\.\DISPLAY2'

# Rename the ReShade proxy DLL to work around a specific hook path:
.\Set-NvCaptureWorkaround.ps1 -RenameReShade d3d12 -GameDir 'D:\Games\MyGame'
.\Set-NvCaptureWorkaround.ps1 -RenameReShade restore -GameDir 'D:\Games\MyGame'

# Print manual ReShade reinstall / resolution-change guidance (no download/edit performed):
.\Set-NvCaptureWorkaround.ps1 -InstallReShadeVersion 6.5.1 -GameDir 'D:\Games\MyGame'
.\Set-NvCaptureWorkaround.ps1 -CaptureResolution InGame

# Undo the most recent change:
.\Set-NvCaptureWorkaround.ps1 -Revert
```

Parameters:
- `-DesktopCapture <On|Off>`: toggles `HKCU:\SOFTWARE\NVIDIA
  Corporation\Global\ShadowPlay\NVSPCAPS` `DwmEnabled`/`DwmEnabledUser`
  (REG_BINARY, `01 00 00 00`=On / `00 00 00 00`=Off). Requires restarting the
  NVIDIA App overlay (`-RestartNvidiaOverlay`, or sign out/in) to take
  effect. The supported UI equivalent is Alt+Z > Settings > Privacy control >
  Desktop capture.
- `-SetPrimaryDisplay <\\.\DISPLAYn | index>`: makes the given display
  primary via `ChangeDisplaySettingsEx`, repositioning all displays so the
  new primary sits at (0,0). Prints before/after topology.
- `-RenameReShade <d3d11|d3d12|dxgi|restore> -GameDir <path>`: renames the
  detected ReShade proxy DLL (and matching `.ini`/`.log`) to the requested
  API hook name; `restore` reverts using the run's own manifest. Refuses to
  overwrite a same-named file that is not itself ReShade.
- `-InstallReShadeVersion <version> -GameDir <path>`: prints exact manual
  download/reinstall steps only; downloads nothing.
- `-CaptureResolution <value>`: prints NVIDIA App UI guidance only; edits no
  config files.
- `-RestartNvidiaOverlay [-Force]`: stops overlay-related NVIDIA processes
  and relaunches the NVIDIA App. `-Force` additionally restarts the
  `NvContainerLocalSystem` service (needs elevation).
- `-Revert`: reverts everything recorded in the most recent
  `nvcapture-backup-*` folder (registry re-import + file renames undone).

Neither script requires elevation to run, but both detect and report
elevation state, and some actions (service restart, some registry areas,
module enumeration of another process) work better or only when elevated.

## Validation

Both scripts were parse-checked with PowerShell 7's
`[System.Management.Automation.Language.Parser]::ParseFile()` and produce no
errors. They cannot be executed end-to-end outside Windows; review the
`-WhatIf` output and the transcript/output files after a real run.
