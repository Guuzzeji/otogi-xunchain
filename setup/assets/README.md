# Setup art

Bundled in otogi-setup.exe:

- `ShipporiMinchoB1-Bold.ttf`: Shippori Mincho B1 Bold by FONTDASU (https://github.com/fontdasu/ShipporiMincho),
  SIL Open Font License 1.1 (`OFL-ShipporiMinchoB1.txt`). Subset to Latin-1 plus 御伽 with
  `python -m fontTools.subset ShipporiMinchoB1-Bold.ttf --unicodes="U+0020-007E,U+00A0-00FF,U+2014,U+2018-201D,U+2026,U+5FA1,U+4F3D" --layout-features='*'`.

`art/`: the game's own menu textures, ripped from the disc (`menu/` on the Otogi USA disc) so setup looks
like the game before any disc is picked. They are FromSoftware/Sega's, shipped by the project owner's choice
(2026-11-01) as the one exception to the no-game-data rule in docs/ROADMAP.md.

- `title.jpg`: `menu/title.dds` (1024x512, BGRA, composited on black), the logo on the title brocade.
- `raikoh.jpg`: `menu/fe_end00.dds` (DXT1), Raikoh with his sword.
- `waves.jpg`: `menu/fe_bg03A.dds` (DXT1), the red waves brocade.
- `brush.png`: `menu/fe_lo000.dds` (DXT3), the red brush stroke; PNG for its alpha.

Decoded with a small DXT1/3/5 reader, saved as JPEG quality 90.
