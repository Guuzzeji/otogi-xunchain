# Changelog

All notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The version lives in `build.zig.zon`;
the Release workflow moves "Unreleased" into a new version section.

## [Unreleased]

## [0.7.0] - 2026-11-08

### Added
- Setup writes `settings.ini` next to `otogi.exe`: the version you are playing and
  what is new in it, a comment on every setting, and your own values kept when setup
  runs again.
- Settings `log` (write `otogi.log`, on by default), `cam_invert` and `debug_menu`.
- `window` setting: window, borderless or fullscreen (`resolution` sets the screen
  mode for fullscreen). Alt+Enter switches between a window and fullscreen.
  Borderless is the new default.
- README with screenshots, install steps, settings, controls and known issues; MIT license.
- Releases publish on their own when a push to main sets a new version in `build.zig.zon`.

### Changed
- The project is now **Otogi XUnchain** (github.com/Guuzzeji/otogi-xunchain), and setup
  is `otogi-xunchain-setup.exe`. The game exe, install folder and saves are unchanged.
- The game's log is `otogi.log` next to `otogi.exe` (was `logs\otogi.log`); the debug
  menu's window layout is `debug_menu.ini` there too.
- Setup's game art (title logo, Raikoh, red waves, brush stroke) is built into the
  exe, so it shows as soon as setup opens, before a disc is picked.

### Fixed
- `otogi.exe` finds `settings.ini` and `game\` in its own folder when started
  from somewhere else (setup's Play button, a shell in another folder).
- Sharp picture on scaled displays (125%, 150%, ...): the game is DPI aware, so
  Windows no longer renders it small and stretches it.
- Menus, the HUD and the game-over screen no longer turn white after the second
  stage played in a session: freed memory is now reused, so the game's textures
  keep loading.
- Stages with the glow effect (Sea of Fire, Inner Sanctum) no longer draw the world
  black: a clear of only the alpha channel cleared the whole picture.
- Game-over menu in widescreen: the still of the stage behind it fills the screen
  instead of sitting off to the left with smeared stripes and a black gap.
- No line of the scene along the top and left screen edges above letterbox bars and
  menu frames at 2x and higher.
- Setup's "Compile the game" step no longer fails on PCs without git.
- Running setup again after it was stopped while unpacking no longer fails with
  `PathAlreadyExists`.
- In the Heavens (the last stage) no longer turns white when the camera faces
  certain directions: the character after-image effect copies its own offscreen
  picture, which was skipped, so the previous frame was added back every frame.
- Tower of Water's waterfall no longer draws as white shards. Half its strips
  were culled; it is now drawn from both sides with a waterfall shader of our
  own, tuned by eye against footage of the Xbox version: solid white at the top
  of each fall, breaking into flowing streaks that fade out lower down.

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
