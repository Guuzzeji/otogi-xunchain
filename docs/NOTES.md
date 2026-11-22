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
- Log: `otogi.log` beside the exe, i.e. in the working directory (stdout and stderr); `log = 0` in settings.ini turns it off. Watchdog: `RECOMP_WATCHDOG_SECS=N` prints guest regs and stack.
- Fixes, in boot order:
  1. `sub_000E571D` (XAPI DVD media check) returns success. Cert+0x1D8 bit 0 asks for the security sector (READ DVD STRUCTURE), which an ISO lacks; it retried 5x and rebooted to the dashboard.
  2. `RECOMP_ASYNC_IO` on by default (`main.zig`). The stream loader `sub_0007BDD0` reads overlapped and only fills the byte count on ERROR_IO_PENDING; a synchronous completion read as 0 bytes, E_FAIL, and the disc-error loop `sub_000137D0`.
  3. `sub_000FA2A0` (D3D BlockOnTime): GPU semaphore (device+0x30) points at the fence counter (device+0x2C), so every fence reads as done. Device pointer is at `0x1051C8`.
  4. `RECOMP_VBLANK` on by default; vblank interrupts come from the toolkit tick (~40 Hz, 600 in 15 s).
  5. `sub_000C81A0` (per-frame XMV step) returns "movie ended". XMV's clock (`sub_00146D25`) stays 0 until its decode/audio pipeline starts the clock, so it would Sleep(2) forever. M4 replaces this.
  6. XAPI input HLE: XInitDevices `sub_0016E924`, XGetDevices `E929`, XGetDeviceChanges `E94B`, XInputOpen `EA1A`, XInputClose `EA70`,
     XInputGetCapabilities `EA7C`, XInputGetState `EC54`, XInputSetState `ECC7` (`0x16DB4C` = gamepad type). They feed
     `usb_gamepad_report` (host pads through SDL3, keyboard, `RECOMP_PAD_SCRIPT`). Port 0 only; it "arrives" on the first
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
    effect draws it back). The back buffer is GPU-only: the copy is a GPU blit into a host target the texture then samples,
    read back into guest memory only when the game locks the surface (see Render thread under Draw cost).
  - `SetViewport` passes 0x7FFFFFFF for "the whole target"; clamped to 640x480 as D3D does.
  - Swap is held to 60 Hz: nothing else paces it, and the title otherwise runs ~1000 fps.
  - A8 textures read RGB as 1 (as xemu); `G8B8` maps as xemu does.
- Debug knobs: `RECOMP_SHOT=<frame>,...` writes `logs\frame_N.bmp`; `RECOMP_GL_DRAWLOG=<frame>` logs that frame's draws;
  `RECOMP_GL_DUMP=1` prints each pixel-shader program's GLSL. `RECOMP_SCALE` (1-4, default 2), `RECOMP_GFX`.
- Known gaps: palettes (P8 reads white), fixed-function lighting (SetLight not identified for 5455), bump/dot texture
  modes sample as 2D, CopyRects downsamples by nearest. Neither palettes nor fixed-function lighting is used by Otogi:
  the disc's 3219 DDS textures are DXT1/3/5 and A8R8G8B8 (its DDS loader `0x41D90` is the only palette path), and all
  FVF draws are pre-transformed (lighting is done in vertex programs). Each logs a line once if it ever shows up.

## Playable (M4)
- Frame rate: CreateDevice (`0x159D0`) asks for `FullScreen_PresentationInterval` 0x80000002 (every second vblank,
  at once when late) and the game steps once per frame, so Swap is held to 30 Hz on a vblank grid. Holding 60 ran
  the game at twice its speed. `zig build` defaults to `-Doptimize=fast`: the Debug renderer could not keep up.
  `RECOMP_FPS=1` prints presents per second every 5 s.
- Input: pads and keyboard through SDL3 (`src/input.zig`, below). The game reads its pad in `0x44060`: `(raw + 0.5) / 32767.5`,
  a 40% dead zone per axis, buttons pressed above 0x1E. Controls (Options > Controller Config, Type A): LT lock-on,
  RT dash, A jump, B small attack, X spell, Y great attack. `src/pad.zig` adapts a modern pad: LB/RB also press
  LT/RT (Otogi does not use Black/White), the right stick is inverted on both axes (Otogi orbits the camera;
  `RECOMP_CAM_INVERT=0` keeps it) and starts at the game's 40% past a 15% host dead zone. Rumble goes to the host
  pad (`XInputSetState`, motors at feedback+66; `SDL_RumbleGamepad` on the host).
- SDL3 is the window, its events and the pads; nothing else. ANGLE still draws (the window is made without SDL's GL
  flag and EGL gets its HWND from `SDL_PROP_WINDOW_WIN32_HWND_POINTER`), XAudio2 still plays. The prebuilt
  `SDL3.dll` is pinned in `build.zig.zon` like ANGLE. All SDL calls are on the render thread, which calls
  `SDL_SetMainReady` itself; that is fine on Windows and not on macOS.
  - `src/input.zig` replaces the toolkit's `input/xinput_device.c` (left out of the build, not edited) and exports
    the same five `xbox_Input*` functions, so `usb_gamepad_report` is unchanged. Before this the pad was XInput
    slot 0 only, and the keyboard was dead: nothing called `xbox_InputKeySet` and `RECOMP_KEYBOARD` was never set
    (issue #8). Now `main.zig` sets it, and key events map SDL scancodes to the Windows key codes of the
    toolkit's key map.
  - Every host pad plays the one guest pad (`pad.merge`: buttons OR-ed, each axis from the pad pushing it
    furthest). That removes the "which slot" question, and a pad that shows up twice (the real one plus a
    DS4Windows or Steam Input copy) does no harm. The render thread polls after each event pump; the game
    thread reads the last state under a lock.
  - Fullscreen is `SDL_SetWindowFullscreenMode`: no mode = borderless, a mode (the desktop's or
    `RECOMP_RESOLUTION`) = exclusive, which SDL minimizes on focus loss. `fr_step` is recomputed when the window
    changes monitor or the monitor changes mode, and takes fractional rates (59.94).
  - While the debug menu wants the keyboard, key presses stay out of the game; releases always go through.
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
- Frame interpolation (`RECOMP_FRAMERATE`, default the refresh rate of the window's monitor; 30 is off):
  the logic still steps once per 30 Hz frame. Each frame's draws and clears are recorded (state block, textures,
  shaders, vertex/index copies, vertex shader constants, transforms); the render thread draws the frame again at in-between
  times inside its slot with constants and transforms blended from the previous frame's matching draw (same
  shader/texture/stream/count, n-th occurrence), and shows the real frame at the slot's end (one frame of latency, and one for the hand-over).
  CPU-written vertices (particles, 2D) do not blend. `RECOMP_FPS=1` prints game and shown frames per second.
  Tested: 30 game / 60 and 120 shown in stage 1.
- The game reads `game\`, `settings.ini` and `logs\` from the working directory; when that has no
  `game\default.xbe` it switches to the exe's folder first (setup's Play starts it from elsewhere).
- Setup writes `settings.ini` beside otogi.exe: a header with the version and that version's CHANGELOG.md section,
  then the repo's `settings.ini` as the template (a comment per setting). Values already in the player's file are kept,
  unknown keys are carried over at the end. Settings: window, resolution, scale, widescreen, framerate, vsync, gfx, mist_depth, cam_invert, show_mouse,
  debug_menu, log.
- `settings.ini` (beside `game\`): each `key = value` line sets `RECOMP_<KEY>` unless the environment has it
  (`main.zig` `loadSettings`). The shipped file sets scale, widescreen, framerate, vsync and gfx.
- `RECOMP_VSYNC` (default on): `eglSwapInterval(1)`.
- Judder report (issue #1, 120 shown on an ultrawide, vsync off): in-betweens were due on an even grid of
  `30 * n` frames a second and blended for their place on it, but Swap only starts after the game's work, so the
  first one showed late (or not at all) with the picture for an earlier time; and a 144 Hz monitor got 120.
  Now each in-between is blended for the time it is shown at (`swapInterp`), at the monitor's own rate.
  Nothing can show while the game thread does its own work, so in-betweens show every second (third...) refresh
  when the work plus one replay takes longer than one: fewer frames, evenly spaced. Measured on the dev machine
  (RX 6700 XT, vsync off, `framerate = 120`, stage 1): work 22 ms, one replay 8 ms (1,440 draws). Before: 56 shown
  a second with 40 ms gaps (an in-between at 30 ms into the slot, the real frame 3 ms later). After: 30 shown,
  34 ms gaps, as nothing fits; menus (work 7 ms) show 60. `RECOMP_FPS=1` prints the longest gap and the work time.
  More frames in a stage need less work a frame, or the replays on a second thread while the game runs.
  With the render thread (below) it is that thread that schedules them (`renderThread`), and what one in-between
  costs to draw (`fr_pass_ms`), not the game's work, decides the spacing: the same opening shows 137 of 144.
- Stuck at 30 shown (issues #15, #1): `fr_pass_ms` was measured only inside the loop it gates. One slow pass
  (about 200 ms: a program compiling as the pause menu opens) lifted the average past what fits between two game
  frames, the loop stopped, and nothing lowered the average again until a restart. Now a sample counts as one game
  frame at most and the average falls while no in-between runs (`pacer.zig`); the log says when they go off and on.
  Forcing the average to 30 ms brings them back within five game frames.
- Flicker report (2026-11-01): a probe reading nine points of the window after every shown frame (title, menus,
  stage, combat, 95 s at 120 Hz, vsync off) found no black frames except the game's own cut at stage start.
  Unexplained; vsync was added in case it was tearing.
- Gameplay flicker (fast movement): in-between frames lost the mist. The mist is dozens of sprite draws sharing
  shader, texture and buffer; matching them by occurrence paired the wrong sprites, and blending their constants
  scattered them. Draws now blend only when their key (shader, textures, stream, base, first vertex, count) is unique
  in both frames; repeated ones show the newer frame. A probe comparing each in-between frame with its neighbours
  (32x18 downsample) found 10 bad frames in a 25 s dash run before, 0 after; about half the draws blend.
- Stutter on trees and enemies (m000, 2026-11-14): the unblended half was every mesh drawn more than once (bamboo,
  enemies of one kind: 329 of 689 draws standing in m000), moving at 30 Hz inside a 60 Hz picture. Pairing them by
  nearest constants (an 8-number signature, the group's mean change taken out, the nearest 4 times nearer than the
  next) fixed standing still and left the trees jittering when the camera turned: a group whose count changed as one
  culled stayed unblended whole (100-220 draws a frame), and a turn changes each instance's rows by a different
  amount. What works: things that stand still keep some rows bit for bit that differ from one to the next (bamboo,
  program `1DA3E41`: rows 91-93 and 120-122 of 13 that differ), so `frameMatch` learns those rows per key and pairs
  by them, any count, any camera. That left the mist jittering (sprites of `1D94C21`, all moving): by the signature
  24-35 of 40 paired while the camera turned, and none where the count changed. The ones the rows do not name now
  take the previous draw nearest in up to 4 rows picked per key, each added while it sets the nearest previous draw
  further apart from the next (16 draws tried, every 4 frames); for the mist that picks its world matrix, rows
  120-122, which a camera turn leaves alone. Two as near count as one only with all constants equal: picking either
  of two sprites with the same alpha is how a one-row choice would scatter them. Running forward and turning in
  m000: 0 draws unblended most frames, else the ones new that frame. Draws with equal constants must get the same
  answer: blending one pass of the player's shadow volume and not the other drew streaks from player to shadow.
  Matching costs 0.1-0.2 ms at 260-690 draws, 1.1-1.3 ms at 1,400-2,200, in the frame's wait. Checked by eye on
  in-between frames of m000, m001, m003, m014, m020; not with the dash probe.
- The mesh cache counted an in-between replay as a mesh's second sighting, so with interpolation on every new mesh got
  buffers at once; it now waits for a later game frame.
- Mist sprites (vertex program `1D94C21`, additive, Z write off) come last in the frame; the game turns ZENABLE off
  for about a third of them, so those draw over the ground in front. `RECOMP_MIST_DEPTH` (default on) keeps the depth
  test for that program (microcode hash `A8A1DBCD`; `HostVs.hash` names programs across runs). The ZENABLE index
  (143) is right: StencilEnable 144 and ZBias 149 match the XbSymbol variables.

## Stage fixes (after M6)
- In the Heavens (m027) white-out: the character after-image pass draws characters into a 640x480 target (fades it with a
  translucent quad each frame), switches back to the back buffer, then `CopyRects` that target into a linear texture and
  draws it over the screen blended and added. CopyRects only read the current target, so the copy was skipped and the
  texture kept last frame's full scene (the glow's back buffer copy uses the same texture); adding it back each frame ran
  away to white. CopyRects now reads any surface that has a host target. A target that widened 3D is drawn into counts
  as a wide copy, so its copy stretches across the 16:9 screen instead of being extended.
- Tower of Water (m007) waterfall: vertex program 0x1D93961 with fixed-function stage 0 (ripple texture x diffuse),
  added (SRCALPHA, ONE) as stacked strip layers, vertex fog: c158 = (-4e-6, 1), fog colour FFBCC7D7 (`0x18170`, table
  `0x20A3D8`); D3D's fog setup (`0xFC220`) for FOGTABLEMODE NONE is LINEAR (1, 1), and the final combiner
  (0x130C0300) lerps to the fog colour. The strips (triangle strips, 720 vertices, v 0 at each strip's top edge) wind
  both ways and the game leaves CULLMODE on, so culling here dropped about half of them: the shards. Drawn faithfully
  (cull off, the game's fog), the layers stack to flat white, unlike Xbox footage. So the draw (m007 is story stage 7,
  the stage's only fogged additive layer: fog key 2) gets our own shader instead, tuned by eye against that footage:
  cull off, premultiplied alpha blend, two layers of the ripple texture flowing down on a clock of our own (the game's
  scroll wraps at 1 and jumps if rescaled), v mapped through sqrt for falling water, whole-number u scales so the wrap
  round the tower is seamless; solid near the top of each strip, streaky with gaps lower, faded in over the top 15%
  and out over the lower 60%; no distance terms, so it looks the same close up.

## Draw cost (issue #2)
- Report: a 15 W laptop (i5-1035G1) at 15 fps on stage 2 (m001), 3,080 draws and 62-69 ms of guest work a frame.
  CPU-bound on the guest thread; resolution and backend make no difference.
- Bench: load a save, cheat `warp 1`, let m001's opening play; `RECOMP_FPS=1` prints guest ms and draws every 5 s.
  Development PC, d3d11, scale 1, at the 2,660-draw part of the opening, guest ms a frame after each step:
  - 28-31 as it was.
  - 26.5: `sub_000FA0C0`, the D3D pushbuffer kick, waited on a PFB flush bit the nv2a-ack thread clears once a
    millisecond; the ring fills several times a frame. Hooked in `manual.zig` to write PUT and return.
  - 24.2: sampler parameters written only when changed, stages with no texture skipped (`applyStages`). ANGLE
    rebuilds a sampler state on every write, changed or not.
  - 18.4: mesh cache (`gl_hle.zig`). Only about 100 of the draws are recorded pushbuffers, so caching those alone
    would have done nothing; nearly all the others repeat unchanged vertices too (skinning is in the vertex programs).
  - 16.1: lifted code at `-O2` (was `-O1`).
  - 16.0: `progGet` tries the last program first.
  - 13.3 (from 15.2 the day it was measured): DirectSound's APU register accesses call the register model
    instead of faulting into it. About 200 faults a frame, 6 of every 7 from one voice-volume routine. The
    lifter emits `xbox_apu_rd32`/`xbox_apu_wr32` for a dword at a fixed address in 0xFE800000-0xFE87FFFF (288
    sites); two byte accesses and anything computed still trap. `RECOMP_APU_TRACE` only sees the trapped ones.
- All 29 stages, old against new, busiest 5 s of the first 45 s after a warp: 33% to 61% less guest ms on every
  stage, about half on most. The heaviest (m003, m005, m014, m016, m017, m019, m021) were 29-36 ms and are 13-20.
  Nothing here is per stage, so there is no switch.
- Measured and left out: skipping unchanged uniform uploads (0.3 ms at best), a no-error EGL context (0.1 ms, and
  it makes a bad guest state value undefined behaviour).
- What is left: about 5 in ANGLE's draw call itself (2 us a draw), 3 in the rest of `draw`, the rest guest
  code. Fewer draws would need batching.
- Render thread: the game thread calls no GL. `draw`, Clear and whole-surface CopyRects are recorded into a
  frame (what interpolation recorded already, plus the bytes of textures whose hash changed and new render
  targets); Swap hands it over and waits until the render thread has shown the frame before, which is the 30 Hz
  pacing. The render thread draws the in-between passes and the frame itself in its slot. Three frames go round:
  one being built, the one being drawn and the one before it to blend from.
  - Shaders are kept by content, handle -> table index looked up when the draw is recorded, so a handle reused
    for another shader (heap reclaim) does not change draws already recorded. Tables are fixed-size (1024) so the
    render thread can read them while the game thread appends.
  - Read-backs: a CopyRects into part of a surface, or the game locking (`Lock2DSurface`, hooked) a surface a
    whole-surface copy left on the GPU, waits while the render thread draws what the game's frame has recorded
    so far on top of the frame before, and reads the pixels (`serveSync`). The post effects' two full-screen
    copies a frame did this at first: 18 of the game thread's 23 ms. They are GPU blits now (and filtered, at
    the render scale, where the read-back sampled nearest down to 640x480).
  - m001's opening at 2,300-2,500 draws, 120 Hz, scale 2: game thread 3.5 ms a frame (1.4 recording), render
    thread 17-18 ms over the four passes, 119.8-120 shown (single thread: 110-113).
  - Costs: one more game frame of latency (the hand-over). The debug menu and cheats run on the render thread
    and write guest memory from there.
  - Not tested: the game-over still (the Lock path); the pause menu, which blurs through render targets, is.

## Shader cache and the shader list
- A GL program is built the first time a draw needs it (`progGet`). Measured on the dev PC (RX 6700 XT, D3D11):
  5-10 ms each, all of it in `glLinkProgram`; the first draw after costs 0.5 ms, so ANGLE does not put the
  compile off to the draw and nothing has to be drawn to finish it.
- Disk cache: `blobInit` hands ANGLE `EGL_ANDROID_blob_cache` callbacks. Every blob is one file in
  `shader_cache\` beside `otogi.exe`, named by ANGLE's key in hex. A cached program links in about 1 ms.
  The key covers driver and backend, so after an update the old files are simply never asked for; deleting
  the folder is always safe. D3D11 stores one blob a program; Vulkan stores more (its pipeline cache too).
  Both tested. `RECOMP_SHADER_CACHE=0` turns it off.
- Otogi makes all its shaders at start-up: 46 vertex programs and 24 pixel shaders before the title, from
  fixed addresses in its image (0x1C01C0 to 0x1D48A0). So a program can be named across runs without holding
  any game data.
- The list, `src/shaders.bin` (embedded): 100-byte records (`Rec`), each a `Key` whose shader indexes are
  swapped for the guest address and hash of each shader. `warm()` runs at the end of `glInit`, while the game
  thread still waits: it registers each record's shaders from guest memory as the game would, checks the hash
  (another disc revision is skipped, and its programs are built on first use as before) and builds the
  program. It draws a bar only when the wait passes 50 ms. The log says how many came from disk.
- Recording: run from the repo root with `RECOMP_SHADER_RECORD=1`. `warm()` then reads the list from
  `src/shaders.bin` on disk and every program the game needs that it lacks is appended. Play the stages,
  rebuild, commit the file. Changing `Key` invalidates it (a comptime size check catches a size change):
  empty the file and record again.
- A vertex program's microcode is translated the first time it is needed (`vsGlsl`), and `genVs` needs
  the result. `warm()` must call it too: without it every listed program with a vertex shader was built
  empty and the whole 3D world was missing (HUD and text still drew), with no error in the log.
- Log lines, all `[SHADER]`: cache on / off / not available, a cache folder that cannot be written (once),
  a list entry skipped with the hash found and the hash listed, one line for each program built (start-up
  or "while playing, not on the list", its time, compiled or from disk; a failed one says what it draws is
  missing) and the start-up total. A report with stutter should show "while playing" lines: those are the
  programs to record.
- State on 2026-11-22: the list holds 284 programs, recorded by warping to every stage (m000 to m027 and
  m185, a minute each, with the pad script and the `warp` cheat) on a new game. m101 and m102 cannot be
  reached by warp and are not covered, nor are cutscenes, the shop or late-game weapons and spells; what
  they need is built on first use and cached. Dev PC, empty cache: 2.0 s on D3D11, 3.0 s on GL, 0.4 s on
  Vulkan; cached: 0.4 to 0.8 s, 0.5 s, 0.1 s. D3D11 start-up time with a full cache varies run to run.

## Debug menu (F1)
- Dear ImGui 1.93.0 with dear_bindings 0.27 (`build.zig.zon`), built by `zig c++`; `build.zig` `addImgui` adds the
  sources and backends and exposes `dcimgui.h` as module `imgui`. Backend functions are hand-declared externs.
- `src/debug_menu.zig`: drawn at the end of `blitWindow` (so shots include it), on the GL thread, through
  `imgui_impl_opengl3` (GLES 3) and `imgui_impl_sdl3`. Closed, it costs nothing. `RECOMP_DEBUG_MENU=1` opens it at
  boot. Window layout in `debug_menu.ini`.
- Render tab: renderer, settings, game/shown fps, guest work time per frame (from the end of one Swap to the start of the
  next) with a graph and a count of frames over 33.3 ms, last frame's draws/clears/CopyRects/texture uploads
  (`gl_hle.last`), host cache sizes, pause and frame step (Swap shows the held frame until resumed).
- Memory tab: hex view and u32 write at a guest VA.
- Cheats tab (`src/cheats.zig`; addresses from the lifted code, all static): story stage `0x13DAC08`, all-stages flag
  `0x13DAC04`, stage order `0x1B98A0`, stage records `0x1D2C88` (0x3C each, +0x18 bit 0 cleared), exit request
  `0x1D80EC` (-1 none, 1 hub), status `0x13DA270` (level, +0x18 exp, +0x1C money, +0x24 max life), player object
  `0x13C91D0` (HP f32 `0x13D8BA8`, shown HP `+4`, max i32 `+8`; magic f32 `0x13D8BB4`, max `+4`), inventories
  (16-byte entries, +8 owned/quantity): weapons `0x13DA4C8` count `0x13DAAD0`, magic `0x13DA170`/`0x13DA8C8`,
  accessories `0x13DA2C0`/`0x13DA4C0`, items `0x13DA8D0`/`0x13DA8CC`.
- Warp sets the story stage and requests exit 1; the hub then opens on that stage. Tested: stage 1 to m005 (the
  hub's Next Stage loaded `map\m005`). Give-all, max money, god mode and infinite magic tested in stage 1.
- Seen with it: in m005 the magic gauge draws on a white square (not looked into).
- Testing by script: `Get-Process otogi` gives the window; `SetCursorPos` + `mouse_event` clicks reach ImGui once
  the window is topmost.

## Setup (M6)
- `zig build setup` makes `zig-out\bin\otogi-xunchain-setup.exe` (~4 MB, ReleaseSmall). It embeds `git archive HEAD` as a
  zip, so commit first. GUI: Win32 + D3D11 (`setup/window.cpp`, after ImGui's example), UI and pipeline in
  `setup/main.zig`. `otogi-xunchain-setup.exe <iso> <out>` starts at once (for tests).
- Steps, stamped in `<out>\build\.stamps` (a step that runs reruns every later one): check `default.xbe` SHA-1 in the
  ISO (`src/xiso.zig`), extract to `<out>\game`, unpack the source to `<out>\build`, download Zig 0.17.0, Python
  3.14.7 embeddable and the Capstone 5.0.9 wheel (SHA-256 pinned in `setup/main.zig`, kept in
  `<out>\build\downloads`), lift (xbe_parser, disasm, func_id, abi_analysis, recomp), `zig build --prefix <out>
  --prefix-exe-dir .` (`-j1` under 16 GB of RAM), copy `settings.ini` unless the player has one.
- Embeddable Python takes its sys.path from `python314._pth`; setup writes the site-packages and toolkit paths there.
- Tool output: stdout and stderr are `.pipe`s, drained by two threads into `<out>\setup.log`. Passing the log as
  `.file` does not work: Zig 0.17's Windows spawn reopens a `.file` handle by name, so the tool writes from offset 0 over
  the log (and an anonymous pipe fails to reopen with `NoDevice`).
- Zig's cache goes to `<out>\build\zig-cache` through `ZIG_GLOBAL_CACHE_DIR`; 0.17's `zig build` has no
  `--global-cache-dir`.
- The log starts with support info: setup commit, Windows build, CPU, RAM, GPU (DXGI adapter), ISO path and size,
  install folder and free space; each step line carries its start time. The UI has Copy log (whole file to the
  clipboard) and Open log file.
- Look: the game's own menu art, bundled (`setup/assets/art/`, ripped from the disc to JPEG/PNG, loaded through WIC):
  the `title.dds` logo on brocade fading to `fe_end00` Raikoh in the header, `fe_bg03A` red waves as the backdrop,
  the `fe_lo000` red brush stroke under the Build button and the running step. Dark panels with gold edges, light
  text, steps left and log right. Shippori Mincho B1 Bold (OFL, subset to 130 KB with fontTools); Segoe UI and
  Consolas come from Windows. Bundling the art is an owner's-choice exception to the no-game-data rule.
- Time estimate: per-step seconds from a measured first run (`step_secs` in `setup/main.zig`): extract 5 s (warm
  cache; 20 assumed), source 1 s, Zig 19 s, Python 1 s, lift 231 s (disasm 189 s), compile 238 s; 8 min 15 s in all.
  Steps already stamped count 0; the compile counts 2.5x under 16 GB of RAM. Before a run setup shows the total for
  what is left; during it, time left and elapsed.
- Stop: the main button turns into "Stop the build" (click twice). Tools run in a job object (KILL_ON_JOB_CLOSE);
  Stop terminates the job, so zig's compiler children die too, and closing setup mid-build does the same. Extract and
  downloads run in-process and finish their step first. Tested: stop during the compile left no processes.
- The last disc image that checked out is remembered in `otogi-setup-iso.txt` beside the exe; without one, setup
  tries the first `.iso` beside the exe.
- Run on this machine (2026-11-01): full pipeline ~7 min (compile alone ~2.5 min with an empty cache); the lifted C matched `src/recomp/gen` exactly; the built
  `<out>\otogi.exe` boots to the title. Not yet run on a clean VM (the M6 exit check).

## Versions and releases
- The version is `build.zig.zon`'s `.version` (semver; 0.6.0 = M6). `build.zig` passes it and the short commit to both
  exes as module `build_info`: the game log's first line, the debug menu, setup's window title and `setup.log`.
- `CHANGELOG.md` (Keep a Changelog): add entries under `## [Unreleased]` as work lands.
- GitHub Actions (github.com/Guuzzeji/otogi-xunchain):
  - `ci.yml` on push to main and on pull requests: changelog has a section for the current version, `zig build setup`,
    `zig build test`, setup exe as an artifact. The game itself is not built (it needs the lifted C from a disc).
  - `pr.yml` on pull requests (and body edits): exactly one box ticked under "Release" in the PR body
    (`.github/pull_request_template.md`: major, minor, patch, none), and unless none, an entry under Unreleased.
  - `release.yml` on every merged PR (`pull_request_target` closed + merged, so fork PRs get a write token; it checks
    out main, never PR code): bumps by the ticked box, moves Unreleased into a dated section, commits "Release vX.Y.Z"
    to main, tags, builds setup, pushes, and publishes a release with `otogi-xunchain-setup.exe`, the font's OFL text,
    and that changelog section as notes. A "none" box releases nothing. Runs are serialized (`concurrency: release`);
    if a merge lands during a build the push fails, and re-running the job bumps again from the new main.
  - By hand: Actions > Release > Run workflow with a bump; "none" there releases the current version as it is.
  - The bump and changelog shell and the box parser were dry-run locally on scratch copies.
