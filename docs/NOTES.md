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

## Boot (M2, in progress)
- Re-lift after changing `seeds/manual.json` (directly called overrides; their bodies are left out):
  `recomp ../game/default.xbe --all --split 250 --gen-dir ../src/recomp/gen --manual-functions ../seeds/manual.json` (~40 s).
  Overrides live in `src/manual.zig` as `export fn sub_XXXXXXXX`.
- `build.zig` sets `sanitize_c = .off`: Zig Debug enables UBSan for C, and its alignment check fires on 4-byte-aligned guest structs.
- Log: `logs\otogi.log` (stdout and stderr). Watchdog: `RECOMP_WATCHDOG_SECS=N` prints guest regs and stack.
- Fixes so far, in boot order:
  1. `sub_000E571D` (XAPI DVD media check) returns success. Cert+0x1D8 bit 0 asks for the security sector (READ DVD STRUCTURE), which an ISO lacks; it retried 5x and rebooted to the dashboard.
  2. `RECOMP_ASYNC_IO` on by default (`main.zig`). The stream loader `sub_0007BDD0` reads overlapped and only fills the byte count on ERROR_IO_PENDING; a synchronous completion read as 0 bytes, E_FAIL, and the disc-error loop `sub_000137D0`.
  3. `sub_000FA2A0` (D3D BlockOnTime): GPU semaphore (device+0x30) points at the fence counter (device+0x2C), so every fence reads as done. Device pointer is at `0x1051C8`.
  4. `RECOMP_VBLANK` on by default; vblank interrupts come from the toolkit tick (~40 Hz, 600 in 15 s).
  5. `sub_000C81A0` (per-frame XMV step) returns "movie ended". XMV's clock (`sub_00146D25`) stays 0 until its decode/audio pipeline starts the clock, so it would Sleep(2) forever. M4 replaces this.
  6. `xbox_OhciInit()` is called at boot (the template never called it); inert unless `RECOMP_USB` is set.
- Current state with no env vars: menu assets, BGM, player data load; the title/attract loop runs (promo XMV reopened each cycle); 60 s, no crash.
- Missing on disc too (the game probes them): `sfx\s000_00.dds` etc., `media\distortion.dds`.
- Open: with `RECOMP_USB=1` the pad enumerates (XID descriptor read) but the game thread crashes in `sub_000DB930` (`edi=0x73FFFF80`, via `sub_000D0A60` from the game main `sub_00043310`). Without a pad there is no input, so no stage loads and `chr\`/`map\` are never opened.
- Unhandled but harmless so far: `cli`/`sti` at `0x00171BA5`/`0x00171BB6` (XPP USB code).
