# Otogi recomp roadmap: Zig + xboxrecomp + ANGLE (Windows only)

## Context
User owns Otogi: Myth of Demons (USA) and has a full dump at `C:\repos\otogi-one-recomp\Otogi-usa-xbox-dump-10-31-2026.iso`. Goal: native Windows recompilation, following the pattern of the user's Sneak King project (`Guuzzeji/sneaky-whopper-recomp`). Differences from Sneak King:
- Zig instead of C for game-side code.
- No web build.
- End product: one GUI exe that builds the game from the player's own ISO without manual installs.

This is a roadmap, not a one-shot. Each milestone ends with a check that must pass before the next starts.

## Facts already established
- ISO is a redump-style dump. XDVDFS game partition is at `0x18300000`. `default.xbe` is 1,921,024 bytes.
- XBE: base `0x10000`, entry `0x000E43B7`, kernel thunk `0x00173DE0`, title ID `0x46530002`.
- XDK **5455** for all libraries (Sneak King is 5849). D3D8, D3DX8, DSOUND and XMV are linked statically into named sections (`D3D` at `0xF3EE0`, `DSOUND` at `0x125B60`, `XMV` at `0x145D40`).
- `.data` virtual size is about 18.8 MB, of which about 96 KB is on disk.
- `movie/` holds one 104 MB file. Otogi uses XMV movies.
- xboxrecomp v0.16 has two halves. Python tools (`tools/xiso`, `xbe_parser`, `disasm`, `func_id`, `abi_analysis`, `recomp`) lift x86 to C. C static libraries (`src/kernel`, `apu`, `usb`, `input`, `video`, `nv2a`, `d3d`) provide the runtime. The game project supplies `main` and `recomp_lookup_manual`. Template: `templates/new-game/src/main.c`.
- Sneak King lessons:
  - Its pushbuffer and D3D11 path was a dead end.
  - What worked was a D3D8 HLE: wrap the game's D3D entry points, run the lifted setter, mirror its state, and replace draw, clear and present.
  - The HLE targets OpenGL ES 3 through ANGLE (`src/gl_hle.c`, `src/d3d_hle_shared.h`).
  - ANGLE is a prebuilt zip pinned to commit `feebf60`, with a SHA-256 check (`tools/sneakking.py`). It ships `libEGL.dll`, `libGLESv2.dll`, `d3dcompiler_47.dll` and `vulkan-1.dll` next to the exe.
- This machine has:
  - cmake 4.4, git and gh, and VS 2022 (not on PATH).
  - **Not installed: zig, python, ninja.**

## Decisions (user confirmed)
- xboxrecomp goes in as a `git subtree` of upstream **v0.16** at `xboxrecomp/`. Port Sneak King toolkit patches only when Otogi hits the same bug.
- Zig is used for:
  - the build (`build.zig`; `zig cc` compiles the toolkit C and the lifted C, so no VS install is needed)
  - the host `main`
  - the manual overrides
  - the ANGLE renderer HLE
  - the ISO extractor
  - the setup GUI
- The Python lifter stays as it is. The GUI fetches embeddable Python and Capstone, pinned by hash.
- The setup GUI uses Dear ImGui.

## Repo layout (keep it this small)
```
build.zig, build.zig.zon     one build: game exe + setup exe
xboxrecomp/                  subtree, upstream v0.16
src/main.zig                 boot sequence (port of template main.c)
src/manual.zig               recomp_lookup_manual + sub_XXXXXXXX overrides
src/gl_hle.zig               D3D8 HLE -> GLES3 via ANGLE EGL
src/shim.h / shim.c          only if translate-c chokes on recomp_types.h macros
src/recomp/gen/              lifted C (gitignored)
seeds/                       missed-function seed JSON
setup/main.zig               ImGui setup tool
settings.ini, mkb.ini        copied pattern from Sneak King
third_party/angle/, game/    gitignored
```
Write `.gitignore` first: `*.iso`, `game/`, `src/recomp/gen/`, `analysis/`, `third_party/angle/`, `zig-out/`, `.zig-cache/`. Never commit game data, lifted C, or the XBE. That content is derived from copyrighted material, so it is why the player's own ISO is required.

---

## M0: Scaffold and toolchain spike (goal: risk check) — DONE 2026-11-01
1. Run `git init`. Write `.gitignore`. Run `git subtree add --prefix xboxrecomp https://github.com/sp00nznet/xboxrecomp v0.16.0 --squash`.
2. Install the dev tools: zig (pin the latest stable release, recorded in `build.zig.zon` `minimum_zig_version`) and Python 3.12 with `pip install capstone`.
3. Write `build.zig`:
   - compile `xboxrecomp/src/**` C as a static library with target `x86_64-windows-gnu`
   - link a stub `main.zig` that `@cImport`s `xboxrecomp.h`
4. Unpack the ISO with `py -3 -m tools.xiso unpack <iso> -o game`. Record the SHA-1 of `default.xbe` in `docs/NOTES.md`.

**Risk check.** Does the toolkit compile under `zig cc` (clang plus MinGW)? The toolkit already ships `cmake/mingw-w64-x86_64.cmake`, which is a good sign.
- If MSVC-only code breaks the build, patch the toolkit for clang. Use `#ifdef _MSC_VER`.
- Fallback: `-target x86_64-windows-msvc` using the installed VS. That fallback blocks the "no install" GUI goal, so prefer the patch.

**Exit check:** `zig build` produces an exe. The exe runs `xbox_MemoryLayoutInit` and exits cleanly.

## M1: Lift and link — DONE 2026-11-01
1. Run the pipeline from `docs/GETTING_STARTED.md`: `xbe_parser --json`, `disasm`, `func_id`, `abi_analysis`, then `recomp --all --split 250 --gen-dir src/recomp/gen`.
2. Make `build.zig` glob `src/recomp/gen/*.c`. Build with limited parallelism, because Sneak King needed about 16 GB of RAM.
3. Fix lifter gaps (`/* mnemonic */` holes, seen as segment prefixes and x87/SSE forms) in `xboxrecomp/tools/recomp/translator.py`. Keep data that was lifted as code out of the seeds. This was Sneak King P2.

**Exit check:**
- The build links cleanly.
- `grep` finds no `/* <mnemonic> */` holes in the generated code.

## M2: Boot without graphics — DONE 2026-11-01
1. Port `templates/new-game/src/main.c` to `src/main.zig`. Boot order:
   1. VEH handler
   2. `xbox_MemoryLayoutInit`
   3. `xbox_kernel_init`
   4. `xbox_path_init`, with D: mapped read-only to `game/`
   5. `xbox_kernel_bridge_init`
   6. set `g_esp`
   7. `recomp_dispatch_init`
   8. `xbe_entry_point()` at `0xE43B7`
2. Call `timeBeginPeriod(1)`. Write the log to `logs\otogi.log`.
3. Write `src/manual.zig` with `export fn recomp_lookup_manual`. Start it empty.
4. Iterate: crash, then `tools/seed_from_log`, `icall_feedback`, and a kernel stub. Re-lift.
5. Check the Sneak King boot fixes first:
   - `XPhysicalAlloc` large arena
   - seed entries after `ret` or noreturn calls
   - `RECOMP_AC97_READY`
   - D3D fence semaphore
   - APU heartbeat
   - `NtQueueApcThread` APCs
   - OHCI init
   - XMV vblank timing

**Exit check:**
- The game reaches its main loop.
- The log shows `game/chr` and `game/map` file opens.
- There is no crash for 60 seconds.

## M3: First pixels through ANGLE — DONE 2026-11-01
1. Find Otogi's D3D8 entry points in the `D3D` section: `func_id` XDK signatures, then confirm in Ghidra. **XDK 5455 is not 5849**, so the device struct offsets and render-state tables differ from Sneak King. Re-derive them. Do not copy addresses.
2. Port `gl_hle.c` and `d3d_hle_shared.h` to `src/gl_hle.zig`. Use `@cImport` of the EGL and GLES3 headers. Use `EGL_PLATFORM_ANGLE_TYPE_D3D11_ANGLE` by default; `RECOMP_GFX` overrides it.
3. Get ANGLE from the same pinned zip and hash that Sneak King uses. Copy the 4 DLLs next to the exe in `build.zig`.
4. Keep one `glBufferData` per draw. Sneak King P10 showed that the unsynchronized ring was slow on D3D11.

**Exit check:** the title screen and menu render correctly.

## M4: Playable — items 1-5 working; full stage 1 run not yet verified (skipped to M5 at the user's request)
1. Input: XInput plus `mkb.ini` (reuse `xboxrecomp/src/input/mkb_input.c`).
2. Audio: APU to XAudio2.
3. XMV intro movie.
4. Saves in `%LOCALAPPDATA%`.
5. Pixel shaders (register combiners). Sneak King never translated these, and Otogi's effects probably need them. Expect real work here.

**Exit check:** Stage 1 is playable start to finish at the game's native frame rate, with sound.

## M5: Enhancements — items 1-3 done 2026-11-01 (plus frame interpolation and vsync); exit check not run at 2560x1440
1. **2x internal resolution:** `RECOMP_SCALE` (1 to 4). Scale render targets, viewport and scissor in `gl_hle.zig`. Copy Sneak King's approach.
2. **16:9 widescreen:** find Otogi's projection/FOV setup and its 2D ortho function. Override both in `manual.zig` (hor+). Keep the HUD at 4:3, centered, or anchored.
3. **`settings.ini`:** an environment variable wins over the file, as in Sneak King. Add a small F1 ImGui overlay only if it is wanted later.

**Exit check:**
- 2560x1440 at 16:9 renders with an undistorted HUD.
- `RECOMP_SCALE=1` and `RECOMP_WIDESCREEN=0` give the original image.

## M6: Setup GUI (`otogi-setup.exe`) — built 2026-11-01; full run from ISO verified on the dev machine, clean-VM exit check not run
1. **Window:** Dear ImGui using `imgui_impl_win32` and `imgui_impl_dx11`. These need only system DLLs, so the result is one exe with no extra files. Build the ImGui C++ with `zig c++`. Call it from Zig through dear_bindings `dcimgui.h` with `@cImport`.
2. **Screen:** ISO picker (Win32 `GetOpenFileName`), output folder, a Build button, a progress bar, and a scrolling log.
3. **Steps.** Each step is resumable through stamp files, as in Sneak King's `analysis/.stamps`.
   1. Check the ISO. Read the XDVDFS image in Zig: a small reader with the partition at `0x18300000` and the binary-tree directory. Hash `default.xbe` and match it against the known SHA-1.
   2. Extract `game/`.
   3. Download and verify (SHA-256 pinned) into a cache folder: the zig toolchain zip, Python embeddable plus the Capstone wheel, and the ANGLE zip.
   4. Run the lift pipeline.
   5. Run `zig build`.
   6. Package `dist/Otogi/`.
4. **Source:** `@embedFile` a zip of the repo source (game Zig code, toolkit and seeds) built at release time. Unpack it with `std.zip`.
5. **Warning:** show a RAM warning when the machine has less than 16 GB. If needed, drop the build to `-j1`.

**Exit check:** on a clean Windows VM with no VS, Python or zig installed, ISO plus `otogi-setup.exe` produce a playable `dist/Otogi/`.

---

## Reuse map (do not rewrite)
- Toolkit runtime and lifter: `xboxrecomp/` as it is.
- Boot sequence: `xboxrecomp/templates/new-game/src/main.c`.
- Renderer design, ANGLE pin, DLL copy and EGL platform selection: Sneak King `src/gl_hle.c` and `src/d3d_hle_shared.h`.
- Scale, widescreen and ini handling: Sneak King `src/main.c` and `src/recomp_manual.c` (FOV and ortho overrides).
- Input bindings: Sneak King `mkb.ini`, plus toolkit `src/input/mkb_input.c`.
- Pipeline order, stamps and hash checks: Sneak King `tools/sneakking.py`.
- Skip: everything in Sneak King for web/Emscripten, joke modes, cod4/skate, and HD textures.

## Known risks
- `zig cc` may not build the toolkit: decide in M0.
- Zig translate-c may fail on the `recomp_types.h` macros (`MEM`, `ICALL`): use a C shim with inline functions.
- D3D for XDK 5455 differs from Sneak King's 5849: re-derive the offsets in M3.
- Register combiners are missing: M4.
- Generated C is large (RAM and build time): `--split 250`, low parallelism.

## Verification per milestone
Each milestone's exit check above is its test. Also:
- Add a `zig build test` step with one test: the XDVDFS reader lists `default.xbe` at sector 1714694 from the real ISO, skipped when the ISO is absent.
- Keep a `docs/ROADMAP.md` in the repo that mirrors these milestones and their status. Update it at each exit check.

## Out of scope (add later only if wanted)
- Porting the Python lifter to Zig.
- A web build.
- HD texture packs.
- Linux and macOS.
- A Pushbuffer/NV2A renderer.
