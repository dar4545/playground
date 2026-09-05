# Fix procedure: NVIDIA overlay recording with ReShade on a portrait multi-monitor setup

This is the reproducible procedure. Run the steps in order. Each step states what to change, how to test, what result means what, and how to revert. Stop at the first step that gives a working recording and keep that configuration. Do not combine steps unless told to.

Every step assumes the same test:

```
TEST = 1. Start the game with ReShade loaded, on the portrait monitor, in the mode you normally use.
       2. Wait until gameplay is rendering (past menus/loading).
       3. Press Alt+F9, play 10 seconds, press Alt+F9 again.
       4. Check the NVIDIA App video folder (default: %USERPROFILE%\Videos\<game name>) for a new file with a duration greater than 0.
PASS = file exists and plays.  FAIL = "Saving recording" appears immediately and no file is created.
```

Before starting, run the diagnostic collector once so you have a baseline:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Collect-NvCaptureDiag.ps1 -GameDir "C:\Path\To\Game" -GameExe game.exe
```

Keep the output folder. Re-run it after any step that passes so the passing state is recorded too.

---

## Step 0. Confirm the baseline (no ReShade)

1. Temporarily rename ReShade's DLL in the game folder (usually `dxgi.dll`, otherwise `d3d11.dll` or `d3d12.dll`) to `dxgi.dll.off`. Same for the per-DLL `.ini` file next to it.
2. Run TEST.

| Result | Meaning | Next |
|---|---|---|
| PASS | Baseline confirmed. The problem is tied to ReShade being loaded. | Rename the files back and continue with Step 1. |
| FAIL | The problem is not ReShade at all. It is the NVIDIA multi-monitor bug on its own. | Rename the files back. Do Step 1 and Step 2 and stop there; the ReShade-specific steps do not apply. |

---

## Step 1. Apply NVIDIA's official fix for wrong-screen capture (KB 5164)

NVIDIA's knowledge-base article 5164 ("GeForce Experience Shadowplay may intermittently record the wrong screen in multi-monitor configurations") gives exactly this procedure. It targets the same failure signature: capture bound to the wrong monitor on Windows 10 20H1 and later because of Video Present Network manager changes.

1. In the game, press Alt+Z to open the NVIDIA overlay.
2. Open Settings (gear icon).
3. Open "Privacy control".
4. Set "Desktop capture" to OFF.
5. Close the overlay, quit the game completely, then relaunch it. The setting only applies to newly hooked processes.
6. If the game is running in windowed or borderless mode, change it to "Full screen" or "Full screen exclusive" in the game's own settings before testing.
7. Run TEST.

Optional registry check that the toggle actually took effect (the overlay stores it under `HKCU\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS`, values `DwmEnabled` and `DwmEnabledUser`, 4-byte binary, `00 00 00 00` is OFF):

```powershell
powershell -ExecutionPolicy Bypass -File tools\Set-NvCaptureWorkaround.ps1 -DesktopCapture Off
```

| Result | Meaning | Next |
|---|---|---|
| PASS | Fixed. Keep Desktop capture OFF. | Done. |
| FAIL | The PID capture path itself is picking the wrong display. | Step 2. |

Revert: set "Desktop capture" back to ON in the same menu.

---

## Step 2. Pin the capture resolution instead of "In-game"

The failing log line "Failed to fetch Current Res" is the overlay reading the current display mode of the display it associated with the game. The "In-game" resolution setting forces that lookup. A fixed resolution skips it. One NVIDIA forum user with the wrong-monitor symptom reported this as their fix.

1. Open NVIDIA App, go to Settings, then "Video capture" (in older GeForce Experience: Alt+Z, Settings, Video capture).
2. Change "Resolution" from "In-game" to an explicit value. Use "4K" (3840×2160) for the portrait 2160×3840 display; NVIDIA does not offer a portrait preset, so the recording will be scaled and letterboxed or pillarboxed, which is acceptable for the test.
3. Quit and relaunch the game.
4. Run TEST.

| Result | Meaning | Next |
|---|---|---|
| PASS | Usable fix. The display association is still wrong but the resolution query no longer runs. Keep it, or continue to Step 4 if you want a portrait-native recording. | Done or Step 4. |
| FAIL | The session is invalidated regardless of resolution. | Step 3. |

Revert: set Resolution back to "In-game".

---

## Step 3. Make the portrait monitor the primary display

When NVIDIA's capture cannot map the process to a display it falls back to the primary or first display. Making the game display primary makes the fallback correct. This is the workaround given repeatedly on NVIDIA's forums for wrong-screen recording. One forum report states GPU port order can override the Windows primary setting; the cable swap in 3c covers that.

1. Windows Settings, System, Display: select the portrait monitor, tick "Make this my main display". Or:
   ```powershell
   powershell -ExecutionPolicy Bypass -File tools\Set-NvCaptureWorkaround.ps1 -SetPrimaryDisplay \\.\DISPLAY2
   ```
   (use the device name shown for the portrait monitor in `displays.txt` from the diagnostic run).
2. NVIDIA Control Panel, "Set up multiple displays": make sure the asterisk (primary) is on the portrait monitor.
3. Quit and relaunch the game. Run TEST.
   - 3a. If FAIL, temporarily disconnect the 2560×1440 monitor entirely (cable out), relaunch, run TEST. A PASS here proves the wrong-display selection is the whole problem.
   - 3b. If 3a passed, reconnect the monitor and try Step 4 or 5 for a permanent fix that keeps both monitors.
   - 3c. If 3a failed and the two monitors are on different ports, swap the cables between the two GPU outputs and repeat TEST once.

| Result | Meaning | Next |
|---|---|---|
| PASS | Fallback path now targets the correct display. Keep it. | Done. |
| FAIL (including 3a) | The session is failing for a reason other than display choice. Collect logs (Step 7) and go to Step 4 anyway; the ReShade version test is still informative. | Step 4. |

Revert: put the primary display back as before.

---

## Step 4. ReShade version bisect: 6.5.1 versus 6.6.0 and later

This is the decisive ReShade-side test. It is based on verified ReShade source history:

- ReShade 6.5.1 (tagged 2025-06-08) hooks the real DXGI factory's vtable. The game and everything injected into it see the driver's own factory and adapter objects. Only the swapchain is a ReShade proxy object.
- ReShade 6.6.0 (tagged 2025-09-26) and every later version hand out a ReShade proxy factory (commit d43daf0, 2025-06-20, "Rework DXGI factory hooks to use a proxy class", motivated by NVIDIA Smooth Motion vtable hooks) and a proxy adapter (commit 3adf9c5, 2025-08-20, "Add DXGI adapter proxy to track swap chain creation"). ReShade's own code comments document that DXGI-internal code crashes when it reaches a proxied adapter, and that NVIDIA driver code vtable-hooks the factory it sees.

If your failing setup runs 6.6.0 or later, this test tells you whether the proxy objects are the trigger.

1. Note the currently installed ReShade version: right-click the ReShade DLL in the game folder, Properties, Details, "Product version". Or read it from `reshade.txt` in the diagnostic output.
2. Back up the game folder's ReShade files (`dxgi.dll` or equivalent, `ReShade.ini`, the per-DLL `.ini`, `reshade-shaders\`, `reshade-presets\` if present).
3. Download ReShade 6.5.1 from the official archive: https://reshade.me/downloads/ReShade_Setup_6.5.1.exe (also listed at https://reshade.me/releases). Verify the download comes from reshade.me.
4. Run the 6.5.1 setup, select the same game and the same API, and let it overwrite the DLL. Do not install add-ons. Keep your presets.
5. Confirm the DLL now reports product version 6.5.1.
6. Quit and relaunch the game. Run TEST.

| Result | Meaning | Next |
|---|---|---|
| PASS on 6.5.1 | Confirmed: the proxy DXGI factory and adapter objects introduced in 6.6.0 are what diverts NVIDIA's capture onto the wrong display. Staying on 6.5.1 is a working fix. For a fix on current ReShade, go to Step 5. | Done, or Step 5. |
| FAIL on 6.5.1 | The proxy objects are not the trigger; the remaining candidate is the swapchain proxy itself, which exists in every ReShade version. Restore your original version and go to Step 6. | Step 6. |

Revert: run your original ReShade version's setup again, or copy the backed-up files back.

---

## Step 5. Permanent fix on current ReShade: force vtable factory hooks

Current ReShade still contains the vtable-hook code path and switches to it automatically when the Ubisoft Connect overlay module is detected. `patches/reshade-dxgi-factory-vtable-hooks-option.patch` extends that switch in two ways:

- Automatically selects vtable hooks when the NVIDIA overlay capture library (`nvspcap64.dll`, or `nvspcap.dll` for 32-bit games) is loaded in the process.
- Adds a configuration override so the behaviour can be forced either way without rebuilding:

  ```ini
  [APP]
  DXGIFactoryVTableHooks=1
  ```

  placed in the per-DLL ini next to ReShade (for example `dxgi.ini`), or in the global `ReShade.ini` `[APP]` section.

The patch was verified to apply cleanly to ReShade tag v6.8.0 and to `main` at commit 358c345 (2026-09-03). It touches one file, `source/dxgi/dxgi.cpp`, and adds 19 lines. It has not been compiled in this environment, because ReShade needs Visual Studio on Windows to build; the change uses only APIs already used in that file and in `dll_main_test_app.cpp` (`reshade::global_config().get`).

Build and install:

1. `git clone --recurse-submodules https://github.com/crosire/reshade.git` and `git checkout v6.8.0` (or the version you use).
2. `git apply path\to\reshade-dxgi-factory-vtable-hooks-option.patch`
3. Open `ReShade.sln` in Visual Studio 2022, build configuration "Release" (or "Release App" for the add-on-enabled build), platform x64.
4. Copy the produced `ReShade64.dll` over the ReShade DLL in the game folder, keeping the existing file name (`dxgi.dll` etc.).
5. Add `DXGIFactoryVTableHooks=1` under `[APP]` in the per-DLL ini so the behaviour does not depend on NVIDIA's injection timing.
6. Quit and relaunch the game. Run TEST.

| Result | Meaning | Next |
|---|---|---|
| PASS | Fixed on current ReShade. Submit the patch upstream (see "Reporting" below). | Done. |
| FAIL while Step 4 passed | The vtable path in current ReShade differs from 6.5.1 in some other way; bisect the remaining commits between v6.5.1 and v6.6.0 with `git bisect` using the same TEST. Candidate commits are listed in the report. | Bisect. |

Revert: restore the official ReShade DLL and remove the ini key.

---

## Step 6. Presentation-mode and DLL-name variants (only if Step 4 failed)

These change what NVIDIA's hooks observe without changing ReShade's object proxying.

6a. Rename the ReShade proxy DLL. If it is `dxgi.dll`, rename it to `d3d11.dll` (D3D11 game) or `d3d12.dll` (D3D12 game), together with its `.ini` and `.log`. ReShade then hooks the system `dxgi.dll` by function hook instead of replacing the module, so anything that resolves `dxgi.dll` by module name gets Microsoft's module.
```powershell
powershell -ExecutionPolicy Bypass -File tools\Set-NvCaptureWorkaround.ps1 -RenameReShade d3d11 -GameDir "C:\Path\To\Game"
```
Run TEST. Revert with `-RenameReShade restore`.

6b. Switch the game between exclusive fullscreen and borderless (game settings). Run TEST in the other mode. Exclusive fullscreen and borderless take different display-association paths in the driver.

6c. If the game has a Vulkan renderer, switch to it and install ReShade as the Vulkan layer. No DXGI objects are proxied in that mode. Run TEST.

| Result | Meaning |
|---|---|
| PASS on 6a | Module-name resolution was the trigger. Keep the renamed DLL. |
| PASS on 6b | Keep that presentation mode. |
| PASS on 6c | Keep Vulkan. |
| FAIL on all | Use desktop capture (Step 8) or OBS, and file the reports in Step 7. |

---

## Step 7. Collect evidence and report

Run the collector again in the failing configuration, then in the best passing configuration:

```powershell
powershell -ExecutionPolicy Bypass -File tools\Collect-NvCaptureDiag.ps1 -GameDir "C:\Path\To\Game" -GameExe game.exe
```

It gathers `C:\ProgramData\NVIDIA Corporation\ShadowPlay\CaptureCore.log` (where the capture engine logs which output it bound), NVIDIA App logs, `ReShade.log` (which dumps the swapchain description at creation, including the windowed flag and swap effect), the exact display topology with orientation, the `NVSPCAPS` registry values, and the list of DXGI and NVIDIA modules loaded in the game process.

Report to ReShade (https://github.com/crosire/reshade/issues) if Step 4 or Step 5 passed. Include: ReShade versions that pass and fail, the game and API, both monitors' resolution and orientation, the `CaptureCore.log` lines around `NVFBC`, and a link to the patch. Title suggestion: "NVIDIA App recording fails (NvFBC binds wrong display) since 6.6.0 DXGI factory proxy; vtable hooks fix it".

Report to NVIDIA (NVIDIA App feedback, or https://www.nvidia.com/en-us/geforce/forums/) in every case, because the underlying wrong-display fallback is theirs. Include the same logs plus the Windows build number; NVIDIA attributes the bug to Windows 10 20H1 and later VidPN manager changes.

---

## Step 8. Fallback that always records ReShade output

If nothing above passes:

- Turn "Desktop capture" ON (Alt+Z, Settings, Privacy control) and record. This uses an output-tracking capture of the display instead of a PID session. ReShade's effects are in the presented frame, so they are recorded. The whole monitor is captured, including any overlays.
- Or use OBS Studio with "Game Capture" (hook) on the game window. This is the most commonly recommended alternative on the ReShade forum for exactly this class of injector conflict.

---

## Decision summary

```
Step 0 baseline FAIL  -> not ReShade: Step 1, Step 2, stop.
Step 1 PASS           -> keep Desktop capture OFF + fullscreen.
Step 2 PASS           -> keep fixed capture resolution.
Step 3 PASS           -> keep portrait as primary.
Step 4 PASS on 6.5.1  -> proxy objects are the trigger: stay on 6.5.1 or build patched ReShade (Step 5).
Step 5 PASS           -> patched ReShade with DXGIFactoryVTableHooks=1; submit upstream.
Step 6 PASS           -> keep that variant.
All FAIL              -> Step 8 fallback; file both reports with Step 7 evidence.
```

---

## Addendum: if the scsp-localify plugin is also installed

See `PLUGIN-scsp-localify.md` for the analysis. Changes to the steps above:

- **Step 0** gains two extra baselines: game with plugin only (`version.dll` present, ReShade DLL renamed off) and game with both. If "plugin only" fails, the plugin's GUI or console window is a trigger on its own.
- **Every TEST**: close the plugin GUI (Ctrl+U) and click the game window before pressing Alt+F9. Run the tests with `"enableConsole": false` in `scsp-config.json`.
- **Step 1 and Step 6b**: in-game resolution and fullscreen changes are blocked by the plugin after startup. Use `startResolution` in `scsp-config.json` (`{"w": 2160, "h": 3840, "isFull": true}`) or the GUI's "Update Resolution", then close the GUI. For true exclusive fullscreen on Unity, add `-window-mode exclusive -monitor <n>` to the launch arguments if the launcher allows it.
- **Optional**: build the plugin with `patches/scsp-localify-gui-window-on-game-monitor.patch` so the GUI opens on the game's monitor. Test "GUI open on portrait monitor" vs "GUI closed" to tell display ambiguity apart from the second (WARP) swapchain as the trigger.
