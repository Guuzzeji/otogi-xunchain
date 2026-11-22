# Launcher art

Bundled in otogi-xunchain.exe (the launcher):

- `ShipporiMinchoB1-Bold.ttf`: Shippori Mincho B1 Bold by FONTDASU (https://github.com/fontdasu/ShipporiMincho),
  SIL Open Font License 1.1 (`OFL-ShipporiMinchoB1.txt`). Subset to Latin-1 plus 御伽 with
  `python -m fontTools.subset ShipporiMinchoB1-Bold.ttf --unicodes="U+0020-007E,U+00A0-00FF,U+2014,U+2018-201D,U+2026,U+5FA1,U+4F3D" --layout-features='*'`.

`art/`: the game's own menu textures, ripped from the disc (`menu/` on the Otogi USA disc) so the launcher looks
like the game before any disc is picked. They are FromSoftware/Sega's, shipped by the project owner's choice
(2026-11-01) as the one exception to the no-game-data rule in docs/ROADMAP.md.

- `title.jpg`: `menu/title.dds` (1024x512, BGRA, composited on black), the logo on the title brocade.
- `raikoh.jpg`: `menu/fe_end00.dds` (DXT1), Raikoh with his sword.
- `brush.png`: `menu/fe_lo000.dds` (DXT3), the red brush stroke; PNG for its alpha.

Decoded with a small DXT1/3/5 reader, saved as JPEG quality 90.

`otogi-xunchain.ico` (the launcher's icon) and `src/otogi.ico` (the game's) are drawn by `make-icons.ps1`
(System.Drawing, no tools to install): the logo's "O・" as an open ring, a ring inside it and the dot beside it,
white on Xbox green for the launcher, the logo's blue with a red dot on black for the game. Each `.ico` holds
PNGs from 16 to 256 px. Rerun the script after changing it; `setup/launcher.rc` and `src/otogi.rc` embed them.
