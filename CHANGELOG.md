# Changelog

All notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The version lives in `build.zig.zon`;
the Release workflow moves "Unreleased" into a new version section.

## [Unreleased]

### Changed
- Setup's game art (title logo, Raikoh, red waves, brush stroke) is built into the
  exe, so it shows as soon as setup opens, before a disc is picked.

## [0.6.0] - 2026-11-01

### Added
- `otogi-setup.exe`: builds the game from the player's own disc image. It checks the
  disc (SHA-1 of `default.xbe`), extracts the game files, downloads pinned Zig,
  Python and Capstone (SHA-256 checked), translates the game code to C, compiles
  it, and leaves `otogi.exe` with `settings.ini` and `game\` in the chosen folder.
  Finished steps are kept, so a rerun picks up where it stopped.
- Setup shows a time estimate before and during the build, a step checklist, and a
  Stop button that also ends the tools it started.
- Setup log (`setup.log`) with system info at the top, Copy log and Open log file
  buttons, for problem reports.
- Setup uses the game's own menu art, read from the player's disc. It remembers the
  last disc, and finds an `.iso` next to the exe.
- In-game debug menu (F1): frame rate and frame time, draw counts, cache sizes,
  pause and frame step, a memory viewer, and cheats (warp to any stage, unlock all
  stages, god mode, infinite magic, max money, give all weapons, magic,
  accessories and items).
- Version and commit in the game log, the debug menu and the setup window.

## [0.5.0] - 2026-11-01

### Added
- 2x to 4x internal resolution, 16:9 widescreen (hor+), frame interpolation up to
  the monitor's refresh rate, vsync, and `settings.ini`.

### Fixed
- Pause-menu blur, and ground mist drawing over the ground in front.

## [0.4.0] - 2026-11-01

### Added
- Playable: controller input, sound, saves, the attract movie, map meshes, fog,
  bump mapping and 30 fps pacing.

## [0.3.0] - 2026-11-01

### Added
- First pixels: the title, menus and stage 1 render through ANGLE.

## [0.2.0] - 2026-11-01

### Added
- The recompiled game boots and reaches stage 1 without graphics.

## [0.1.0] - 2026-11-01

### Added
- Zig build, the xboxrecomp toolkit, and the lifted game code linking into one exe.
