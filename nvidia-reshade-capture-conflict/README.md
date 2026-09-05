# NVIDIA In-Game Overlay recording fails when ReShade is active (multi-monitor, portrait game display)

Research and root-cause analysis, 2026-09-04.

Files in this directory:

| File | Purpose |
|---|---|
| `FIX-PROCEDURE.md` | The reproducible step-by-step procedure. Start there. |
| `PLUGIN-scsp-localify.md` | Whether adding the scsp-localify plugin (second GUI window, own WARP D3D11 device) creates new conflicts, and what changes in the procedure. |
| `patches/scsp-localify-gui-window-on-game-monitor.patch` | Plugin patch: open its GUI window on the monitor that holds the game window instead of absolute coordinates on the primary display. |
| `patches/reshade-dxgi-factory-vtable-hooks-option.patch` | Source fix for ReShade 6.6.0 and later: auto-select vtable factory hooks when the NVIDIA overlay is loaded, plus an `[APP] DXGIFactoryVTableHooks` override. Verified to apply to v6.8.0 and main. |
| `tools/Collect-NvCaptureDiag.ps1` | Collects display topology, NVIDIA and ReShade logs, registry and loaded modules. |
| `tools/Set-NvCaptureWorkaround.ps1` | Applies or reverts each workaround with backups. |
| `README.md` | This analysis and the evidence behind it. |

## 0. The ReShade version boundary (added after source-history review)

ReShade's DXGI hooking changed between 6.5.1 and 6.6.0, verified from the git history of `crosire/reshade`:

| Tag | Date | Factory | Adapter | Swapchain |
|---|---|---|---|---|
| v6.5.1 | 2025-06-08 | real object, vtable-hooked | real object | ReShade proxy |
| v6.6.0 and later | 2025-09-26 | ReShade proxy (commit d43daf0, 2025-06-20) | ReShade proxy (commit 3adf9c5, 2025-08-20) | ReShade proxy |

The 6.6.0 commit message says why: "NVIDIA Smooth Motion creates vtable hooks that intercept swap chain creation requests from the application. By using a proxy DXGI factory, commands from the application will reach ReShade first". In other words, NVIDIA driver code inside the game process vtable-hooks whatever DXGI factory it sees, and since 6.6.0 the app-side factory it sees is ReShade's. An `IDXGIOutput` proxy also existed between 2025-08 and 2025-09-11 and was removed as unused (commit 66184d7). ReShade's own code notes that DXGI-internal code crashes when it reaches a proxied adapter through device-to-adapter navigation (`source/d3d11/d3d11_device.cpp:118-126`).

ReShade still contains the vtable-hook path and switches to it automatically when the Ubisoft Connect overlay module is present (`source/dxgi/dxgi.cpp`, `use_dxgi_factory_vtable_hooks`). The patch in this directory adds the NVIDIA capture module and a configuration override to that switch. Step 4 of the procedure (install 6.5.1) tests this hypothesis directly without building anything.

## 1. Symptom under investigation

- Game runs fullscreen on a portrait monitor, desktop resolution 2160×3840. A second landscape monitor is 2560×1440.
- With ReShade loaded, pressing Alt+F9 shows "Recording has started" and immediately "Saving recording". No file is written.
- NVIDIA's log shows the process, the render surface, the AV1 encoder and the output path are all set up. The NvFBC PID-capture session is then bound to the 2560×1440 monitor, not the portrait one, and the first grab fails:

```
CaptureFrame failed 0x7
NVFBC_ERROR_INVALIDATED_SESSION
Failed to fetch Current Res
```

- Without ReShade the same recording works. Disabling every ReShade add-on and running core ReShade alone does not help.

## 2. Short answer

The evidence supports a two-part cause, not a single ReShade bug:

1. **NVIDIA already has a known, acknowledged wrong-monitor bug in multi-monitor setups.** NVIDIA knowledge-base article 5164 states that changes to the Windows Video Present Network (VidPN) manager in Windows 10 20H1 and later can make ShadowPlay "record the wrong screen in multi-monitor system configurations". Independent user reports (NVIDIA forums, Japanese troubleshooting blogs) describe the same wrong-screen or instant-stop behaviour with no ReShade involved. The portrait-plus-landscape, mixed-resolution layout here is exactly the kind of topology that bug covers.

2. **ReShade changes which NVIDIA code path is used to associate the game with a display, and that second path is the one that hits the bug.** ReShade does not rewrite any output or monitor information (verified in source, section 4). What it does change is object identity: the game, and anything hooking inside the game process, sees ReShade's proxy `IDXGIFactory`, `IDXGIAdapter` and `IDXGISwapChain` objects instead of the driver's own. When the driver's PID-capture logic cannot match the presenting surface to a VidPN source by the normal direct route, it falls back to a topology heuristic (primary display or first enumerated output), which on this machine is the 2560×1440 monitor. The session is then validated against a 2160×3840 surface, the resolution check fails ("Failed to fetch Current Res"), and NvFBC reports `NVFBC_ERROR_INVALIDATED_SESSION` (error 7), which NVIDIA uses generically for "the output this session is bound to no longer matches reality".

The rest of this document gives the evidence, the exact ReShade code involved, what is still unproven, and an ordered set of tests and workarounds.

## 3. What the error codes mean

| Log line | Meaning | Source |
|---|---|---|
| `NVFBC_ERROR_INVALIDATED_SESSION` (0x7) | The capture session was invalidated by a display topology, mode, or resolution change, or by the tracked output disappearing. A Moonlight/GameStream bug report shows the same chain: display topology change, capture resolution drops to 0×0, then `NVFBC_ERROR_INVALIDATED_SESSION`. A second display that was plugged in but off was enough to trigger it. | https://github.com/moonlight-stream/nvidia-gamestream-issues/issues/34 , https://forums.developer.nvidia.com/t/nvfbc-error-invalidated-session/162347 |
| `Failed to fetch Current Res` | Not a public API string. It comes from NVIDIA's internal CaptureCore/ShadowPlay logging. The public NvFBC status call reports per-output width, height and refresh; this line is most plausibly that query failing against the wrongly bound output. Inference, not verified. | Public `NvFBC.h` in https://github.com/LizardByte/Sunshine/blob/master/third-party/nvfbc/NvFBC.h |
| `CaptureFrame failed 0x7` | The first frame grab returning the invalidated-session code above. | same |

Two important caveats about NvFBC on Windows:

- NVIDIA froze the public NvFBC SDK for Windows at Capture SDK 7.1 and only supports it up to Windows 10 1803 (Technical Bulletin TB-09382-001, October 2021). Current ShadowPlay / NVIDIA App capture on Windows therefore runs on an internal engine that shares NvFBC error names. The public header's output-tracking semantics (`NVFBC_TRACKING_DEFAULT` "tries to track a connected primary output, falls back to the first connected output or entire screen") describe design intent, not the exact Windows PID-capture code. That default behaviour is nevertheless a precise match for "bound to the primary/first output instead of the game's output".
- No NVIDIA document was found that states a limitation for rotated or portrait outputs. Absence of documentation is not proof that rotation is handled correctly on every path.

## 4. What ReShade actually does to DXGI (verified in source, `crosire/reshade` main branch)

Files read directly: `source/dxgi/dxgi.cpp`, `dxgi_factory.cpp`, `dxgi_adapter.cpp`, `dxgi_swapchain.cpp`.

What ReShade does **not** do:

- `DXGISwapChain::GetContainingOutput` is a one-line pass-through to the original swapchain (`dxgi_swapchain.cpp:471`).
- `DXGISwapChain::GetHwnd` and `GetCoreWindow` pass through (`dxgi_swapchain.cpp:537`).
- `DXGIAdapter::EnumOutputs` passes through and there is no `IDXGIOutput` proxy class anywhere in the DXGI layer. ReShade never rewrites monitor handles, desktop coordinates, rotation, or mode lists.
- `ResizeTarget` passes through.
- With no add-on loaded, the swapchain description reaches the driver unchanged. `modify_swapchain_desc` only alters width, height, format, buffer count, swap effect, flags and the windowed flag when an add-on handles the `create_swapchain` event (`dxgi.cpp:74-104` and `156-191`).

What ReShade **does** do:

- Replaces the factory, adapter and swapchain COM objects with proxies. The game holds a `DXGISwapChain` proxy whose vtable lives in ReShade's module, not in `dxgi.dll`. `GetParent` returns the proxy factory and `GetDevice` returns the proxy device (`dxgi_swapchain.cpp:248-256`). The original object is reachable only through a private `IID_UnwrappedObject` query (`dxgi_swapchain.cpp:189`).
- Wraps every `Present` and `Present1` call and runs its own rendering work on the back buffer before forwarding (`dxgi_swapchain.cpp:258-293`, `549+`).
- Wraps `SetFullscreenState` and logs every call. Only when an add-on handles the `set_fullscreen_state` event does ReShade stop forwarding the call and start faking the state: `GetFullscreenState` then reports the cached value and returns the containing output as the target (`dxgi_swapchain.cpp:298-354`). Display Commander is an add-on of exactly this kind. With all add-ons removed this path is inactive, which is consistent with the user's finding that removing add-ons does not fix the recording.
- Exports `CreateDXGIFactory`, `CreateDXGIFactory1`, `CreateDXGIFactory2` from a module named `dxgi.dll` in the game directory when installed the default way. `CreateDXGIFactory2` deliberately upgrades the request to at least `IDXGIFactory2` (`dxgi.cpp:728-731`).

Consequence for capture tools: any code inside the game process that resolves DXGI by module name, or that identifies "the" swapchain by COM pointer, vtable address, or by walking `GetParent`/`GetDevice`, sees ReShade's objects. This is the only mechanism by which core ReShade with no add-ons can change what NVIDIA's in-process component observes. ReShade's author has described the ordering between ReShade and other injectors as "a gamble" (https://reshade.me/forum/troubleshooting/2061-record-gameplay-with-reshade-enabled-afterburner), and Special K's maintainers document real cases of a hook binding to the wrong or a transient swapchain ("hooks the game too fast, and ends up piggybacking on a swapchain that doesn't end up rendering anything").

## 5. Proposed failure chain

Stated as the most probable sequence. Items marked (V) are verified from source or official statements. Items marked (H) are hypotheses that the tests in section 7 are designed to confirm or refute.

1. (V) NVIDIA's overlay component is loaded inside the game process and needs to map the process's presented surface to a display so the driver-side PID capture can be bound to one VidPN source.
2. (V) Without ReShade, the game's swapchain is a native `dxgi.dll` object and the association resolves to the portrait display. Recording works.
3. (V) With ReShade, the game's DXGI objects are ReShade proxies. Output enumeration and `GetContainingOutput` still return correct data, but object identity, vtables, `GetParent`, and possibly the module answering `GetModuleHandle("dxgi.dll")` all differ.
4. (H) NVIDIA's surface-to-display match fails or is skipped on the proxied objects and the driver falls back to its default tracking rule: primary or first output. On this machine that is the 2560×1440 landscape monitor. This is the same fallback that NVIDIA KB 5164 says misfires after the Windows 20H1 VidPN changes.
5. (V) The session is created against the wrong output. The first grab validates the tracked output's current mode against the process surface (2160×3840 portrait). The values disagree, "Failed to fetch Current Res" is logged, and the session is invalidated with error 7.
6. (V) The overlay retries, tears the session down and reports "Saving recording" with nothing to save.

The portrait orientation may be an additional aggravating factor, because a rotated output's DXGI desktop rectangle (2160×3840, rotation 90) differs from its mode-list entry (3840×2160). No source confirms that NVIDIA mishandles rotated outputs, so this remains a secondary hypothesis to test separately (test T5 below).

## 6. What was searched and not found

- No issue in `crosire/reshade` matches this symptom (GitHub issue search for ShadowPlay, NvFBC, GetContainingOutput, portrait, wrong monitor returned nothing).
- No English, Chinese or Japanese thread pairs ReShade specifically with this NvFBC failure. Community consensus is that ShadowPlay usually records ReShade output fine. This means the failure is an edge case of the multi-monitor topology bug, not a general ReShade regression.
- No NVIDIA driver release note was found that lists a fix for ShadowPlay wrong-monitor capture on rotated displays.
- The exact strings "Failed to fetch Current Res" and "CaptureFrame failed 0x7" do not appear in any public ShadowPlay report; they only appear in NVIDIA developer-forum threads about the standalone Capture SDK.

## 7. Isolation tests and fixes

The ordered, reproducible procedure is in `FIX-PROCEDURE.md`. Summary of the order and why:

| Step | Change | Evidence for it |
|---|---|---|
| 1 | Overlay Privacy control: Desktop capture OFF, game in exclusive fullscreen | NVIDIA KB 5164 full text (recovered from the Wayback Machine): this is NVIDIA's own fix for wrong-screen capture in multi-monitor setups on Windows 10 20H1 and later. |
| 2 | NVIDIA App video capture Resolution: explicit value instead of "In-game" | Matches the failing log line "Failed to fetch Current Res". Single NVIDIA forum report of it fixing wrong-monitor recording. |
| 3 | Portrait monitor as primary (and NVIDIA Control Panel primary); disconnect the other monitor as a control | Repeated NVIDIA forum workaround; public NvFBC header documents default tracking as "primary output, else first output". |
| 4 | Install ReShade 6.5.1 | Version boundary in section 0: last release without proxy factory and adapter objects. Decisive for the ReShade half. |
| 5 | Build current ReShade with the included patch and set `[APP] DXGIFactoryVTableHooks=1` | Restores 6.5.1 hooking behaviour on current ReShade; the code path already exists upstream for the Ubisoft overlay. |
| 6 | Rename the DLL to `d3d11.dll`/`d3d12.dll`, switch presentation mode, or use Vulkan | Renaming changes only module-name resolution, not object proxying (verified: proxies are created in every install mode, `dll_main.cpp:275-335`), so it ranks below the version test. |
| 8 | Desktop capture ON, or OBS Game Capture | Records ReShade output through a display-tracking session instead of PID capture. |

Notes on the earlier hypotheses:

- Module-name collision on `dxgi.dll` is now ranked low: ReShade wraps the factory, adapter and swapchain whether it is loaded as `dxgi.dll` (export proxy) or as `d3d11.dll` (function hooks on the system `dxgi.dll`). Only code that resolves `dxgi.dll` by module name would behave differently.
- The `[APP] ForceWindowed`/`ForceFullscreen`/`ForceResolution` keys live in the separately shipped Swapchain Override add-on, not in core ReShade, so they were already excluded by the user's add-on-free test.
- No ReShade changelog entry or issue mentions ShadowPlay, NVIDIA App, GeForce Experience or NvFBC. The 6.6.0 changelog entry "Reworked DXGI hooks to prefer usage of proxy classes" is the only relevant upstream change.

## 8. Additional NVIDIA-side facts found

- NVIDIA KB 5602 (2024-11-15) says Desktop capture ON can also stop recordings when copy-protected content is detected in any window, and recommends driver 551.52 or newer for NVIDIA App overlay features.
- The Desktop capture toggle is stored at `HKCU\SOFTWARE\NVIDIA Corporation\Global\ShadowPlay\NVSPCAPS`, values `DwmEnabled` and `DwmEnabledUser` (4-byte binary). Confirmed by registry diff on Stack Overflow and an ASUS forum thread.
- One NVIDIA forum report states that GPU output port order, not the Windows primary setting, decided which monitor ShadowPlay captured. The procedure includes a cable swap for that case.
- DisplayPort hot-plug and monitor sleep re-enumerate the topology and are independently reported to make ShadowPlay lose the correct monitor (https://blog.cover1sea.net/pc/4453/). Mixed HDR state across monitors is reported to cause instant-stop recordings (https://favorite-fashion.com/blog101/).
- `nvspcap64.dll` is the NVIDIA capture library injected into the game by the NVIDIA container service. No public write-up documents how it resolves DXGI or identifies the swapchain; that remains unverified.

## 9. Logs to collect if reporting to NVIDIA or ReShade

- `C:\ProgramData\NVIDIA Corporation\ShadowPlay\CaptureCore.log`. This is where NVIDIA's internal capture engine logs session binding, the chosen output, and protected-content blocks (format confirmed in https://github.com/Verpous/AlwaysShadow/issues/20). Capture one run with ReShade and one without and diff the output-selection lines.
- `ReShade.log` in the game directory. ReShade dumps the full swapchain description at creation (`dxgi.cpp:228-246`): width, height, refresh rate, format, buffer count, windowed flag, swap effect and flags. Confirm the windowed flag and swap effect match the no-ReShade run, and check whether any "Redirecting IDXGISwapChain::SetFullscreenState" line appears.
- Windows build number. NVIDIA attributes the wrong-screen bug to VidPN changes in 20H1 and later.
- NVIDIA App and driver versions for both the failing and any passing configuration.

## 10. Confidence summary

| Claim | Confidence |
|---|---|
| ReShade does not rewrite output, monitor, rotation or mode data | High, verified in source |
| Core ReShade without add-ons leaves the swapchain description unchanged | High, verified in source |
| ReShade replaces the COM identity of factory, adapter and swapchain | High, verified in source |
| NVIDIA has an acknowledged multi-monitor wrong-screen capture bug tied to Windows VidPN changes | High, official KB title and summary, plus independent reports |
| Error 7 means the tracked output no longer matches the capture source | High, multiple independent NvFBC consumers |
| ReShade 6.6.0 introduced proxy factory and adapter objects; 6.5.1 did not | High, verified in git history and tags |
| NVIDIA driver code vtable-hooks the DXGI factory it observes in-process | High, stated in ReShade commit d43daf0 and source comment |
| ReShade's proxy factory/adapter objects are what divert NVIDIA onto the failing fallback path | Medium, consistent with all evidence, no direct public report; Step 4 of the procedure decides it |
| Disabling Desktop capture plus exclusive fullscreen fixes wrong-screen capture | High as NVIDIA's official guidance; untested on this exact machine |
| Portrait rotation is itself part of the trigger | Low, no evidence either way |

## 11. Sources

- NVIDIA KB 5164, "GeForce Experience Shadowplay may intermittently record the wrong screen in multi-monitor configurations", updated 2021-03-05: https://nvidia.custhelp.com/app/answers/detail/a_id/5164 (full text via http://web.archive.org/web/2023id_/https://nvidia.custhelp.com/app/answers/detail/a_id/5164)
- NVIDIA KB 5602, "NVIDIA App Instant Replay -> Desktop capture does not start or stops recording", 2024-11-15: https://nvidia.custhelp.com/app/answers/detail/a_id/5602
- NVSPCAPS registry values for Desktop capture: https://stackoverflow.com/questions/66362524/ and https://rog-forum.asus.com/t5/rog-gaming-notebooks/enable-shadowplay-to-record-your-desktop/td-p/560358
- ReShade commit d43daf0 "Rework DXGI factory hooks to use a proxy class (#359)", 2025-06-20: https://github.com/crosire/reshade/commit/d43daf0a9ef3b375cc0578c7147506a7fdd90396
- ReShade commit 3adf9c5 "Add DXGI adapter proxy to track swap chain creation (#369)", 2025-08-20; commit 66184d7 "Remove unused IDXGIOutput proxy class", 2025-09-11
- ReShade 6.6 release notes ("Reworked DXGI hooks to prefer usage of proxy classes"): https://reshade.me/releases/10138-6-6
- ReShade 6.5.1 installer (official archive): https://reshade.me/downloads/ReShade_Setup_6.5.1.exe
- NVIDIA Technical Bulletin TB-09382-001, NvFBC Windows 10 support: https://developer.download.nvidia.com/designworks/capture-sdk/docs/NVFBC_Win10_Deprecation_Tech_Bulletin.pdf
- NVIDIA developer forum, NVFBC_ERROR_INVALIDATED_SESSION: https://forums.developer.nvidia.com/t/nvfbc-error-invalidated-session/162347
- NVIDIA developer forum, fullscreen capture issue (NvFBC session bug acknowledged): https://forums.developer.nvidia.com/t/fullscreen-video-capture-issue/162382
- Moonlight GameStream issue showing topology change to invalidated session: https://github.com/moonlight-stream/nvidia-gamestream-issues/issues/34
- Public NvFBC header (tracking types): https://github.com/LizardByte/Sunshine/blob/master/third-party/nvfbc/NvFBC.h
- ReShade source, DXGI layer: https://github.com/crosire/reshade/tree/main/source/dxgi
- ReShade forum, injector ordering "a gamble": https://reshade.me/forum/troubleshooting/2061-record-gameplay-with-reshade-enabled-afterburner
- ReShade forum, DLL renaming: https://reshade.me/forum/troubleshooting/5309-dxgi-dll-and-d3d11-dll-not-working-together
- ReShade forum, Swapchain Override add-on: https://reshade.me/forum/addons-discussion/9631-how-to-use-swapchain-override-add-on
- ReShade forum, Vulkan layer vs local DXGI: https://reshade.me/forum/troubleshooting/7361-reshade-and-dxvk-dxgi-dll-on-windows
- Microsoft DirectX samples, GetContainingOutput adapter/output mismatch: https://github.com/microsoft/DirectX-Graphics-Samples/issues/865
- Special K, ReShade coexistence: https://wiki.special-k.info/en/SpecialK/ReShade
- Special K, NieR:Automata FAR swapchain identity notes: https://wiki.special-k.info/SpecialK/Custom/FAR
- AlwaysShadow issue showing CaptureCore.log location and format: https://github.com/Verpous/AlwaysShadow/issues/20
- Japanese report, Instant Replay recording the sub-monitor after DisplayPort re-enumeration: https://blog.cover1sea.net/pc/4453/
- Japanese report, instant-stop recordings with mixed HDR monitors: https://favorite-fashion.com/blog101/
- NVIDIA forum threads (content behind JS, titles confirmed): https://www.nvidia.com/en-us/geforce/forums/instant-replay-recording/15/394211/ , https://www.nvidia.com/en-us/geforce/forums/geforce-experience/14/259542/
