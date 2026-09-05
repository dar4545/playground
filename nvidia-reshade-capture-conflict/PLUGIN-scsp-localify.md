# Does adding scsp-localify create new conflicts with NVIDIA overlay recording or ReShade?

Assessment of https://github.com/dar4545/scsp-localify at commit 3890f84 (2026-09-04), read against ReShade `main` (358c345) and the NVIDIA capture findings in `README.md`.

## Short answer

Yes, one new conflict with NVIDIA recording, no new conflict with ReShade's hooking, and a few side effects that change how the fix procedure must be run.

1. **New wrong-display trigger (NVIDIA).** When the plugin GUI is open (Ctrl+U), the process owns a second top-level window, "iM@S SCSP GUI", created at absolute desktop coordinates (100,100), which is on the primary display, not on the game's display. It has its own D3D11 device and swapchain, created on WARP (software rasterizer), and it is the foreground window while you use it. NVIDIA's capture then has two windows and two swapchains in the same process, one on the landscape 2560×1440 monitor, one on the portrait monitor. This reproduces the same failure signature as the ReShade case (session bound to the wrong monitor, "Failed to fetch Current Res", instant stop) independently of ReShade. The console window (`enableConsole`, default true) is a third top-level window of the process, also on the primary display.
2. **No new conflict with ReShade's hooks.** The plugin loads as `version.dll`, so there is no file-name clash with ReShade's `dxgi.dll`/`d3d11.dll`. ReShade sees the plugin's device creation, logs "Skipping device because the driver type is 'D3D_DRIVER_TYPE_WARP'", and does not proxy that device or its swapchain, so no second ReShade runtime appears in the plugin window. Both use MinHook, but ReShade registers DLL-load notifications instead of detouring `LoadLibraryW`, so the two detours do not stack.
3. **Procedure changes.** The plugin blocks every `Screen.SetResolution` call from the game after the first one, so in-game resolution and fullscreen changes silently do nothing while the plugin is loaded. Fullscreen and resolution must be set through `scsp-config.json` `startResolution` or the plugin GUI "Update Resolution". Steps 1 and 6b of `FIX-PROCEDURE.md` depend on this.

## What the plugin does, verified in source

| Behaviour | Where | Relevance |
|---|---|---|
| Loads as a `version.dll` export proxy, forwards to `System32\version.dll`. | `src/dllproxy/proxy.cpp` | No name collision with ReShade. Loads before ReShade because `version.dll` is imported at process start while Unity loads `d3d11.dll`/`dxgi.dll` later. |
| Only activates when the exe is `imasscprism.exe`; starts a detached init thread; MinHook `LoadLibraryW` detour that patches `NPGameDLL.dll` and triggers IL2CPP hooking when `cri_ware_unity.dll` loads. | `src/main.cpp:329-398`, `src/hook.cpp:420-444`, `4018-4036` | Detour chain with ReShade is not an issue: ReShade uses `LdrRegisterDllNotification` first and only detours `LoadLibraryW` if that registration fails (`hook_manager.cpp:526-542`). The plugin restores original bytes for all its hooks only at process detach. |
| Subclasses the game window (`UnityWndClass`/`imasscprism`) with `SetWindowLongPtr(GWLP_WNDPROC)`; swallows `WM_KILLFOCUS` and `WM_NCACTIVATE(FALSE)` unconditionally (the `blockOutOfFocus` config value is read but never used); handles `WM_INPUT` raw mouse for the free camera; `WM_CLOSE` terminates the process. | `src/mhotkey.cpp:67-181` | The game never learns it lost focus. DXGI's own window subclass (installed at swapchain creation, so beneath the plugin's) is what switches exclusive fullscreen out on focus loss; with these messages swallowed the game stays fullscreen while the plugin GUI has focus. That is the intended feature. It does not change the OS foreground window, which is what NVIDIA's overlay keys on. |
| Ctrl+`hotKey` (default `u`) starts a thread running `guimain()`: registers class "iM@S SCSP Localify", creates window "iM@S SCSP GUI" (`WS_OVERLAPPEDWINDOW`, 630×810 at (100,100)), creates `D3D11CreateDeviceAndSwapChain` with `D3D_DRIVER_TYPE_WARP` (hardware only if WARP returns `DXGI_ERROR_UNSUPPORTED`), swapchain `DISCARD`, 2 buffers, windowed, `Present(1,0)` loop; destroys everything when the window closes. `attachToGame` overlay mode is hard-coded off. | `src/hook.cpp:690-700`, `src/scgui/scGUIMain.cpp:64-243`, `247-278` | Second window and second swapchain in the game process, on the primary monitor, software-rendered. See conflict 1. |
| Hooks Unity `Screen.SetResolution`: first call is replaced by `startResolution` from config (or the game's own values), every later call from the game is dropped (`return;`). The GUI's "Update Resolution" and "Swap" buttons call the original directly. | `src/hook.cpp:1886-1899`, `src/scgui/scGUILoop.cpp:662-675` | In-game display settings stop working. See procedure changes. |
| `AllocConsole()` at load when `enableConsole` is true (default). | `src/main.cpp:95-111`, `353-357` | Extra top-level window of the process on the primary display. |
| Steam client and overlay loading code exists but is never called. | `src/steam/steam.cpp` | Dead code, no Steam overlay is injected by the plugin. |
| No hooks on `Present`, `CreateSwapChain`, `CreateDXGIFactory`, `SetWindowDisplayAffinity`, or any DXGI/D3D symbol. | grep of `src/` excluding `imgui/` | The plugin does not touch the game's swapchain. NVIDIA and ReShade interactions are entirely through the extra window and device. |

## Conflict 1 in detail: the GUI window and NVIDIA PID capture

NVIDIA's overlay identifies the game by process and by the foreground window and rendering surface it observes in that process (section 2 of `README.md`). With the plugin GUI open:

- The foreground window belongs to the game process but sits on the primary (landscape) monitor.
- The process now presents two swapchains: the game's on the NVIDIA adapter, and the GUI's on the Microsoft Basic Render Driver (WARP). NvFBC cannot capture a WARP surface at all.
- NVIDIA's default output tracking falls back to the primary output when it cannot resolve the display from the surface (public NvFBC header, `NVFBC_TRACKING_DEFAULT`).

Any of those three is enough to bind the session to the 2560×1440 display and fail the first frame exactly as in the ReShade case. Closing the GUI window destroys the device and swapchain (`guimain` cleanup), which removes the trigger, but the plugin keeps the class registered and the next Ctrl+U recreates the window at the same absolute position.

The included patch `patches/scsp-localify-gui-window-on-game-monitor.patch` (37 lines, `src/scgui/scGUIMain.cpp`, verified to apply to commit 3890f84) places the GUI window centred on the monitor that contains the game window, clamps it to that monitor's work area (portrait displays are narrow), and remembers the last position after the user moves it. With the patch, both windows of the process live on the portrait display, which removes the display ambiguity. It does not change the WARP device; if recording still fails only while the GUI is open, the second swapchain itself is the trigger and the GUI must simply be closed before Alt+F9.

## What does not conflict, verified

- **ReShade and the WARP device.** `D3D11CreateDeviceAndSwapChain` is hooked by ReShade, but for `D3D_DRIVER_TYPE_WARP` it does not create a device proxy (`d3d11.cpp:148-153`), and the swapchain creation then goes through `query_device`, which finds no proxy and logs "Skipping swap chain because it was created without a proxy Direct3D device" (`dxgi.cpp:294-316`, `381-384`). No ReShade runtime, overlay, or effect is attached to the plugin window. The only visible trace is those two lines in `ReShade.log` each time the GUI opens.
- **Hardware fallback.** If WARP creation ever fails with `DXGI_ERROR_UNSUPPORTED`, the plugin retries with `D3D_DRIVER_TYPE_HARDWARE`. That device would be proxied and ReShade would open a second runtime in the plugin window (ReShade overlay and effects drawn into the GUI). WARP is part of Windows 8 and later, so this path is not expected on this machine; check `ReShade.log` for a second "Redirecting D3D11CreateDeviceAndSwapChain" block with `DriverType = 1` if the plugin window ever shows ReShade's overlay.
- **Input.** ReShade hooks `RegisterRawInputDevices` and `SetWindowsHookEx` (`input_windows.cpp:578`, `801`, `850`). The plugin uses neither; it reads `WM_INPUT` in its window subclass. When ReShade's overlay is open and set to block input, the game window does not receive those messages, so the free camera stops responding until ReShade's overlay closes. That is the normal ReShade behaviour, not a defect.
- **Hotkeys.** NVIDIA's Alt+F9 and Alt+Z are `WM_SYSKEYDOWN` with virtual keys outside 'A'..'Z', which the plugin's hotkey filter ignores (`mhotkey.cpp:136-146`). The plugin's Ctrl+U does not collide with any NVIDIA or ReShade default binding.
- **Module name.** Nothing in the plugin resolves or replaces `dxgi.dll`, so the ReShade DLL-rename step (6a) is unaffected.

## Required changes to the fix procedure when the plugin is installed

1. **Baseline first.** Run Step 0 with the plugin also removed (rename `version.dll` to `version.dll.off`) so the three-way combination is separated: game alone, game+ReShade, game+plugin, game+both.
2. **Close the GUI before recording.** Press Ctrl+U to close the plugin window, click the game window, then press Alt+F9. Also set `"enableConsole": false` in `scsp-config.json` for the tests so the console window is not present.
3. **Set fullscreen through the plugin, not the game.** For Step 1 (exclusive fullscreen) and Step 6b, set `startResolution` in `scsp-config.json` to `{"w": 2160, "h": 3840, "isFull": true}` (or use "Update Resolution" in the GUI, then close the GUI). Unity's `Screen.SetResolution(..., true)` uses the project's fullscreen mode, which on Windows defaults to borderless "FullScreenWindow"; if the NVIDIA KB fix needs exclusive fullscreen and the game does not offer it, add the Unity player argument `-window-mode exclusive` to the launch command (Unity 2019.1 and later), and `-monitor N` to pin the game to the portrait display. The plugin can print the launch command with `"showStartCommand": true`; note that it contains the personal login token, so do not share that output.
4. **Apply the GUI patch** if you need the plugin window open while recording (for example to drive the free camera during a take). Build with the repository's `generate.bat` and Visual Studio 2022 as described in `readme_EN.md`.
5. **Diagnostics.** `tools/Collect-NvCaptureDiag.ps1 -GameExe imasscprism.exe` lists loaded modules; expect `version.dll` from the game folder and, while the GUI is open, `d3d10warp.dll`. Two `IDXGISwapChain` creations will be visible in `ReShade.log`.

## Fork versus upstream: device creation order matters

Upstream `chinosk6/scsp-localify` (10abb3e, 2026-08-01) creates the GUI device with `D3D_DRIVER_TYPE_HARDWARE` first and falls back to WARP. The `dar4545` fork (3890f84) reverses this: WARP first, hardware only on `DXGI_ERROR_UNSUPPORTED`. Keep the fork's order. With upstream's order:

- ReShade proxies the hardware device and its swapchain, so a second ReShade runtime opens inside the plugin window (ReShade's overlay and effects drawn on the GUI, ReShade's input hooks on that window).
- NVIDIA's overlay sees a second swapchain on the NVIDIA adapter in the same process, which is a stronger wrong-surface candidate for PID capture than a WARP swapchain it cannot capture anyway.

## Community evidence (searched 2026-09-05)

- No issue, discussion, or forum post was found that pairs scsp-localify, or its sibling projects sharing the same GUI code (umamusume-localify, gakuen-imas-localify), with ReShade, NVIDIA overlay or ShadowPlay, Steam overlay, OBS, or multi-monitor problems. Searches covered GitHub issues and discussions of the upstream repository and both siblings, and English, Chinese and Japanese web queries. This is a low-traffic project, so absence of reports is weak evidence either way.
- The closest data point is upstream issue #118 "Failed to start control GUI" (opened 2026-08-19, open, undiagnosed): pressing Ctrl+U logs "GUI START", repeated "init D3D failed", "GUI END". That is the exact log path when `D3D11CreateDeviceAndSwapChain` fails in `CreateDeviceD3D`. Nobody in the thread names a cause. If the GUI fails to open on a machine that also runs ReShade or the NVIDIA overlay, that issue is the place to compare notes; the `ReShade.log` lines around the second device creation will say whether ReShade was in the call path. https://github.com/chinosk6/scsp-localify/issues/118
- No PCGamingWiki entry exists for the game, so the renderer (D3D11 vs D3D12) and Unity swap-effect settings could not be confirmed from public sources. `ReShade.log` records both at startup (the "Redirecting D3D11CreateDeviceAndSwapChain" block and the swapchain description dump), which the diagnostic collector copies.

## Confidence

| Claim | Confidence |
|---|---|
| Plugin does not hook any DXGI/D3D/Present symbol; only extra window, WARP device, window subclass, resolution hook | High, verified in source |
| ReShade skips the WARP device and its swapchain | High, verified in ReShade source |
| No `LoadLibraryW` detour stacking with ReShade | High, ReShade source; note ReShade falls back to a detour only if DLL notification registration fails |
| Open GUI window on the other monitor triggers the same NVIDIA wrong-display failure | Medium (no public report either way): consistent with NVIDIA's documented fallback behaviour and with the mechanism in `README.md`, not yet reproduced on this machine; test with the GUI open vs closed |
| Console window alone triggers it | Low; included only because it is cheap to exclude |
| `SetResolution` block makes in-game display settings inert | High, verified in source |
