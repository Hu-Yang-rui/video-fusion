<#
    video_fusion -- launcher icon generator
    =====================================================================
    Single geometry source: one 108x108 unit coordinate system drives both
      1) the vector drawables of the Android adaptive icon
      2) the legacy PNG fallbacks for API 24-25 (mdpi..xxxhdpi)

    IMPORTANT: this script is deliberately ASCII-only. Windows PowerShell 5.1
    decodes a BOM-less .ps1 with the system ANSI code page, so any non-ASCII
    literal (a Chinese comment, for instance) gets silently double-encoded and
    ends up as mojibake inside the generated XML. Keep it ASCII.

    Usage:  powershell -ExecutionPolicy Bypass -File tool\gen_launcher_icons.ps1
    Deps:   .NET System.Drawing (ships with Windows)
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$ResRoot = Join-Path $PSScriptRoot '..\android\app\src\main\res'
$ResRoot = [System.IO.Path]::GetFullPath($ResRoot)
if (-not (Test-Path $ResRoot)) { throw "res dir not found: $ResRoot" }

# ---- design constants ---------------------------------------------------
$Canvas       = 108.0    # adaptive icon canvas edge
$Center       = 54.0     # canvas centre
$CornerRadius = 7.0      # play-triangle corner radius
$EchoDX       = -10.0    # back layer offset: pure horizontal, so the pair
$EchoDY       = 0.0      # reads as stacked layers rather than a drop shadow
$EchoAlpha    = 0.45
$SafeRadius   = 33.0     # safe circle radius (66dp diameter)

$ColorTop     = [System.Drawing.Color]::FromArgb(255, 0x0A, 0x84, 0xFF)  # #0A84FF
$ColorMid     = [System.Drawing.Color]::FromArgb(255, 0x3B, 0x6B, 0xF0)  # #3B6BF0
$ColorBottom  = [System.Drawing.Color]::FromArgb(255, 0x5E, 0x5C, 0xE6)  # #5E5CE6
$ColorGlyph   = [System.Drawing.Color]::White
$EchoAlpha255 = [int]($EchoAlpha * 255)
$ColorGlyphEcho = [System.Drawing.Color]::FromArgb($EchoAlpha255, 255, 255, 255)

# ---- rounded polygon geometry -------------------------------------------
function Get-RoundedPolygonGeometry {
    param(
        [Parameter(Mandatory)][object[]]$Points,
        [Parameter(Mandatory)][double]$Radius
    )
    $n = $Points.Count
    $tanIn  = New-Object 'System.Collections.Generic.List[object]'
    $tanOut = New-Object 'System.Collections.Generic.List[object]'
    for ($i = 0; $i -lt $n; $i++) {
        $p    = $Points[$i]
        $prev = $Points[($i - 1 + $n) % $n]
        $next = $Points[($i + 1) % $n]
        $vix = $p[0] - $prev[0]; $viy = $p[1] - $prev[1]
        $vox = $next[0] - $p[0]; $voy = $next[1] - $p[1]
        $li = [math]::Sqrt($vix * $vix + $viy * $viy)
        $lo = [math]::Sqrt($vox * $vox + $voy * $voy)
        # a corner radius may not exceed half an edge or neighbours overlap
        $r = [math]::Min($Radius, [math]::Min($li, $lo) * 0.45)
        $tanIn.Add(@(($p[0] - $vix / $li * $r), ($p[1] - $viy / $li * $r)))
        $tanOut.Add(@(($p[0] + $vox / $lo * $r), ($p[1] + $voy / $lo * $r)))
    }
    [pscustomobject]@{ Points = $Points; TanIn = $tanIn; TanOut = $tanOut; N = $n }
}

$Inv = [System.Globalization.CultureInfo]::InvariantCulture
function Format-Num([double]$v) {
    return ([math]::Round($v, 2)).ToString('0.##', $Inv)
}

# quadratic bezier -> exactly equivalent cubic bezier, emitted as pathData
function Get-VectorPathData {
    param([Parameter(Mandatory)]$Geo)
    $n = $Geo.N; $pts = $Geo.Points; $tin = $Geo.TanIn; $tout = $Geo.TanOut
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append('M ' + (Format-Num $tin[0][0]) + ',' + (Format-Num $tin[0][1]) + ' ')
    for ($i = 0; $i -lt $n; $i++) {
        $p = $pts[$i]; $a = $tin[$i]; $b = $tout[$i]
        $c1x = $a[0] + 2.0 / 3.0 * ($p[0] - $a[0]); $c1y = $a[1] + 2.0 / 3.0 * ($p[1] - $a[1])
        $c2x = $b[0] + 2.0 / 3.0 * ($p[0] - $b[0]); $c2y = $b[1] + 2.0 / 3.0 * ($p[1] - $b[1])
        [void]$sb.Append('C ' + (Format-Num $c1x) + ',' + (Format-Num $c1y) + ' ' +
                                (Format-Num $c2x) + ',' + (Format-Num $c2y) + ' ' +
                                (Format-Num $b[0]) + ',' + (Format-Num $b[1]) + ' ')
        if ($i -lt $n - 1) {
            $nx = $tin[$i + 1]
            [void]$sb.Append('L ' + (Format-Num $nx[0]) + ',' + (Format-Num $nx[1]) + ' ')
        }
    }
    [void]$sb.Append('Z')
    return $sb.ToString()
}

function New-GdiPath {
    param([Parameter(Mandatory)]$Geo)
    $path = New-Object System.Drawing.Drawing2D.GraphicsPath
    $n = $Geo.N; $pts = $Geo.Points; $tin = $Geo.TanIn; $tout = $Geo.TanOut
    $path.StartFigure()
    $last = $tout[$n - 1]; $first = $tin[0]
    $path.AddLine([single]$last[0], [single]$last[1], [single]$first[0], [single]$first[1])
    for ($i = 0; $i -lt $n; $i++) {
        $p = $pts[$i]; $a = $tin[$i]; $b = $tout[$i]
        $c1x = $a[0] + 2.0 / 3.0 * ($p[0] - $a[0]); $c1y = $a[1] + 2.0 / 3.0 * ($p[1] - $a[1])
        $c2x = $b[0] + 2.0 / 3.0 * ($p[0] - $b[0]); $c2y = $b[1] + 2.0 / 3.0 * ($p[1] - $b[1])
        $path.AddBezier(
            [single]$a[0],  [single]$a[1],
            [single]$c1x,    [single]$c1y,
            [single]$c2x,    [single]$c2y,
            [single]$b[0],   [single]$b[1])
        if ($i -lt $n - 1) {
            $nx = $tin[$i + 1]
            $path.AddLine([single]$b[0], [single]$b[1], [single]$nx[0], [single]$nx[1])
        }
    }
    $path.CloseFigure()
    return $path
}

# ---- shapes (108 unit canvas) -------------------------------------------
# Play triangle: A top-left, B bottom-left, C right tip. The pair (front plus
# back layer) sits right of the canvas centre for optical balance, because a
# right-pointing triangle's visual mass is left of its bounding box.
# 39 x 48 units -> ~54% of the 72dp guaranteed-visible width.
$TrianglePts = @(
    @(43.0, 30.0),
    @(43.0, 78.0),
    @(82.0, 54.0)
)
$MainGeo = Get-RoundedPolygonGeometry -Points $TrianglePts -Radius $CornerRadius

$EchoPts = @()
foreach ($p in $TrianglePts) { $EchoPts += , @(($p[0] + $EchoDX), ($p[1] + $EchoDY)) }
$EchoGeo = Get-RoundedPolygonGeometry -Points $EchoPts -Radius $CornerRadius

# safe-zone self check: every vertex must sit inside the 66dp safe circle
$maxR = 0.0
foreach ($geo in @($MainGeo, $EchoGeo)) {
    foreach ($p in $geo.Points) {
        $r = [math]::Sqrt([math]::Pow($p[0] - $Center, 2) + [math]::Pow($p[1] - $Center, 2))
        if ($r -gt $maxR) { $maxR = $r }
    }
}
$verdict = if ($maxR -lt $SafeRadius) { 'OK' } else { 'FAIL' }
Write-Host ('[safe-zone] farthest vertex radius = {0:N2} / safe radius {1} -> {2}' -f $maxR, $SafeRadius, $verdict)
if ($maxR -ge $SafeRadius) { throw 'glyph escapes the adaptive-icon safe circle' }

$mainPathData = Get-VectorPathData -Geo $MainGeo
$echoPathData = Get-VectorPathData -Geo $EchoGeo
$echoHex = '#{0:X2}FFFFFF' -f $EchoAlpha255

# ---- 1. vector drawables ------------------------------------------------
$drawableDir = Join-Path $ResRoot 'drawable'
New-Item -ItemType Directory -Force -Path $drawableDir | Out-Null

$fgXml = @"
<?xml version="1.0" encoding="utf-8"?>
<!--
    video_fusion - adaptive icon FOREGROUND layer.
    108dp canvas. Everything sits inside the central 66dp safe circle; the
    outer 18dp band is cropped by the launcher mask. Generated by
    tool/gen_launcher_icons.ps1 - the geometry is shared with the legacy
    mipmap-* PNGs, so edit the script rather than this file.
-->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">

    <!-- Back layer: same play mark shifted left, so the pair reads as two
         stacked streams fusing into one. -->
    <path
        android:fillColor="$echoHex"
        android:pathData="$echoPathData" />

    <!-- Front layer: solid white play mark with softened corners. -->
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="$mainPathData" />
</vector>
"@

$bgXml = @"
<?xml version="1.0" encoding="utf-8"?>
<!--
    video_fusion - adaptive icon BACKGROUND layer.
    Diagonal gradient #0A84FF -> #3B6BF0 -> #5E5CE6: Apple system blue into
    system indigo. Deliberately free of any video-platform brand colour.
-->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">

    <path android:pathData="M0,0h108v108h-108z">
        <aapt:attr name="android:fillColor">
            <gradient
                android:type="linear"
                android:startX="0"
                android:startY="0"
                android:endX="108"
                android:endY="108">
                <item android:offset="0" android:color="#FF0A84FF" />
                <item android:offset="0.55" android:color="#FF3B6BF0" />
                <item android:offset="1" android:color="#FF5E5CE6" />
            </gradient>
        </aapt:attr>
    </path>
</vector>
"@

# Themed icons (Android 13+) consume only the alpha channel, so the monochrome
# layer is a single solid silhouette - the back layer would merge into a blob.
$monoXml = @"
<?xml version="1.0" encoding="utf-8"?>
<!--
    video_fusion - MONOCHROME layer for themed icons (Android 13+).
    The system tints this silhouette with the wallpaper palette, so it is one
    solid shape; the translucent back layer is intentionally omitted.
-->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">

    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="$mainPathData" />
</vector>
"@

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)
[System.IO.File]::WriteAllText((Join-Path $drawableDir 'ic_launcher_foreground.xml'), $fgXml, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $drawableDir 'ic_launcher_background.xml'), $bgXml, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $drawableDir 'ic_launcher_monochrome.xml'), $monoXml, $utf8NoBom)

# ---- 2. mipmap-anydpi-v26 adaptive icon --------------------------------
$anydpiDir = Join-Path $ResRoot 'mipmap-anydpi-v26'
New-Item -ItemType Directory -Force -Path $anydpiDir | Out-Null

$adaptiveXml = @"
<?xml version="1.0" encoding="utf-8"?>
<!-- video_fusion - adaptive launcher icon (Android 8.0+). -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
"@

$adaptiveRoundXml = @"
<?xml version="1.0" encoding="utf-8"?>
<!-- video_fusion - round-mask launcher icon. Same adaptive layers; the
     launcher applies the circular mask itself. -->
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@drawable/ic_launcher_foreground" />
    <monochrome android:drawable="@drawable/ic_launcher_monochrome" />
</adaptive-icon>
"@

[System.IO.File]::WriteAllText((Join-Path $anydpiDir 'ic_launcher.xml'), $adaptiveXml, $utf8NoBom)
[System.IO.File]::WriteAllText((Join-Path $anydpiDir 'ic_launcher_round.xml'), $adaptiveRoundXml, $utf8NoBom)

# ---- 3. legacy PNGs (API 24-25 fallback) -------------------------------
$densities = @(
    @{ Dir = 'mipmap-mdpi';    Size = 48  },
    @{ Dir = 'mipmap-hdpi';    Size = 72  },
    @{ Dir = 'mipmap-xhdpi';   Size = 96  },
    @{ Dir = 'mipmap-xxhdpi';  Size = 144 },
    @{ Dir = 'mipmap-xxxhdpi'; Size = 192 }
)

# The adaptive icon shows only the central 72 of its 108 units, so the same
# glyph on a full 108-unit legacy canvas must be ~1.5x larger to keep the same
# on-screen weight. 1.42 keeps the back layer clear of the edge.
$GlyphScale = 1.42
# The round variant loses the corners of its bounding box, so it needs a
# slightly smaller glyph to keep the same apparent size inside the circle.
$GlyphScaleRound = 1.24
$LegacyCornerRatio = 0.205
$SS = 4

$mainGdi = New-GdiPath -Geo $MainGeo
$echoGdi = New-GdiPath -Geo $EchoGeo

function New-GlyphMatrix {
    param([double]$Scale)
    $m = New-Object System.Drawing.Drawing2D.Matrix
    $m.Translate([single](-$Center), [single](-$Center), [System.Drawing.Drawing2D.MatrixOrder]::Append)
    $m.Scale([single]$Scale, [single]$Scale, [System.Drawing.Drawing2D.MatrixOrder]::Append)
    $m.Translate([single]$Center, [single]$Center, [System.Drawing.Drawing2D.MatrixOrder]::Append)
    return $m
}

$glyphMatrix      = New-GlyphMatrix -Scale $GlyphScale
$glyphMatrixRound = New-GlyphMatrix -Scale $GlyphScaleRound

function New-GradientBrush {
    $ptA = New-Object System.Drawing.PointF ([single]0), ([single]0)
    $ptB = New-Object System.Drawing.PointF ([single]$Canvas), ([single]$Canvas)
    $br = New-Object System.Drawing.Drawing2D.LinearGradientBrush($ptA, $ptB, $ColorTop, $ColorBottom)
    $bl = New-Object System.Drawing.Drawing2D.ColorBlend 3
    $bl.Colors    = @($ColorTop, $ColorMid, $ColorBottom)
    $bl.Positions = @(0.0, 0.55, 1.0)
    $br.InterpolationColors = $bl
    return $br
}

$results = @()

foreach ($d in $densities) {
    $size = [int]$d.Size
    $dir  = Join-Path $ResRoot $d.Dir
    New-Item -ItemType Directory -Force -Path $dir | Out-Null

    foreach ($variant in @('square', 'round')) {
        if ($variant -eq 'square') {
            $outPath = Join-Path $dir 'ic_launcher.png'
            $gm      = $glyphMatrix
        } else {
            $outPath = Join-Path $dir 'ic_launcher_round.png'
            $gm      = $glyphMatrixRound
        }

        $W = $size * $SS
        $bmp = New-Object System.Drawing.Bitmap $W, $W, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $g = [System.Drawing.Graphics]::FromImage($bmp)
        $g.SmoothingMode      = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
        $g.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $g.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $g.Clear([System.Drawing.Color]::Transparent)
        # from here on every coordinate is in 108-unit space
        $g.ScaleTransform([single]($W / $Canvas), [single]($W / $Canvas))

        # background plate: circle for the round variant, rounded rect otherwise
        $bgPath = New-Object System.Drawing.Drawing2D.GraphicsPath
        if ($variant -eq 'round') {
            $bgPath.AddEllipse([single]0, [single]0, [single]$Canvas, [single]$Canvas)
        } else {
            $r  = $Canvas * $LegacyCornerRatio
            $d2 = $r * 2
            $bgPath.AddArc([single]0, [single]0, [single]$d2, [single]$d2, 180, 90)
            $bgPath.AddArc([single]($Canvas - $d2), [single]0, [single]$d2, [single]$d2, 270, 90)
            $bgPath.AddArc([single]($Canvas - $d2), [single]($Canvas - $d2), [single]$d2, [single]$d2, 0, 90)
            $bgPath.AddArc([single]0, [single]($Canvas - $d2), [single]$d2, [single]$d2, 90, 90)
            $bgPath.CloseFigure()
        }

        $gradBrush = New-GradientBrush
        $g.FillPath($gradBrush, $bgPath)

        # keep the glyph inside the background plate
        $g.SetClip($bgPath, [System.Drawing.Drawing2D.CombineMode]::Intersect)

        # foreground: back layer, then front layer
        $echoDraw = $echoGdi.Clone()
        $echoDraw.Transform($gm)
        $echoBrush = New-Object System.Drawing.SolidBrush $ColorGlyphEcho
        $g.FillPath($echoBrush, $echoDraw)

        $mainDraw = $mainGdi.Clone()
        $mainDraw.Transform($gm)
        $mainBrush = New-Object System.Drawing.SolidBrush $ColorGlyph
        $g.FillPath($mainBrush, $mainDraw)

        $g.ResetClip()
        $g.Dispose()

        # supersampled downsample
        $small = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $gs = [System.Drawing.Graphics]::FromImage($small)
        $gs.InterpolationMode  = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $gs.PixelOffsetMode    = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
        $gs.CompositingQuality = [System.Drawing.Drawing2D.CompositingQuality]::HighQuality
        $gs.Clear([System.Drawing.Color]::Transparent)
        $rect = New-Object System.Drawing.Rectangle 0, 0, $size, $size
        $gs.DrawImage($bmp, $rect)
        $gs.Dispose()

        $small.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
        $small.Dispose()
        $bmp.Dispose()
        $gradBrush.Dispose(); $echoBrush.Dispose(); $mainBrush.Dispose()
        $bgPath.Dispose(); $echoDraw.Dispose(); $mainDraw.Dispose()

        $results += [pscustomobject]@{ Path = $outPath; Size = $size }
    }
}

$glyphMatrix.Dispose(); $glyphMatrixRound.Dispose()
$mainGdi.Dispose(); $echoGdi.Dispose()

Write-Host ''
Write-Host 'generated:'
foreach ($x in $results) { Write-Host ('  {0}  ({1}x{1})' -f $x.Path, $x.Size) }
Write-Host ('  ' + (Join-Path $drawableDir 'ic_launcher_foreground.xml'))
Write-Host ('  ' + (Join-Path $drawableDir 'ic_launcher_background.xml'))
Write-Host ('  ' + (Join-Path $drawableDir 'ic_launcher_monochrome.xml'))
Write-Host ('  ' + (Join-Path $anydpiDir 'ic_launcher.xml'))
Write-Host ('  ' + (Join-Path $anydpiDir 'ic_launcher_round.xml'))
Write-Host ''
Write-Host ('front pathData: ' + $mainPathData)
Write-Host ('back  pathData: ' + $echoPathData)
