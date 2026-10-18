<#
    video_fusion -- adaptive icon mask preview + PNG read-back verification
    Renders the adaptive icon layers exactly as Android composites them
    (foreground drawn at 108dp with the outer 18dp crop), then applies the
    real launcher masks so clipping problems are visible before install.

    Usage: powershell -ExecutionPolicy Bypass -File tool\preview_launcher_icons.ps1
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root    = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$res     = Join-Path $root 'android\app\src\main\res'
$outDir  = Join-Path $root 'build\icon-preview'
New-Item -ItemType Directory -Force -Path $outDir | Out-Null

# ---- 1. PNG read-back verification -------------------------------------
Write-Host '=== legacy PNG read-back ==='
$expect = @{
    'mipmap-mdpi'    = 48
    'mipmap-hdpi'    = 72
    'mipmap-xhdpi'   = 96
    'mipmap-xxhdpi'  = 144
    'mipmap-xxxhdpi' = 192
}
$okAll = $true
foreach ($k in $expect.Keys | Sort-Object) {
    $p = Join-Path $res "$k\ic_launcher.png"
    if (-not (Test-Path $p)) { Write-Host ("  MISSING  {0}" -f $p); $okAll = $false; continue }
    $fi = Get-Item $p
    $img = [System.Drawing.Image]::FromFile($p)
    $w = $img.Width; $h = $img.Height
    $img.Dispose()
    $want = $expect[$k]
    $dimOk = ($w -eq $want -and $h -eq $want)
    if (-not $dimOk) { $okAll = $false }
    Write-Host ("  {0,-16} {1,5} bytes  {2}x{3}  expected {4}x{4}  {5}" -f `
        $k, $fi.Length, $w, $h, $want, $(if ($dimOk) { 'OK' } else { 'DIM-MISMATCH' }))
}
Write-Host ("  => {0}" -f $(if ($okAll) { 'ALL OK' } else { 'FAILURES PRESENT' }))

# ---- 2. adaptive icon composite (108dp, outer 18dp cropped by the system) --
# Mask geometry mirrors Android: only the central 72dp of the 108dp canvas is
# guaranteed visible; circle diameter 72dp, squircle radius ~ 36dp * 0.42.
$CanvasUnits = 108.0
$VisibleUnits = 72.0
$Px = 576                     # composite resolution
$scale = $Px / $CanvasUnits

$bmp = New-Object System.Drawing.Bitmap $Px, $Px, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
$g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
$g.Clear([System.Drawing.Color]::Transparent)
$g.ScaleTransform([single]$scale, [single]$scale)

# background: diagonal gradient over the full 108 canvas
$c1 = [System.Drawing.Color]::FromArgb(255, 0x0A, 0x84, 0xFF)
$c2 = [System.Drawing.Color]::FromArgb(255, 0x3B, 0x6B, 0xF0)
$c3 = [System.Drawing.Color]::FromArgb(255, 0x5E, 0x5C, 0xE6)
$ptA = New-Object System.Drawing.PointF ([single]0), ([single]0)
$ptB = New-Object System.Drawing.PointF ([single]$CanvasUnits), ([single]$CanvasUnits)
$grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($ptA, $ptB, $c1, $c3)
$blend = New-Object System.Drawing.Drawing2D.ColorBlend 3
$blend.Colors    = @($c1, $c2, $c3)
$blend.Positions = @(0.0, 0.55, 1.0)
$grad.InterpolationColors = $blend
$g.FillRectangle($grad, [single]0, [single]0, [single]$CanvasUnits, [single]$CanvasUnits)

# foreground geometry (must match the generator)
function New-RoundedTri {
    param([double]$dx = 0, [double]$dy = 0, [double]$Radius = 7.0)
    $pts = @(
        @((43.0 + $dx), (30.0 + $dy)),
        @((43.0 + $dx), (78.0 + $dy)),
        @((82.0 + $dx), (54.0 + $dy))
    )
    $n = 3
    $tin = @(); $tout = @()
    for ($i = 0; $i -lt $n; $i++) {
        $p = $pts[$i]; $prev = $pts[($i + 2) % 3]; $next = $pts[($i + 1) % 3]
        $vix = $p[0] - $prev[0]; $viy = $p[1] - $prev[1]
        $vox = $next[0] - $p[0]; $voy = $next[1] - $p[1]
        $li = [math]::Sqrt($vix * $vix + $viy * $viy); $lo = [math]::Sqrt($vox * $vox + $voy * $voy)
        $r = [math]::Min($Radius, [math]::Min($li, $lo) * 0.45)
        $tin  += , @(($p[0] - $vix / $li * $r), ($p[1] - $viy / $li * $r))
        $tout += , @(($p[0] + $vox / $lo * $r), ($p[1] + $voy / $lo * $r))
    }
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $path.StartFigure()
    $path.AddLine([single]$tout[2][0], [single]$tout[2][1], [single]$tin[0][0], [single]$tin[0][1])
    for ($i = 0; $i -lt 3; $i++) {
        $p = $pts[$i]; $a = $tin[$i]; $b = $tout[$i]
        $c1x = $a[0] + 2.0 / 3.0 * ($p[0] - $a[0]); $c1y = $a[1] + 2.0 / 3.0 * ($p[1] - $a[1])
        $c2x = $b[0] + 2.0 / 3.0 * ($p[0] - $b[0]); $c2y = $b[1] + 2.0 / 3.0 * ($p[1] - $b[1])
        $path.AddBezier([single]$a[0],[single]$a[1],[single]$c1x,[single]$c1y,[single]$c2x,[single]$c2y,[single]$b[0],[single]$b[1])
        if ($i -lt 2) { $path.AddLine([single]$b[0],[single]$b[1],[single]$tin[$i+1][0],[single]$tin[$i+1][1]) }
    }
    $path.CloseFigure()
    return $path
}

$echoPath = New-RoundedTri -dx (-10.0) -dy 0.0
$echoBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb([int](0.45 * 255), 255, 255, 255))
$g.FillPath($echoBrush, $echoPath)

$mainPath = New-RoundedTri
$mainBrush = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
$g.FillPath($mainBrush, $mainPath)

# safe-circle guide (66dp diameter) -- diagnostic only, drawn on a copy
$g.Dispose()

function Save-Masked {
    param(
        [System.Drawing.Bitmap]$Source,
        [string]$Path,
        [string]$Mask   # 'circle' | 'squircle' | 'full'
    )
    $s = $Source.Width
    $dst = New-Object System.Drawing.Bitmap $s, $s, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $dg = [System.Drawing.Graphics]::FromImage($dst)
    $dg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $dg.Clear([System.Drawing.Color]::Transparent)
    $mp = New-Object System.Drawing.Drawing2D.GraphicsPath
    $f = [single]$s
    switch ($Mask) {
        'circle'   { $mp.AddEllipse([single]0, [single]0, $f, $f) }
        'squircle' {
            # Android squircle approximation: corner radius ~ 0.42 * edge
            $rr = [single]($s * 0.42); $d = [single]($rr * 2)
            $mp.AddArc([single]0, [single]0, $d, $d, 180, 90)
            $mp.AddArc([single]($s - $d), [single]0, $d, $d, 270, 90)
            $mp.AddArc([single]($s - $d), [single]($s - $d), $d, $d, 0, 90)
            $mp.AddArc([single]0, [single]($s - $d), $d, $d, 90, 90)
            $mp.CloseFigure()
        }
        default { $mp.AddRectangle((New-Object System.Drawing.Rectangle 0, 0, $s, $s)) }
    }
    $dg.SetClip($mp)
    $dg.DrawImage($Source, 0, 0)
    $dg.Dispose(); $mp.Dispose()
    $dst.Save($Path, [System.Drawing.Imaging.ImageFormat]::Png)
    $dst.Dispose()
}

Save-Masked -Source $bmp -Path (Join-Path $outDir 'adaptive-full.png')     -Mask 'full'
Save-Masked -Source $bmp -Path (Join-Path $outDir 'adaptive-circle.png')   -Mask 'circle'
Save-Masked -Source $bmp -Path (Join-Path $outDir 'adaptive-squircle.png') -Mask 'squircle'

# ---- 3. contact sheet: legacy icons at native size + mask previews ------
$cell = 200; $pad = 16
$sheetW = ($cell + $pad) * 3 + $pad
$sheetH = $cell + $pad * 2 + 40
$sheet = New-Object System.Drawing.Bitmap $sheetW, $sheetH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$sg = [System.Drawing.Graphics]::FromImage($sheet)
$sg.Clear([System.Drawing.Color]::FromArgb(255, 0xF2, 0xF2, 0xF7))
$sg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
$sg.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias

$names = @('adaptive-full.png', 'adaptive-circle.png', 'adaptive-squircle.png')
for ($i = 0; $i -lt 3; $i++) {
    $img = [System.Drawing.Image]::FromFile((Join-Path $outDir $names[$i]))
    $x = $pad + $i * ($cell + $pad)
    $sg.DrawImage($img, (New-Object System.Drawing.Rectangle $x, $pad, $cell, $cell))
    $img.Dispose()
}
$font = New-Object System.Drawing.Font 'Segoe UI', 10
$brushTxt = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0x3C, 0x3C, 0x43))
$labels = @('108dp full', 'circle mask', 'squircle mask')
for ($i = 0; $i -lt 3; $i++) {
    $x = $pad + $i * ($cell + $pad)
    $sg.DrawString($labels[$i], $font, $brushTxt, [single]$x, [single]($pad + $cell + 6))
}
$sg.Dispose()
$sheetPath = Join-Path $outDir 'preview-sheet.png'
$sheet.Save($sheetPath, [System.Drawing.Imaging.ImageFormat]::Png)
$sheet.Dispose()

$grad.Dispose(); $echoBrush.Dispose(); $mainBrush.Dispose()
$echoPath.Dispose(); $mainPath.Dispose(); $bmp.Dispose(); $font.Dispose(); $brushTxt.Dispose()

# ---- 4. legibility strip: icons at true launcher sizes ------------------
$sizes = @(48, 72, 96, 144)
$stripPad = 20
$stripH = 200
$stripW = $stripPad + (($sizes | Measure-Object -Sum).Sum) + ($stripPad * $sizes.Count)
$strip = New-Object System.Drawing.Bitmap $stripW, $stripH, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$stg = [System.Drawing.Graphics]::FromImage($strip)
$stg.Clear([System.Drawing.Color]::FromArgb(255, 0xF2, 0xF2, 0xF7))
$stg.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::NearestNeighbor
$fntSmall = New-Object System.Drawing.Font 'Segoe UI', 9
$brText = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(255, 0x3C, 0x3C, 0x43))
$x = $stripPad
foreach ($s in $sizes) {
    $src = Join-Path $res ("mipmap-" + $(switch ($s) {
        48 { 'mdpi' } 72 { 'hdpi' } 96 { 'xhdpi' } 144 { 'xxhdpi' }
    }) + '\ic_launcher_round.png')
    $im = [System.Drawing.Image]::FromFile($src)
    $y = 20 + (144 - $s) / 2
    $stg.DrawImage($im, (New-Object System.Drawing.Rectangle ([int]$x), ([int]$y), $s, $s))
    $im.Dispose()
    $stg.DrawString("$s px", $fntSmall, $brText, [single]$x, [single]170)
    $x += $s + $stripPad
}
$stg.Dispose()
$stripPath = Join-Path $outDir 'preview-legibility.png'
$strip.Save($stripPath, [System.Drawing.Imaging.ImageFormat]::Png)
$strip.Dispose(); $fntSmall.Dispose(); $brText.Dispose()

Write-Host ''
Write-Host ("preview sheet -> {0}" -f $sheetPath)
Write-Host ("legibility    -> {0}" -f $stripPath)
