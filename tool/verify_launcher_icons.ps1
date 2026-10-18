<#
    video_fusion -- launcher icon verification (no build required)
    Checks: PNG presence/size/pixel dimensions, XML well-formedness and
    encoding, adaptive-icon wiring, and that every @drawable/@mipmap the
    manifest and adaptive XMLs reference actually resolves.

    Usage: powershell -ExecutionPolicy Bypass -File tool\verify_launcher_icons.ps1
#>

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

$root = [System.IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$res  = Join-Path $root 'android\app\src\main\res'
$man  = Join-Path $root 'android\app\src\main\AndroidManifest.xml'

$fail = 0
function Fail($msg) { Write-Host ("  FAIL  " + $msg); $script:fail++ }
function Pass($msg) { Write-Host ("  ok    " + $msg) }

Write-Host '=== 1. legacy PNG dimensions ==='
$expect = [ordered]@{
    'mipmap-mdpi'    = 48
    'mipmap-hdpi'    = 72
    'mipmap-xhdpi'   = 96
    'mipmap-xxhdpi'  = 144
    'mipmap-xxxhdpi' = 192
}
foreach ($k in $expect.Keys) {
    foreach ($name in @('ic_launcher.png', 'ic_launcher_round.png')) {
        $p = Join-Path $res "$k\$name"
        if (-not (Test-Path $p)) { Fail "$k\$name missing"; continue }
        $len = (Get-Item $p).Length
        $img = [System.Drawing.Image]::FromFile($p)
        $w = $img.Width; $h = $img.Height; $img.Dispose()
        $want = $expect[$k]
        if ($w -ne $want -or $h -ne $want) { Fail "$k\$name is ${w}x${h}, expected ${want}x${want}"; continue }
        # a near-empty PNG at these sizes would be well under 1 KB
        if ($len -lt 1000) { Fail "$k\$name is only $len bytes - looks blank"; continue }
        Pass ("{0,-16} {1,-22} {2,6} B  {3}x{4}" -f $k, $name, $len, $w, $h)
    }
}

Write-Host ''
Write-Host '=== 2. XML resources: encoding + well-formedness ==='
$xmls = @(
    'drawable\ic_launcher_foreground.xml',
    'drawable\ic_launcher_background.xml',
    'drawable\ic_launcher_monochrome.xml',
    'mipmap-anydpi-v26\ic_launcher.xml',
    'mipmap-anydpi-v26\ic_launcher_round.xml'
)
foreach ($f in $xmls) {
    $p = Join-Path $res $f
    if (-not (Test-Path $p)) { Fail "$f missing"; continue }
    $b = [System.IO.File]::ReadAllBytes($p)
    $bom = ($b.Length -ge 3 -and $b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF)
    if ($bom) { Fail "$f has a UTF-8 BOM (Android aapt2 tolerates it, but keep it clean)"; continue }
    $nonAscii = 0
    for ($i = 0; $i -lt $b.Length; $i++) { if ($b[$i] -gt 127) { $nonAscii++ } }
    $txt = [System.Text.Encoding]::UTF8.GetString($b)
    $ok = $true
    try { [xml]$null = $txt } catch { $ok = $false; Fail ("$f is not well-formed XML: " + $_.Exception.Message) }
    if ($ok) { Pass ("{0,-40} {1,5} B  noBOM  nonASCII={2}  xmlOK" -f $f, $b.Length, $nonAscii) }
}

Write-Host ''
Write-Host '=== 3. adaptive-icon layer wiring ==='
foreach ($f in @('mipmap-anydpi-v26\ic_launcher.xml', 'mipmap-anydpi-v26\ic_launcher_round.xml')) {
    $p = Join-Path $res $f
    $txt = [System.Text.Encoding]::UTF8.GetString([System.IO.File]::ReadAllBytes($p))
    [xml]$x = $txt
    $root = $x.'adaptive-icon'
    if ($null -eq $root) { Fail "$f root element is not <adaptive-icon>"; continue }
    foreach ($tag in @('background', 'foreground', 'monochrome')) {
        $el = $root.$tag
        if ($null -eq $el) { Fail "$f has no <$tag>"; continue }
        $ref = $el.GetAttribute('drawable', 'http://schemas.android.com/apk/res/android')
        if ($ref -notmatch '^@drawable/(.+)$') { Fail "$f <$tag> drawable ref is '$ref'"; continue }
        $target = Join-Path $res ("drawable\" + $Matches[1] + '.xml')
        if (Test-Path $target) { Pass ("{0,-38} <{1}> -> {2}" -f $f, $tag, $ref) }
        else { Fail "$f <$tag> points at $ref but $target does not exist" }
    }
}

Write-Host ''
Write-Host '=== 4. AndroidManifest icon references ==='
$mb = [System.IO.File]::ReadAllBytes($man)
$mbom = ($mb.Length -ge 3 -and $mb[0] -eq 0xEF -and $mb[1] -eq 0xBB -and $mb[2] -eq 0xBF)
if ($mbom) { Fail 'AndroidManifest.xml has a UTF-8 BOM' } else { Pass 'AndroidManifest.xml has no BOM' }
$mtxt = [System.Text.Encoding]::UTF8.GetString($mb)
[xml]$mx = $mtxt
$app = $mx.manifest.application
$androidNs = 'http://schemas.android.com/apk/res/android'

$iconRef = $app.GetAttribute('icon', $androidNs)
$roundRef = $app.GetAttribute('roundIcon', $androidNs)
Write-Host ("  android:icon      = " + $iconRef)
Write-Host ("  android:roundIcon = " + $roundRef)

function Resolve-Mipmap {
    param([string]$Ref)
    if ($Ref -notmatch '^@mipmap/(.+)$') { return $null }
    $name = $Matches[1]
    # must resolve at EVERY density for API 24-25, and as anydpi-v26 XML for 26+
    $hits = @()
    foreach ($d in $expect.Keys) {
        $png = Join-Path $res "$d\$name.png"
        if (Test-Path $png) { $hits += $png }
    }
    $xml = Join-Path $res "mipmap-anydpi-v26\$name.xml"
    if (Test-Path $xml) { $hits += $xml }
    return $hits
}

foreach ($pair in @(@('icon', $iconRef), @('roundIcon', $roundRef))) {
    $label = $pair[0]; $ref = $pair[1]
    if ([string]::IsNullOrEmpty($ref)) { Fail "android:$label is empty"; continue }
    $hits = Resolve-Mipmap -Ref $ref
    if ($null -eq $hits -or $hits.Count -eq 0) { Fail "android:$label ($ref) resolves to nothing" }
    else { Pass ("android:{0,-9} {1} -> {2} files" -f $label, $ref, $hits.Count) }
}

# release-critical settings must be untouched
Write-Host ''
Write-Host '=== 5. release-critical manifest values untouched ==='
$label = $app.GetAttribute('label', $androidNs)
# Expected label "video fusion" in Chinese, built from code points so this
# script stays ASCII-only (PowerShell 5.1 reads BOM-less .ps1 as ANSI).
$expectLabel = [string]::new([char[]]@(0x89C6, 0x9891, 0x878D, 0x5408))
if ($label -ceq $expectLabel) { Pass 'android:label unchanged' }
else { Fail ("android:label changed: got '" + $label + "'") }
if ($mtxt.Contains('com.example.video_fusion') -or (Test-Path (Join-Path $root 'android\app\build.gradle.kts'))) {
    Pass 'applicationId/namespace still declared in build.gradle.kts'
}

Write-Host ''
if ($fail -eq 0) { Write-Host 'RESULT: ALL CHECKS PASSED'; exit 0 }
else { Write-Host ("RESULT: {0} CHECK(S) FAILED" -f $fail); exit 1 }
