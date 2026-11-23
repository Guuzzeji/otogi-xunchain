# Draws the two app icons (Windows' System.Drawing, nothing to install):
#   setup/assets/otogi-xunchain.ico  the launcher: a white mark on Xbox green
#   src/otogi.ico                    the game: the logo's blue, its red kanji's dot, on black
# The mark is the "O・" of the Otogi logo (O・TGI), simplified so it reads at 16 px. Run: powershell -File setup/assets/make-icons.ps1
# -Preview <dir> also writes a 256 px PNG of each to look at.
param([string]$Preview = "")
Add-Type -AssemblyName System.Drawing

function Mark([int]$size, [string]$bg, [string]$ring, [string]$dot) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = [single]$size
    # Rounded square, small corners: the launcher's flat look.
    $r = $s * 0.16
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.AddArc(0, 0, 2 * $r, 2 * $r, 180, 90)
    $path.AddArc($s - 2 * $r, 0, 2 * $r, 2 * $r, 270, 90)
    $path.AddArc($s - 2 * $r, $s - 2 * $r, 2 * $r, 2 * $r, 0, 90)
    $path.AddArc(0, $s - 2 * $r, 2 * $r, 2 * $r, 90, 90)
    $path.CloseFigure()
    $g.FillPath((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($bg))), $path)
    # The logo's "O・": an open ring (gap at the top right, round ends), a small
    # ring inside it, and the dot beside it. Strokes thicken at small sizes.
    $k = if ($size -le 24) { 1.3 } else { 1.0 }
    $ringColor = [System.Drawing.ColorTranslator]::FromHtml($ring)
    $cx = $s * 0.45; $cy = $s * 0.55
    $pen = New-Object System.Drawing.Pen $ringColor, ($s * 0.12 * $k)
    $pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
    $pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round
    $rad = $s * 0.29
    $g.DrawArc($pen, $cx - $rad, $cy - $rad, 2 * $rad, 2 * $rad, -20, 290)
    $pen.Width = $s * 0.075 * $k
    $rad = $s * 0.12
    $g.DrawEllipse($pen, $cx - $rad, $cy - $rad, 2 * $rad, 2 * $rad)
    $d = $s * 0.075 * $k
    $g.FillEllipse((New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($dot))), $s * 0.78 - $d, $s * 0.24 - $d, 2 * $d, 2 * $d)
    $g.Dispose()
    return $bmp
}

# An .ico of PNG images, one per size (Windows Vista and later read these).
function WriteIco([string]$out, [string]$bg, [string]$ring, [string]$dot) {
    $sizes = 16, 20, 24, 32, 40, 48, 64, 128, 256
    $pngs = foreach ($n in $sizes) {
        $ms = New-Object System.IO.MemoryStream
        (Mark $n $bg $ring $dot).Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
        , $ms.ToArray()
    }
    $f = [System.IO.File]::Create($out)
    $w = New-Object System.IO.BinaryWriter $f
    $w.Write([uint16]0); $w.Write([uint16]1); $w.Write([uint16]$sizes.Count)
    $offset = 6 + 16 * $sizes.Count
    for ($i = 0; $i -lt $sizes.Count; $i++) {
        $n = $sizes[$i] % 256   # 0 means 256
        $w.Write([byte]$n); $w.Write([byte]$n); $w.Write([byte]0); $w.Write([byte]0)
        $w.Write([uint16]1); $w.Write([uint16]32)
        $w.Write([uint32]$pngs[$i].Length); $w.Write([uint32]$offset)
        $offset += $pngs[$i].Length
    }
    foreach ($p in $pngs) { $w.Write($p) }
    $w.Close()
}

$launcher = @("#107C10", "#FFFFFF", "#FFFFFF")
$game = @("#0B0F0A", "#4FA8CC", "#D0392E")
$root = Resolve-Path (Join-Path $PSScriptRoot "..\..")   # absolute: .NET does not follow Set-Location
WriteIco (Join-Path $root "setup\assets\otogi-xunchain.ico") @launcher
WriteIco (Join-Path $root "src\otogi.ico") @game
if ($Preview) {
    (Mark 256 @launcher).Save((Join-Path $Preview "icon-launcher.png"))
    (Mark 256 @game).Save((Join-Path $Preview "icon-game.png"))
    (Mark 32 @launcher).Save((Join-Path $Preview "icon-launcher-32.png"))
    (Mark 32 @game).Save((Join-Path $Preview "icon-game-32.png"))
}
