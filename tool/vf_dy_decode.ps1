# vf_dy_decode.ps1
#
# Purpose: prove whether Douyin live HLS segments are DECODABLE, not just downloadable.
#
# Why this matters: Q2 proved segments download (first byte 0x47 = MPEG-TS).
# But feed declares v_codec = "bytevc1" (ByteDance HEVC variant) and the PMT reports
# stream_type 0x24 (HEVC). media_kit == libmpv == FFmpeg decoders, so "downloadable"
# is not the same as "shows picture". This script decodes a real segment with the
# local ffmpeg/ffprobe (same decoder family as media_kit) and also queries the
# Android emulator for HEVC hardware decoder availability.
#
# ASCII-only on purpose: Windows PowerShell 5.1 mis-parses BOM-less UTF-8 scripts.
# NOTE: PowerShell variable names are case-INsensitive, so parameter names must not
# collide with local variables (e.g. -RoomCount vs $feedRooms).
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/vf_dy_decode.ps1
#   powershell -NoProfile -ExecutionPolicy Bypass -File tool/vf_dy_decode.ps1 -RoomCount 3 -TiersCsv HD1,FULL_HD1
param(
    [int]$RoomCount = 2,
    [string]$TiersCsv = 'HD1,FULL_HD1',
    [string]$WorkDir = "$env:TEMP\vf_dy_decode"
)
$ErrorActionPreference = 'Continue'

# make adb reachable even when the caller did not extend PATH
$adbDir = 'D:\android-sdk\platform-tools'
if ((Test-Path $adbDir) -and ($env:Path -notlike "*$adbDir*")) { $env:Path = "$adbDir;" + $env:Path }

$UaApp = 'com.ss.android.ugc.aweme/400701 (Linux; U; Android 13; zh_CN; Pixel 7; Build/TQ3A.230805.001; Cronet/TTNetVersion:5f296c8c 2023-06-01)'
$Common = 'aid=1128&app_name=douyin_lite&device_platform=android&version_code=400701&device_type=Pixel7&os_version=13&channel=googleplay&language=zh'
$Tiers = $TiersCsv -split ','

Write-Host "=== vf_dy_decode: decode a real Douyin live HLS segment ==="
$ffprobeCmd = Get-Command ffprobe -ErrorAction SilentlyContinue
$ffmpegCmd = Get-Command ffmpeg -ErrorAction SilentlyContinue
if (-not $ffmpegCmd -or -not $ffprobeCmd) {
    Write-Host "!! ffmpeg/ffprobe not found - decode check skipped (download evidence is unaffected)"
    exit 2
}
Write-Host "ffmpeg : $($ffmpegCmd.Source)"
& $ffmpegCmd.Source -hide_banner -version 2>$null | Select-Object -First 1 | ForEach-Object { Write-Host "  $_" }
if (-not (Test-Path $WorkDir)) { New-Item -ItemType Directory -Path $WorkDir | Out-Null }

# ---------------------------------------------------------------------------
# 1) fetch feed anonymously. webcast/feed intermittently returns HTTP 200 with
#    an EMPTY body (measured 5/7 = 71% in this session), so retry is mandatory.
# ---------------------------------------------------------------------------
$feedRooms = New-Object System.Collections.ArrayList
Write-Host ""
Write-Host "-- fetch feed rooms (anonymous: no cookie, no signature) --"
for ($i = 1; $i -le 12; $i++) {
    try {
        $resp = Invoke-WebRequest -Uri "https://webcast.amemv.com/webcast/feed/?$Common&count=12&offset=0&type=0" `
            -Headers @{ 'user-agent' = $UaApp; 'referer' = 'https://live.douyin.com/' } -TimeoutSec 25 -UseBasicParsing
        $c = $resp.Content
        if ($c -is [byte[]]) { $c = [System.Text.Encoding]::UTF8.GetString($c) }
        if ($c -and $c.Trim().Length -gt 100) {
            $j = $c | ConvertFrom-Json
            foreach ($e in @($j.data)) {
                if ($null -ne $e -and $null -ne $e.data) { [void]$feedRooms.Add($e.data) }
            }
            Write-Host "  feed try#$i : OK, $($feedRooms.Count) rooms"
            break
        }
        Write-Host "  feed try#$i : empty body (HTTP $($resp.StatusCode))"
    } catch { Write-Host "  feed try#$i : $($_.Exception.Message)" }
    Start-Sleep -Milliseconds (300 * $i)
}
Write-Host "  total rooms: $($feedRooms.Count)"
if ($feedRooms.Count -eq 0) { Write-Host "!! no data, abort"; exit 1 }

function Get-Binary($Url, $Out) {
    try {
        Invoke-WebRequest -Uri $Url -Headers @{ 'user-agent' = $UaApp; 'referer' = 'https://live.douyin.com/' } -OutFile $Out -TimeoutSec 90 -UseBasicParsing
        return $true
    } catch { Write-Host "    download failed: $($_.Exception.Message)"; return $false }
}
function Resolve-Abs($Base, $Rel) {
    if ($Rel -match '^https?:') { return $Rel }
    return (New-Object System.Uri((New-Object System.Uri($Base)), $Rel)).AbsoluteUri
}
function Get-HexHead($Path, $N) {
    $bytes = $null
    try { $bytes = @(Get-Content $Path -AsByteStream -TotalCount $N) }
    catch { try { $bytes = @(Get-Content $Path -Encoding Byte -TotalCount $N) } catch { $bytes = @() } }
    ($bytes | ForEach-Object { ([byte]$_).ToString('x2') }) -join ' '
}

$max = [Math]::Min($RoomCount, $feedRooms.Count)
for ($ri = 0; $ri -lt $max; $ri++) {
    $room = $feedRooms[$ri]
    Write-Host ""
    Write-Host "===== room $($room.id_str) status=$($room.status) default=$($room.stream_url.default_resolution) ====="
    $map = $room.stream_url.hls_pull_url_map
    if (-not $map) { Write-Host "  (no hls_pull_url_map)"; continue }
    foreach ($tier in $Tiers) {
        $url = $map."$tier"
        if (-not $url) { Write-Host "  $tier : tier absent for this room"; continue }
        $pl = Join-Path $WorkDir "pl_$($room.id_str)_$tier.m3u8"
        if (-not (Get-Binary $url $pl)) { continue }
        $txt = [System.IO.File]::ReadAllText($pl)
        $baseUrl = $url
        if ($txt -match '(?m)#EXT-X-STREAM-INF:[^\r\n]*\r?\n([^\r\n]+)') {
            Write-Host "  $tier : master playlist -> following first variant"
            $baseUrl = Resolve-Abs $url $Matches[1].Trim()
            $vpl = Join-Path $WorkDir "var_$($room.id_str)_$tier.m3u8"
            if (-not (Get-Binary $baseUrl $vpl)) { continue }
            $txt = [System.IO.File]::ReadAllText($vpl)
        }
        $segs = @($txt -split "\r?\n" | Where-Object { $_ -and -not $_.StartsWith('#') })
        if ($segs.Count -eq 0) { Write-Host "  $tier : media playlist has no segment lines"; continue }
        $segUrl = Resolve-Abs $baseUrl $segs[0]
        $tsFile = Join-Path $WorkDir "seg_$($room.id_str)_$tier.ts"
        if (-not (Get-Binary $segUrl $tsFile)) { continue }
        $size = (Get-Item $tsFile).Length
        Write-Host "  $tier : segment $size bytes, first 8 bytes = [$(Get-HexHead $tsFile 8)]"

        Write-Host "  --- ffprobe streams (container + codec as seen by FFmpeg) ---"
        & $ffprobeCmd.Source -hide_banner -loglevel error -show_entries 'stream=index,codec_type,codec_name,profile,width,height,pix_fmt,r_frame_rate' -of default=noprint_wrappers=0 $tsFile 2>&1 |
            ForEach-Object { Write-Host "    $_" }

        Write-Host "  --- ffmpeg decode of 1s to -f null (software decode) ---"
        $dec = & $ffmpegCmd.Source -hide_banner -nostats -loglevel warning -i $tsFile -t 1 -f null - 2>&1
        $decExit = $LASTEXITCODE
        foreach ($l in $dec) { Write-Host "    $l" }
        $codecs = @($dec | Select-String -Pattern 'Video:\s*([A-Za-z0-9_]+)' | ForEach-Object { $_.Matches.Groups[0].Groups[1].Value })
        Write-Host "    -> decode exit=$decExit  ffmpeg video codec(s)=$($codecs -join ',')"
        if ($decExit -eq 0) {
            Write-Host "    PASS: FFmpeg decodes this segment -> media_kit (libmpv) decode path viable"
        } else {
            Write-Host "    FAIL: decode failed -> media_kit would stay black despite downloadable bytes"
        }

        Write-Host "  --- extract one PNG frame (proof of real picture, not black) ---"
        $png = Join-Path $WorkDir "frame_$($room.id_str)_$tier.png"
        & $ffmpegCmd.Source -hide_banner -loglevel error -y -i $tsFile -frames:v 1 $png 2>&1 | ForEach-Object { Write-Host "    $_" }
        if (Test-Path $png) {
            $pi = Get-Item $png
            Write-Host "    frame saved: $($pi.FullName) ($($pi.Length) bytes)"
            # mean luma via signalstats: 0 => pure black frame, ~90-120 => real picture
            $lum = & $ffmpegCmd.Source -hide_banner -loglevel info -i $pi.FullName -vf "signalstats,metadata=print:key=lavfi.signalstats.YAVG" -f null - 2>&1 |
                Select-String -Pattern 'YAVG=' | ForEach-Object { $_.Line }
            $black = & $ffmpegCmd.Source -hide_banner -loglevel info -i $pi.FullName -vf "blackdetect=d=0.1:pix_th=0.10" -an -f null - 2>&1 |
                Select-String -Pattern 'black_start' | ForEach-Object { $_.Line }
            Write-Host "    YAVG: $lum"
            Write-Host "    blackdetect: $(if ($black) { $black } else { '(no black interval => 画面有真实内容)' })"
        } else {
            Write-Host "    no frame produced"
        }
    }
}

Write-Host ""
Write-Host "=== Android emulator HEVC hardware decoder availability ==="
$adbCmd = Get-Command adb -ErrorAction SilentlyContinue
if ($adbCmd) {
    & $adbCmd.Source devices 2>&1 | ForEach-Object { Write-Host "  $_" }
    Write-Host "  video/hevc entries in vendor media_codecs:"
    & $adbCmd.Source -s emulator-5554 shell "grep -i -B1 -A2 'video/hevc' /vendor/etc/media_codecs.xml /vendor/etc/media_codecs_google_video.xml 2>/dev/null" 2>&1 |
        ForEach-Object { Write-Host "    $_" }
    Write-Host "  device props:"
    & $adbCmd.Source -s emulator-5554 shell "getprop ro.product.model; getprop ro.board.platform; getprop ro.build.version.sdk" 2>&1 |
        ForEach-Object { Write-Host "    $_" }
    Write-Host "  GPU / forced-sw-rendering traces:"
    & $adbCmd.Source -s emulator-5554 shell "getprop | grep -i -E 'angle|gltransport|force.*gpu|gpu.*force'" 2>&1 |
        Select-Object -First 8 | ForEach-Object { Write-Host "    $_" }
} else {
    Write-Host "  (adb not found, skipped)"
}
Write-Host ""
Write-Host "samples kept in: $WorkDir"
