# Bilibili comment IP-location: the dm_* anti-crawl fingerprint params.
#
# GENUINE GAP in rounds 1-5
# -------------------------
# Every earlier probe sent a plain query string. The real Bilibili web
# client also sends a set of anti-crawl fingerprint parameters:
#
#   dm_img_list       []
#   dm_img_str        base64(WebGL renderer string)
#   dm_cover_img_str  base64(unmasked GPU string)
#   dm_img_inter      {"ds":[],"wh":[0,0,0],"of":[0,0,0]}
#
# If the server gates the full comment payload (including
# reply_control.location) on these being present/plausible, then all
# earlier probes would have received a DEGRADED response -- which would
# look exactly like "the field does not exist".
#
# That is the one hypothesis that explains "the browser shows IP属地 but
# my API calls never do". This script tests it.
#
# Also tests:
#   - w_webid cookie (newer Bilibili cookie)
#   - proper bili_ticket via HMAC-SHA256 GenWebTicket
#   - seek_rpid param
#   - combination of all of the above
#
# Pure ASCII.

param([long]$Aid = 117427861985029, [string]$Bvid = 'BV1VVpo6gEYg')

$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$ref = 'https://www.bilibili.com/'
$cnShudi = [string][char]0x5C5E + [string][char]0x5730

function B64Str([string]$s) {
  return [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($s))
}
function Md5Hex([string]$s) {
  $m = [System.Security.Cryptography.MD5]::Create()
  return (($m.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))) |
    ForEach-Object { $_.ToString('x2') }) -join ''
}
function HmacSha256Hex([string]$key, [string]$msg) {
  $h = New-Object System.Security.Cryptography.HMACSHA256
  $h.Key = [System.Text.Encoding]::UTF8.GetBytes($key)
  return (($h.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($msg))) |
    ForEach-Object { $_.ToString('x2') }) -join ''
}

function Report($label, $body) {
  $len = if ($body) { $body.Length } else { 0 }
  $code = '?'; $n = 0; $withLoc = 0; $keys = ''
  $loc = ([regex]::Matches($body, 'location')).Count
  $cn = ([regex]::Matches($body, $cnShudi)).Count
  try {
    $j = $body | ConvertFrom-Json
    if ($null -ne $j.code) { $code = $j.code }
    if ($j.data.replies) {
      $n = $j.data.replies.Count
      $withLoc = ($j.data.replies | Where-Object { $_.reply_control.location }).Count
      $keys = (($j.data.replies[0].reply_control.PSObject.Properties | ForEach-Object Name) -join ',')
    }
  } catch { }
  Write-Host ("{0,-42} len={1,-7} code={2,-6} rep={3,-3} loc x{4} shudi x{5} withLoc={6}" -f `
      $label, $len, $code, $n, $loc, $cn, $withLoc)
  if ($keys) { Write-Host ("    keys: [$keys]") }
}

# ---------- baseline cookies ----------
$tmp = New-TemporaryFile
curl.exe -s -c $tmp -A $ua $ref -o NUL 2>&1 | Out-Null
$cookieNames = (Get-Content $tmp | Where-Object { $_ -notmatch '^#' -and $_.Trim() } |
  ForEach-Object { ($_ -split "`t")[5] }) -join ','
Write-Host "baseline cookies: $cookieNames"
Write-Host ""

# ---------- dm_* params (the missing piece) ----------
# Realistic values as sent by Chrome on Windows with an Intel GPU.
$webglRaw = 'WebGL 1.0 (OpenGL ES 2.0 Chromium)'
$gpuRaw = 'ANGLE (Intel, Intel(R) UHD Graphics 630 (0x00003E9B) Direct3D11 vs_5_0 ps_5_0), or similar'
$dmImgStr = B64Str $webglRaw
$dmCoverStr = B64Str $gpuRaw
$dmImgList = '[]'
$dmImgInter = '{"ds":[],"wh":[0,0,0],"of":[0,0,0]}'

$dmQuery = "&dm_img_list=$([uri]::EscapeDataString($dmImgList))" +
           "&dm_img_str=$([uri]::EscapeDataString($dmImgStr))" +
           "&dm_cover_img_str=$([uri]::EscapeDataString($dmCoverStr))" +
           "&dm_img_inter=$([uri]::EscapeDataString($dmImgInter))"

Write-Host "dm_img_str      = $dmImgStr"
Write-Host "dm_cover_img_str= $($dmCoverStr.Substring(0,40))..."
Write-Host ""

$base = "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20&plat=1&web_location=1315875"

# ---------- A. baseline (no dm) ----------
Write-Host "=== A. baseline, no dm params ==="
$bA = (& curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/video/$Bvid/" $base 2>&1) -join "`n"
Report 'no dm params' $bA

# ---------- B. with dm params ----------
Write-Host ""
Write-Host "=== B. WITH dm_* fingerprint params ==="
$bB = (& curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/video/$Bvid/" "$base$dmQuery" 2>&1) -join "`n"
Report 'dm_* params' $bB

# ---------- C. dm params + Origin/Sec-Fetch headers ----------
Write-Host ""
Write-Host "=== C. dm_* + browser fetch headers ==="
$bC = (& curl.exe -s -b $tmp -A $ua `
    -H "Referer: https://www.bilibili.com/video/$Bvid/" `
    -H "Origin: https://www.bilibili.com" `
    -H "Accept: application/json, text/plain, */*" `
    -H "Accept-Language: zh-CN,zh;q=0.9" `
    -H "Sec-Fetch-Dest: empty" `
    -H "Sec-Fetch-Mode: cors" `
    -H "Sec-Fetch-Site: same-site" `
    "$base$dmQuery" 2>&1) -join "`n"
Report 'dm_* + fetch headers' $bC

# ---------- D. proper bili_ticket ----------
Write-Host ""
Write-Host "=== D. bili_ticket (HMAC-SHA256 GenWebTicket) ==="
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
# key_id=ec02, key secret is a well-known public constant used by web
$hexsign = HmacSha256Hex 'XgwSnGZ1p' ("ts$ts")
$ticketUrl = "https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket" +
             "?key_id=ec02&hexsign=$hexsign&context[ts]=$ts&csrf="
$tRaw = (& curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/" $ticketUrl 2>&1) -join "`n"
$ticket = ''
try { $ticket = ($tRaw | ConvertFrom-Json).data.ticket } catch { }
Write-Host "  ticket len = $($ticket.Length)"
if ($ticket) {
  $bD = (& curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/video/$Bvid/" `
      -H "Cookie: bili_ticket=$ticket" "$base$dmQuery" 2>&1) -join "`n"
  Report 'dm_* + bili_ticket' $bD
} else {
  Write-Host "  no ticket obtained; raw: $($tRaw.Substring(0,[Math]::Min(200,$tRaw.Length)))"
}

# ---------- E. w_webid ----------
Write-Host ""
Write-Host "=== E. w_webid cookie ==="
$wRaw = (& curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/" `
    "https://api.bilibili.com/x/web-interface/wbi/view/webid" 2>&1) -join "`n"
$webid = ''
try { $webid = ($wRaw | ConvertFrom-Json).data.w_webid } catch { }
Write-Host "  w_webid = $(if ($webid) { $webid } else { '(none)' })"
if ($webid) {
  $bE = (& curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/video/$Bvid/" `
      -H "Cookie: w_webid=$webid" "$base$dmQuery" 2>&1) -join "`n"
  Report 'dm_* + w_webid' $bE
}

# ---------- F. seek_rpid ----------
Write-Host ""
Write-Host "=== F. seek_rpid (anchor a specific comment) ==="
$rpid = ''
try { $rpid = (($bB | ConvertFrom-Json).data.replies[0].rpid) } catch { }
if ($rpid) {
  $bF = (& curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/video/$Bvid/" `
      "$base$dmQuery&seek_rpid=$rpid" 2>&1) -join "`n"
  Report "seek_rpid=$rpid" $bF
}

# ---------- G. mode=3 with dm ----------
Write-Host ""
Write-Host "=== G. mode=3 + dm_* ==="
$bG = (& curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/video/$Bvid/" `
    "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=3&next=0&ps=20&plat=1&web_location=1315875$dmQuery" 2>&1) -join "`n"
Report 'mode=3 + dm_*' $bG

# ---------- verdict ----------
Write-Host ""
Write-Host "=== verdict ==="
$locA = ([regex]::Matches($bA, 'location')).Count
$locB = ([regex]::Matches($bB, 'location')).Count
if ($locB -gt $locA) {
  Write-Host "  dm_* params CHANGED the response -- location now present!"
} elseif ($locA -eq 0 -and $locB -eq 0) {
  Write-Host "  dm_* params made no difference: location still absent."
  Write-Host "  -> anti-crawl fingerprinting is NOT what gates the field."
}
