# Setup art

Bundled in otogi-setup.exe:

- `ShipporiMinchoB1-Bold.ttf`: Shippori Mincho B1 Bold by FONTDASU (https://github.com/fontdasu/ShipporiMincho),
  SIL Open Font License 1.1 (`OFL-ShipporiMinchoB1.txt`). Subset to Latin-1 plus 御伽 with
  `python -m fontTools.subset ShipporiMinchoB1-Bold.ttf --unicodes="U+0020-007E,U+00A0-00FF,U+2014,U+2018-201D,U+2026,U+5FA1,U+4F3D" --layout-features='*'`.

Not bundled: the title logo, Raikoh, the red waves, and the brush stroke are the game's own menu
textures (`menu\title.dds`, `fe_end00.dds`, `fe_bg03A.dds`, `fe_lo000.dds`). Setup reads them from the
player's disc image once it checks out.
