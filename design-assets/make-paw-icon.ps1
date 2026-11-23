param([string]$Out, [int]$Size = 1024, [string]$Bg = "#FFFFFF", [string]$Fg = "#000000")
Add-Type -AssemblyName System.Drawing

# Geometry designed on a 612 grid, scaled to $Size.
$s = $Size / 612.0
function P([double]$x, [double]$y) { New-Object System.Drawing.PointF ([single]($x * $s)), ([single]($y * $s)) }

$transparent = ($Bg -eq "transparent")
$fmt = if ($transparent) { [System.Drawing.Imaging.PixelFormat]::Format32bppArgb } else { [System.Drawing.Imaging.PixelFormat]::Format24bppRgb }
$bmp = New-Object System.Drawing.Bitmap $Size, $Size, $fmt
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
if ($transparent) { $g.Clear([System.Drawing.Color]::Transparent) } else { $g.Clear([System.Drawing.ColorTranslator]::FromHtml($Bg)) }
$brush = New-Object System.Drawing.SolidBrush ([System.Drawing.ColorTranslator]::FromHtml($Fg))

# Main pad: rounded triangle with a soft wavy bottom (closed Bezier path)
$pad = New-Object System.Drawing.Drawing2D.GraphicsPath
$pad.AddBezier((P 306 270), (P 338 270), (P 365 305), (P 392 343))
$pad.AddBezier((P 392 343), (P 430 392), (P 422 446), (P 378 442))
$pad.AddBezier((P 378 442), (P 350 440), (P 330 428), (P 306 428))
$pad.AddBezier((P 306 428), (P 282 428), (P 262 440), (P 234 442))
$pad.AddBezier((P 234 442), (P 190 446), (P 182 392), (P 220 343))
$pad.AddBezier((P 220 343), (P 247 305), (P 274 270), (P 306 270))
$pad.CloseFigure()
$g.FillPath($brush, $pad)

# Four toes: rotated ellipses (centre x, centre y, radius x, radius y, angle)
$toes = @(
  @(187, 292, 37, 46, -22),
  @(258, 204, 38, 48, -8),
  @(354, 204, 38, 48, 8),
  @(425, 292, 37, 46, 22)
)
foreach ($t in $toes) {
  $state = $g.Save()
  $g.TranslateTransform([single]($t[0] * $s), [single]($t[1] * $s))
  $g.RotateTransform([single]$t[4])
  $rx = $t[2] * $s; $ry = $t[3] * $s
  $g.FillEllipse($brush, [single](-$rx), [single](-$ry), [single](2 * $rx), [single](2 * $ry))
  $g.Restore($state)
}

$dir = Split-Path $Out
if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force $dir | Out-Null }
$bmp.Save($Out, [System.Drawing.Imaging.ImageFormat]::Png)
$g.Dispose(); $bmp.Dispose()
"saved $Out"
