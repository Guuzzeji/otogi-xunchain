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
  modes sample as 2D, one render target, CopyRects downsamples by nearest, no keyboard from the window.
