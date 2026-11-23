# Changelog

All notable changes to this project. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/). The version lives in `build.zig.zon`;
merging a PR runs the Release workflow, which moves "Unreleased" into a new version section.

## [Unreleased]

### Fixed
- In widescreen, the trailer that plays when you wait on the title screen no longer has
  smeared, streaky strips at the left and right: it plays at its own 4:3 shape with black
  bars at the sides (issue #9).

## [0.11.0] - 2026-11-23

### Added
- A launcher, `otogi-xunchain.exe`, replaces `otogi-xunchain-setup.exe`. Besides building
  the game from your disc, it has a Play page, a Settings page that edits every option in
  `settings.ini` with its explanation, a Saves page that lists your saved games and backs
  them up, and What's new with every release's notes. It works with a controller too.
- Updates from the launcher: when a new release is out, **Update** downloads it and
  rebuilds the game from the files you already have (the disc is not needed again).
  Settings and saves stay. This release is the last one to download by hand. The version
  list beside Play also goes back to an earlier launcher release, the same way.
- Help & logs in the launcher: the game's and the build's logs, live, with Copy and Open;
  **Report on GitHub** opens a new issue with your version and PC filled in and copies the
  log to paste into it; **Open Discussions** is for questions that are not bugs.
- Icons for the launcher (green) and the game (the logo's blue and red on black), in
  Explorer, the taskbar and the title bar.

## [0.10.2] - 2026-11-23

### Fixed
- Tower of Water's waterfall looks closer to the Xbox: bright white with fine grain at the top, thinning to
  soft streaks and mist lower down, without the bright band where its strips meet. With `framerate` above 30
  it now flows on every shown frame, not in 30-a-second steps.

## [0.10.1] - 2026-11-23

### Fixed
- Fire no longer looks like flat boxes with `framerate` above 30: torch flames and other animated sprites
  showed two halves of their animation side by side on the in-between frames.

## [0.10.0] - 2026-11-23

### Added
- The mouse pointer is hidden over the game while a controller is connected. The new setting
  `show_mouse = 1` keeps it shown; the debug menu (F1) shows it either way.

## [0.9.1] - 2026-11-23

### Fixed
- Shaders are compiled once per PC, not once per run: they are kept in a `shader_cache` folder beside
  `otogi.exe`, so the short stutters when an effect first appears do not come back after the first time.
  The folder is safe to delete.
- The game compiles the shaders it knows about before the title screen, behind a progress bar when it
  takes a moment, instead of in the middle of play.

## [0.9.0] - 2026-11-23

### Added
- PlayStation and Switch controllers work directly, without DS4Windows or Steam Input, and any
  controller can be plugged in, unplugged or swapped while playing. Rumble works on all of them.

### Changed
- The window and input now run on SDL3 (`SDL3.dll` sits beside `otogi.exe`). The picture is drawn
  the same way as before.
- The frame rate follows the monitor the window is on, also after moving it to another one.

### Fixed
- Keyboard controls work (issue #8): they were listed in the README but never reached the game.
- A controller is found whichever slot Windows gave it; before, only the first slot was read.

## [0.8.1] - 2026-11-23

### Fixed
- The game no longer stays at 30 shown frames a second after one slow moment (opening the
  pause menu, skipping a cutscene, loading a stage). It used to need a restart to get the
  higher frame rate back (issues #15 and #1).

## [0.8.0] - 2026-11-15

### Changed
- Busy scenes cost about half the CPU time they did: the second stage's 2,600-draw
  opening went from about 30 ms of work a frame to about 16 on the development PC.
  Slower laptops that dropped below 30 fps there should hold up better (issue #2).
- Drawing runs on its own thread, beside the game's. With frame interpolation on, busy
  scenes that fell short of 120 shown frames a second (the second stage's opening)
  now hold it, and the game's own work a frame dropped to a few milliseconds.
- The full-screen effects (glow, heat haze, menu tint) are copied on the graphics card
  at the render resolution instead of being read back at 640x480: sharper, and faster.
- Every merged pull request publishes its own release; the PR says how big a version step it is.

### Fixed
- Judder with `framerate` above 30: the scenery moved unevenly while the character
  looked fine. In-between frames are now drawn for the moment they are shown at,
  and when the PC cannot make them all in time it shows fewer, evenly spaced.
- `framerate = 0` follows the refresh rate of the monitor the game is on, exactly
  (a 144 Hz monitor shows 144 frames a second, was 120).
- Setup downloads everything it needs (the ANGLE and Dear ImGui libraries too) before
  translating the game, and tries a failed download three times. A network hiccup no
  longer stops the build minutes in, at the compile step.

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
