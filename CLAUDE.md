# Otogi XUnchain

Otogi: Myth of Demons (Xbox) natively recompiled for Windows. The game's code is lifted
from the disc to C by `xboxrecomp`, linked with a Zig host, and drawn through ANGLE.
Players get `otogi-xunchain.exe`, a launcher that does the lift and build from their own disc,
edits settings, lists saves and updates itself from GitHub releases.

## Layout
- `src/`: game host, Xbox HLE, renderer (`d3d.zig`, `gl_hle.zig`), debug menu. `src/recomp/gen/` is lifted C (not in git).
- `setup/`: the launcher (Zig + RmlUi: `ui/launcher.rml`, `ui/theme.rcss`). The game's menus (F1, F10, metrics) are
  RmlUi too: `src/ui.cpp`, `src/ui/*.rml`, sharing the launcher's theme. No Dear ImGui anywhere.
- `xboxrecomp/`: vendored toolkit (git subtree). Reuse it; don't rewrite or reformat it.
- `docs/NOTES.md`: how everything works and what was found, one section per area. Add findings there.
- `docs/ROADMAP.md`: milestones and decisions.

## Build
- Zig 0.17.0. Not on PATH in this shell: prepend
  `~/AppData/Local/Microsoft/WinGet/Packages/zig.zig_Microsoft.Winget.Source_8wekyb3d8bbwe/zig-x86_64-windows-0.17.0`.
- `zig build` (game, needs the lifted C), `zig build setup`, `zig build test`. CI builds only setup and runs tests.
- Lifter: `cd xboxrecomp && ../.venv/Scripts/python -m tools.<step> ...` (exactly that prefix; it is allow-listed).
- Never commit the ISO, `game/`, `src/recomp/gen/`, `analysis/` or logs (gitignored; don't force-add).

## Working rules
- Roadmap milestones one at a time, only on the user's go-ahead. Ask before installing tools.

## Commits, PRs, releases
- Commit subjects: short, imperative, plain English, like the history
  ("Fix black worlds in glow stages; keep recorded mesh indices").
- Every PR uses `.github/pull_request_template.md`: summary in player-facing words, what was tested,
  and **exactly one** box ticked under Release (major / minor / patch / none). The PR check fails otherwise.
- Unless the box is none, add an entry under `## [Unreleased]` in `CHANGELOG.md` (Added / Changed / Fixed),
  written for players.
- Never edit `.version` in `build.zig.zon` or add a version section to the changelog by hand. Merging a PR
  releases nothing. The user runs Actions > Release > Run workflow (`release.yml`): by default it bumps by the
  biggest box among PRs merged since the last tag, dates the changelog section, tags, builds setup and
  publishes the GitHub release.
- Pre-1.0 bump guide: minor = new feature or setting, patch = fixes and speedups, major = breaks saves/settings.
