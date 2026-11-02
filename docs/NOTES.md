# Notes

## Toolchain (M0)
- Zig 0.17.0 (winget `zig.zig`). `@cImport` is gone in 0.17; use `b.addTranslateC` or plain `extern fn` declarations.
- Python: repo-local `.venv` (uv, Python 3.14.7, capstone 5.0.7). Not 3.12; capstone is ctypes-based so the version does not matter.
- All 61 Windows toolkit C files build under `zig cc` (`x86_64-windows-gnu`) with no toolkit patches.
- xboxrecomp's `nv2a_pb_replay.c` references another game's symbols (`g_suppress_present`, `g_fe_cursor`, `fe_menu_get_pb_state`); stubbed in `src/main.zig`.

## Game data
- `default.xbe` SHA-1 `abf12bb66fcbd9f694c223419a2309c1a5f72293`, 1,921,024 bytes, sector 1714694.
- ISO unpacked with `zig build unpack -- <iso> game` (`src/xiso.zig`, Zig port of the toolkit's xdvdfs.py): 1577 files, 2.2 GB.
- XBE header confirmed: base 0x10000, entry 0x000E43B7, kernel thunk 0x00173DE0 (115 entries), title ID 0x46530002, 12 sections.

## REA
- REA on Windows cannot open XBE: Ghidra provider accepts only PE (and raw 6502); raw-binary x86 is rejected. Header was decoded by hand instead.
- For M3 static analysis use the ghidra-mcp server with an XBE loader, or a PE wrapper of the XBE.

## Lift (M1)
- Pipeline, run from `xboxrecomp/` with `../.venv/Scripts/python -m tools.<step>`:
  `xbe_parser ../game/default.xbe --json ../game/otogi_analysis.json`, `disasm ../game/default.xbe -v`,
  `func_id`, `abi_analysis`, `recomp ../game/default.xbe --all --split 250 --gen-dir ../src/recomp/gen`.
- Do not pass `--text-only` to disasm: Otogi's D3D/D3DX/XGRPH/DSOUND/XMV/XPP sections are code the game calls.
  Full run: 6231 functions (.text 4709, DSOUND 506, D3DX 430, D3D 289, XPP 198, XMV 71, XGRPH 28).
  `--text-only` reports 5067 in .text; the full run drops ~360 of those. Worth checking if M2 hits missing functions.
- recomp: 6232/6232 translated, 0 failed, ~720k lines in 25 files (29 MB). Builds under `zig cc` in ~30 s.
- 78 untranslated instructions (20 mnemonics). The lifter emits `recomp_unimpl()` for each, so any that run are logged.
  Classified by containing function:
  - Data lifted as code, never called: `sub_00155118` (100 KB in XMV) and `sub_00154FE0` (daa/aaa/das/aas/clts/lldt/lsl).
  - Jump-table bytes after a final `jmp`, so unreachable: `sub_000CF460`, `sub_000EB0D0`, `sub_0011620A`, `sub_0011D415`.
  - Real, harmless as no-ops: `cli`/`sti` in `sub_000E5E7D`, `wbinvd` in `sub_000FFAB0` (D3D).
  - Real, needs an override in M2: `sub_000E88E4` does `sgdt` and a far jump (writes a GDT entry).

## Boot (M2)
- Re-lift after changing `seeds/manual.h` (replaced and wrapped functions; see its header):
  `recomp ../game/default.xbe --all --split 250 --gen-dir ../src/recomp/gen --exclude-manual ../seeds/manual.h` (~40 s).
  Overrides live in `src/manual.zig` and `src/gl_hle.zig` as `export fn sub_XXXXXXXX`.
- `build.zig` sets `sanitize_c = .off`: Zig Debug enables UBSan for C, and its alignment check fires on 4-byte-aligned guest structs.
- Log: `logs\otogi.log` (stdout and stderr). Watchdog: `RECOMP_WATCHDOG_SECS=N` prints guest regs and stack.
- Fixes, in boot order:
  1. `sub_000E571D` (XAPI DVD media check) returns success. Cert+0x1D8 bit 0 asks for the security sector (READ DVD STRUCTURE), which an ISO lacks; it retried 5x and rebooted to the dashboard.
  2. `RECOMP_ASYNC_IO` on by default (`main.zig`). The stream loader `sub_0007BDD0` reads overlapped and only fills the byte count on ERROR_IO_PENDING; a synchronous completion read as 0 bytes, E_FAIL, and the disc-error loop `sub_000137D0`.
  3. `sub_000FA2A0` (D3D BlockOnTime): GPU semaphore (device+0x30) points at the fence counter (device+0x2C), so every fence reads as done. Device pointer is at `0x1051C8`.
  4. `RECOMP_VBLANK` on by default; vblank interrupts come from the toolkit tick (~40 Hz, 600 in 15 s).
  5. `sub_000C81A0` (per-frame XMV step) returns "movie ended". XMV's clock (`sub_00146D25`) stays 0 until its decode/audio pipeline starts the clock, so it would Sleep(2) forever. M4 replaces this.
  6. XAPI input HLE: XInitDevices `sub_0016E924`, XGetDevices `E929`, XGetDeviceChanges `E94B`, XInputOpen `EA1A`, XInputClose `EA70`,
     XInputGetCapabilities `EA7C`, XInputGetState `EC54`, XInputSetState `ECC7` (`0x16DB4C` = gamepad type). They feed
     `usb_gamepad_report` (host XInput pad, keyboard, `RECOMP_PAD_SCRIPT`). Port 0 only; it "arrives" on the first
     XGetDeviceChanges, as on hardware. XAPI's own USB stack hung, then crashed in `sub_000DB930`, on the toolkit OHCI model.
  7. `RECOMP_AC97_READY` on by default. Without DirectSound the game never starts its sound-stream worker
     (`sub_00072DA0`, started through vtable `0x18432C`+4), and the main menu spins in `0x78037` waiting on it.
- Exit check passes: `RECOMP_PAD_SCRIPT=2000:start,4000:start,7000:a,9000:a,...` reaches stage m000
  (`map\m000\map.dat`, `chr\c000.dat`); 70 s, no crash. Idle (no input) runs the title/attract loop.
- Missing on disc too (the game probes them): `sfx\s000_00.dds` etc., `media\distortion.dds`.
- Unhandled but harmless so far: `cli`/`sti` at `0x00171BA5`/`0x00171BB6` (XPP USB code).

## Renderer (M3)
- XDK symbols: `XbSymbolDatabaseCLI.exe game/default.xbe -e > analysis/xbsymbol/xbsymbol.txt` (CLI from the Sneak King
  toolkit; allowed in `.claude/settings.local.json`). It names every D3D entry point and `D3D_g_RenderState` `0x104F30`,
  `D3D_g_DeferredTextureState` `0x104D30`, `D3D_g_pDevice` `0x1051C8`. Render-state indices match XDK 5849.
- REA: `zig build pe -- game/default.xbe analysis/rea/default_flat.exe` wraps the XBE in a PE32 that REA's Ghidra opens
  at the XBE's own addresses (port of Sneak King's `xbe_to_pe.py`).
- ANGLE: `build.zig.zon` pins Sneak King's `angle-feebf60` zip (SHA-256 `ca896706...c5d7`); `zig build` installs the
  4 DLLs beside the exe. Zig unpacks it into `zig-pkg/` (gitignored).
- `src/gl_hle.zig` (GL side) and `src/d3d.zig` (guest side) port Sneak King's `gl_hle.c`/`d3d_hle_shared.h`:
  wrapped setters mirror state, draws/Clear/Swap are done in GL ES 3, GLSL is generated per state key.
- Otogi-specific:
  - Most 2D is drawn by the title itself between `BeginPush`/`EndPush`: `SET_BEGIN_END` + `INLINE_ARRAY` quads in the
    current FVF. `EndPush` decodes them.
  - Text and several effects use pixel shaders (register combiners); `CreatePixelShader` keeps each
    `D3DPIXELSHADERDEF`, translated to GLSL after the toolkit's `nv2a_combiner.c`.
  - Every menu frame `CopyRects` copies the back buffer into a 640x480 linear ARGB texture (a desaturate/tint post
    effect draws it back). The back buffer is GPU-only, so CopyRects reads it back into guest memory.
  - `SetViewport` passes 0x7FFFFFFF for "the whole target"; clamped to 640x480 as D3D does.
  - Swap is held to 60 Hz: nothing else paces it, and the title otherwise runs ~1000 fps.
  - A8 textures read RGB as 1 (as xemu); `G8B8` maps as xemu does.
- Debug knobs: `RECOMP_SHOT=<frame>,...` writes `logs\frame_N.bmp`; `RECOMP_GL_DRAWLOG=<frame>` logs that frame's draws;
  `RECOMP_GL_DUMP=1` prints each pixel-shader program's GLSL. `RECOMP_SCALE` (1-4, default 2), `RECOMP_GFX`.
- Known gaps: palettes (P8 reads white), fixed-function lighting (SetLight not identified for 5455), bump/dot texture
  modes sample as 2D, CopyRects downsamples by nearest.

## Playable (M4)
- Frame rate: CreateDevice (`0x159D0`) asks for `FullScreen_PresentationInterval` 0x80000002 (every second vblank,
  at once when late) and the game steps once per frame, so Swap is held to 30 Hz on a vblank grid. Holding 60 ran
  the game at twice its speed. `zig build` defaults to `-Doptimize=fast`: the Debug renderer could not keep up.
  `RECOMP_FPS=1` prints presents per second every 5 s.
- Input: controller only (keyboard/mouse dropped for now). The game reads its pad in `0x44060`: `(raw + 0.5) / 32767.5`,
  a 40% dead zone per axis, buttons pressed above 0x1E. Controls (Options > Controller Config, Type A): LT lock-on,
  RT dash, A jump, B small attack, X spell, Y great attack. `src/pad.zig` adapts a modern pad: LB/RB also press
  LT/RT (Otogi does not use Black/White), the right stick is inverted on both axes (Otogi orbits the camera;
  `RECOMP_CAM_INVERT=0` keeps it) and starts at the game's 40% past a 15% host dead zone. Rumble goes to the host
  pad (`XInputSetState`, motors at feedback+66).
- Audio: already worked through the emulated APU and XAudio2 (`RECOMP_AC97_READY`); title music and movie sound play.
- Saves: `xbox_path_init("game", "%LOCALAPPDATA%\Otogi")`. Create, list (with thumbnail) and load were tested.
- Movie: `otogi_us_promo.xmv` is the attract-mode trailer (title idle ~25 s), not an intro. `sub_000C81A0` now runs the
  lifted body (`RECOMP_NO_MOVIE=1` skips). It decodes to a YUY2 texture and draws it with `DrawVerticesUP` into an
  X8R8G8B8 render target, then draws that target to the screen. Needed:
  - `DrawVerticesUP` (`0xF8F80`) replaced; YUY2/UYVY textures decoded (BT.601, as xemu).
  - Offscreen render targets: each is a GL texture + FBO keyed by its Data; a texture with the same Data samples it.
    The back buffer is the surface the device sets first (`0x1067D4`; Swap rotates its Data). The old device+0x1A14
    read was garbage on 5455.
- Map meshes are recorded once at load (`BeginPushBuffer`, setters, `DrawIndexedVertices`, `EndPushBuffer`) and played
  every frame with `RunPushBuffer(pb, fixup)` (`0x254E0`). Draws are replaced, so the guest pushbuffer has no draws.
  `gl_hle.zig` records the calls on the host (state snapshot per draw; constants as pushbuffer addresses, which the
  fixup rewrites) and replays them in `RunPushBuffer`. This brought back the ground, cliffs and sky.
- Fog: with `FOGTABLEMODE` NONE the vertex program's `oFog.x` is the factor itself (Otogi writes `1 - z/70000` from
  c158); NaN reads as no fog (character shaders get c158 = -inf,NaN). A pixel shader without a final combiner gets
  D3D's default one, which applies fog. `GL_EXT_depth_clamp` is on (the NV2A clamps depth rather than clipping).
- Debug: `touch logs\drawlog` logs the next frame's draws (and clears, replays) and saves `logs\frame_N.bmp`.
- BUMPENVMAP (texture mode 6), used by the title-to-menu ripple: the previous stage's V8U8 texel read as signed
  (du, dv) even without COLORSIGN, turned by BUMPENVMAT and added to the coordinates (in texels for linear textures).
- Offscreen render targets get a depth buffer while the title passes a Z surface, and none for NULL (the movie).
- CPU: the toolkit's `nv2a_ack_thread` (`xbox_memory_layout.c`) looped on `Sleep(0)` and held a core; it now sleeps
  1 ms (toolkit patch). Found with the sampler: `type nul > logs\sample` samples every thread for 3 s and logs the
  hot functions with the nearest return address into the exe. System DLL functions get names; code in the exe
  shows as its page address (SymFromAddr does not resolve it from the sampler, not yet looked into).
- Stage 1 playtest (2026-11-01): load, fight, kill, jump, pause menu, 30 fps throughout, sound plays.
- Gaps: a pushbuffer not recorded on the host (loaded from disc) draws nothing (none seen); BUMPENVMAP_LUM and the
  dot-product texture modes still sample as 2D (none seen).

## Enhancements (M5)
- `RECOMP_SCALE` (1-4, default 2) was already done in M3: back buffer, offscreen targets, viewport and clear rects scale.
- Widescreen (hor+, 16:9, default on; `RECOMP_WIDESCREEN=0` gives the original 4:3 image):
  - `sub_000E983E` is `D3DXMatrixPerspectiveFovLH(out, fovy, aspect, zn, zf)`. `manual.zig` widens a 4:3 aspect by 4/3
    and stamps `gl_hle.wide_frame`. The title screen's caller (`0xD09BF`) is left alone: its 3D logo belongs to a 4:3
    composition. Other callers: stage camera `0x1B86B`, `0x428FE`, `0x83F48`, `0x846A3`; `0xD4048` (aspect 1) stays.
  - The back buffer is 853x480 (times scale). 3D stretches across it only while a widened projection is in use
    (`wideNow`, in stages); otherwise 3D and narrow 2D (HUD, text) keep their 4:3 place in the middle.
  - 2D touching a screen edge (backgrounds, banners, tiled pictures, fades, letterbox bars, the SEGA white screen) is extended,
    not stretched (`extend2d`): its edge vertices move out to the buffer's edges with texture coordinates extrapolated,
    so tiled patterns carry on and a picture inside a full-screen layer (the title logo) keeps its shape. A
    picture with faded edges (the stage menu's bamboo preview) stays 4:3 with the pattern beneath it at the sides.
    Banner tiles (edge quads 16-256 px wide, a power of two; the menus draw their bands as 128 px tiles with clamped
    textures) repeat outward instead, as extrapolating a clamped tile only smears its edge texels.
  - A full-width `CopyRects` of the back buffer squeezes the whole wide buffer into its 640 columns. A full-width draw
    of such a copy (pause blur, menu desaturate) stretches back; a draw kept in the middle (the title logo's
    refraction) samples it remapped to its 4:3 position (`uploadTscale`, `u_tscale.zw` offset).
  - Known: in the pause menu a full-width overlay's clamped texture edge darkens the left pillar a little. Cutscene
    letterbox bars are handled by the full-width rule but were not seen in a test run.
- Pad script that reaches stage 1 from boot: `RECOMP_PAD_SCRIPT=15000:start,18000:start,21000:a,23000:a,...,61000:a`
  (A every 2 s); add `70000:start` for the pause menu. `RECOMP_SHOT` frames ~1800 are in the stage.
- Pause blur: it copies the back buffer, downsamples the copy into a 320x240 target and draws that back. A target drawn
  from a back buffer copy counts as one (`addCopy`), so the blur stretches across instead of extending its edge.
- Frame interpolation (`RECOMP_FRAMERATE`, default the monitor's refresh rate, rounded down to a multiple of 30; 30 is off):
  the logic still steps once per 30 Hz frame. Each frame's draws and clears are recorded (state block, textures,
  shaders, vertex/index copies, vertex shader constants, transforms); Swap then draws the frame again at in-between
  times inside its slot with constants and transforms blended from the previous frame's matching draw (same
  shader/texture/stream/count, n-th occurrence), and shows the real frame at the slot's end (one frame of latency).
  CPU-written vertices (particles, 2D) do not blend. `RECOMP_FPS=1` prints game and shown frames per second.
  Tested: 30 game / 60 and 120 shown in stage 1.
- `settings.ini` (beside `game\`): each `key = value` line sets `RECOMP_<KEY>` unless the environment has it
  (`main.zig` `loadSettings`). The shipped file sets scale, widescreen, framerate, vsync and gfx.
- `RECOMP_VSYNC` (default on): `eglSwapInterval(1)`. On a 144 Hz monitor interpolation shows 120 frames a second,
  which judders against the refresh; a 60/120 Hz refresh or `framerate = 60` paces evenly.
- Flicker report (2026-11-01): a probe reading nine points of the window after every shown frame (title, menus,
  stage, combat, 95 s at 120 Hz, vsync off) found no black frames except the game's own cut at stage start.
  Unexplained; vsync was added in case it was tearing.
- Gameplay flicker (fast movement): in-between frames lost the mist. The mist is dozens of sprite draws sharing
  shader, texture and buffer; matching them by occurrence paired the wrong sprites, and blending their constants
  scattered them. Draws now blend only when their key (shader, textures, stream, base, first vertex, count) is unique
  in both frames; repeated ones show the newer frame. A probe comparing each in-between frame with its neighbours
  (32x18 downsample) found 10 bad frames in a 25 s dash run before, 0 after; about half the draws blend.
- Mist sprites (vertex program `1D94C21`, additive, Z write off) come last in the frame; the game turns ZENABLE off
  for about a third of them, so those draw over the ground in front. `RECOMP_MIST_DEPTH` (default on) keeps the depth
  test for that program (microcode hash `A8A1DBCD`; `HostVs.hash` names programs across runs). The ZENABLE index
  (143) is right: StencilEnable 144 and ZBias 149 match the XbSymbol variables.
