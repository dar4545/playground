# NVIDIA In-Game Overlay recording fails when ReShade is active (multi-monitor, portrait game display)

Research and root-cause analysis, 2026-09-04.

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

## 7. Ordered isolation tests

Run in this order. Each test changes one variable and has a decisive outcome.

| # | Test | If recording now works | If it still fails |
|---|---|---|---|
| T1 | Rename ReShade's `dxgi.dll` to `d3d11.dll` (or `d3d12.dll` for a D3D12 game) so the game directory no longer contains a module named `dxgi.dll`. Keep everything else identical. | NVIDIA's component was resolving DXGI by module name and hitting ReShade's exports. Permanent workaround found. | Module name is not the trigger; proceed to T2. |
| T2 | Make the portrait monitor the Windows primary display and the NVIDIA Control Panel primary (asterisk in "Set up multiple displays"). | The fallback path binds to the primary output. Confirms the KB 5164 class of bug is the second half of the chain. | Fallback is not "primary"; may be "first enumerated output". Try physically swapping the two monitors' connector order and repeat. |
| T3 | Temporarily disconnect or disable the 2560×1440 monitor, leaving only the portrait one. | Wrong-output selection confirmed as the failure point. | Something other than output choice is failing; collect logs (section 9) before continuing. |
| T4 | Force the opposite fullscreen mode with the game's own settings (exclusive fullscreen vs borderless). If the game has no option, use ReShade's Swapchain Override add-on `ForceWindowed`/`ForceFullscreen` for this test only. | The two modes take different association paths inside NVIDIA's capture. Use the working mode. | Presentation mode is not the differentiator. |
| T5 | Set the game monitor to landscape orientation for one run (game at 3840×2160). | Rotation is part of the trigger. Report to NVIDIA with logs. | Rotation is irrelevant; the problem is purely output selection. |
| T6 | Inject ReShade without a proxy DLL: use a global injector that loads `ReShade64.dll` by its own name after the game starts, with no `dxgi.dll` in the game folder. | Confirms T1's conclusion from a second angle. | ReShade's proxy objects themselves, not the module name, are the trigger. Only NVIDIA can fix that; use section 8 workarounds. |

## 8. Workarounds, with evidence quality

1. **Rename ReShade's DLL** (T1). Documented and widely used ReShade compatibility technique for injector conflicts (https://reshade.me/forum/troubleshooting/5309-dxgi-dll-and-d3d11-dll-not-working-together , https://reshade.me/forum/troubleshooting/6058-can-i-rename-dll-files). Not yet verified against this specific NvFBC failure. Anti-cheat titles may reject the renamed module.
2. **Make the portrait monitor the primary display** (T2). This is the workaround NVIDIA and multiple independent users give for the KB 5164 wrong-screen bug.
3. **Switch the NVIDIA overlay to desktop capture** for this game: Alt+Z, Settings, Privacy control, enable "Desktop capture". This makes NVIDIA use an output-tracking session on the display rather than a PID session, and it still records ReShade's effects because they are in the presented frame. It records the whole monitor, including any overlays.
4. **Keep display topology stable.** DisplayPort hot-plug and monitor sleep re-enumerate the topology and are independently reported to make ShadowPlay lose the correct monitor (https://blog.cover1sea.net/pc/4453/). Match HDR state across both monitors; mixed HDR is reported to cause instant-stop recordings (https://favorite-fashion.com/blog101/).
5. **Use ReShade's Vulkan layer path** if the game has a Vulkan renderer. Vulkan ReShade installs as a system-wide layer and does not proxy DXGI at all (https://reshade.me/forum/troubleshooting/7361-reshade-and-dxvk-dxgi-dll-on-windows).
6. **Fall back to OBS Game Capture.** Repeatedly recommended on the ReShade forum as the reliable way to record ReShade output when injector ordering fights with ShadowPlay. Multiple independent reports.

Workarounds 1 and 3 are the cheapest and should be tried first.

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
| ReShade's proxy identity is what diverts NVIDIA onto the failing fallback path | Medium, consistent with all evidence, no direct public report; T1 and T6 decide it |
| Portrait rotation is itself part of the trigger | Low, no evidence either way; T5 decides it |

## 11. Sources

- NVIDIA KB 5164, "GeForce Experience Shadowplay may intermittently record the wrong screen in multi-monitor configurations", 2021-10-05: https://nvidia.custhelp.com/app/answers/detail/a_id/5164
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
