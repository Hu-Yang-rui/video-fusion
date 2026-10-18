# Bilibili comment IP-location probe: try every distinct request surface.
#
# Pure ASCII on purpose (PowerShell 5.1 reads BOM-less files as ANSI).
#
# Variants tested:
#   A. web API + full device fingerprint (buvid3 + buvid4 + b_nut + _uuid)
#   B. web API + bili_ticket (GenWebTicket anti-bot token)
#   C. app API (api.bilibili.com, mobi_app=android) with appkey signing
#   D. app API (app.bilibili.com) with appkey signing
#   E. sub-reply endpoint /x/v2/reply/reply
#   F. legacy /x/v2/reply with sort
#
# For each: print HTTP status, api code, reply count, and whether the raw
# body contains the string "location" / the Chinese word for IP location.

param([long]$Aid = 117427861985029)

$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$appUa = 'Mozilla/5.0 BiliDroid/7.38.0 (bbcallen@gmail.com) os/android mobi_android'

function Get-Md5Hex([string]$text) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
  return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
}

# Chinese keyword for "IP location" built from code points, so this file
# stays pure ASCII.
$cnDi = [char]0x5C5E   # shu
$cnDi2 = [char]0x5730  # di
$cnKw = "$cnDi$cnDi2"  # "shudi" = IP location

function Report($label, $body) {
  $len = if ($body) { $body.Length } else { 0 }
  $code = '?'
  $n = 0
  try {
    $j = $body | ConvertFrom-Json
    $code = $j.code
    if ($j.data.replies) { $n = $j.data.replies.Count }
  } catch { }
  $hasLoc = ([regex]::Matches($body, 'location')).Count
  $hasCn = ([regex]::Matches($body, $cnKw)).Count
  $withLoc = 0
  try {
    $j2 = $body | ConvertFrom-Json
    if ($j2.data.replies) {
      $withLoc = ($j2.data.replies | Where-Object { $_.reply_control.location }).Count
    }
  } catch { }
  Write-Host ("{0,-46} len={1,-7} code={2,-6} replies={3,-3} 'location'x{4} cnKw x{5} withLoc={6}" -f $label, $len, $code, $n, $hasLoc, $hasCn, $withLoc)
}

# ---------- fingerprint cookies ----------
$jar = New-TemporaryFile
curl.exe -s -c $jar -A $ua "https://www.bilibili.com/" -o NUL 2>&1 | Out-Null
$fingerprint = (Get-Content $jar | Where-Object { $_ -notmatch '^#' -and $_.Trim() } | ForEach-Object { ($_ -split "`t")[5] }) -join ','
Write-Host "base cookies: $fingerprint"
Write-Host ""

# ---------- A. full fingerprint ----------
Write-Host "=== A. web + full fingerprint ==="
$buvid4 = curl.exe -s -A $ua "https://api.bilibili.com/x/frontend/finger/spi" 2>&1 | ConvertFrom-Json
$b3 = $buvid4.data.b_3
$b4 = $buvid4.data.b_4
$uuid = [guid]::NewGuid().ToString().ToUpper() + [string]([DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() % 100000) + 'infoc'
$ckA = "buvid3=$b3; buvid4=$b4; b_nut=$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()); _uuid=$uuid; CURRENT_FNVAL=4048; buvid_fp=$(Get-Md5Hex $uuid)"
$bodyA = curl.exe -s -A $ua -H "Referer: https://www.bilibili.com/" -H "Cookie: $ckA" "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20&plat=1&web_location=1315875" 2>&1
Report 'reply/main + full fingerprint' $bodyA

# ---------- B. bili_ticket ----------
Write-Host "=== B. web + bili_ticket ==="
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$ticketRaw = curl.exe -s -A $ua -H "Referer: https://www.bilibili.com/" -H "Cookie: $ckA" -X POST "https://api.bilibili.com/bapis/bilibili.api.ticket.v1.Ticket/GenWebTicket?key_id=ec02&hexsign=6f7b1d1b1f2c2b7f4c8a&context%5Bts%5D=$ts&csrf=" 2>&1
$ticket = ''
try { $ticket = ($ticketRaw | ConvertFrom-Json).data.ticket } catch { }
Write-Host "bili_ticket len=$($ticket.Length)"
$ckB = "$ckA; bili_ticket=$ticket"
$bodyB = curl.exe -s -A $ua -H "Referer: https://www.bilibili.com/" -H "Cookie: $ckB" "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20&plat=1&web_location=1315875" 2>&1
Report 'reply/main + bili_ticket' $bodyB

# ---------- C. app API with appkey signing ----------
Write-Host "=== C. app API (api.bilibili.com, mobi_app=android) ==="
$appkey = '1d8b6e7d45233436'
$appsec = '560c52ccd288fed045859ed18bffd973'
$p = @{
  appkey = $appkey; build = '7380200'; c_locale = 'zh_CN'; channel = 'bili'
  mobi_app = 'android'; oid = $Aid; platform = 'android'; pn = 1; ps = 20
  s_locale = 'zh_CN'; sort = 2; statistics = '{"appId":1,"platform":3,"version":"7.38.0","abtest":""}'
  type = 1
}
$keys = $p.Keys | Sort-Object
$q = ($keys | ForEach-Object { "$_=$([uri]::EscapeDataString([string]$p[$_]))" }) -join '&'
$sign = Get-Md5Hex ($q + $appsec)
$urlC = "https://api.bilibili.com/x/v2/reply?$q&sign=$sign"
$bodyC = curl.exe -s -A $appUa -H "Referer: https://www.bilibili.com/" $urlC 2>&1
Report 'app API api.bilibili.com' $bodyC

# ---------- D. app.bilibili.com ----------
Write-Host "=== D. app API (app.bilibili.com) ==="
$urlD = "https://app.bilibili.com/x/v2/reply?$q&sign=$sign"
$bodyD = curl.exe -s -A $appUa -H "Referer: https://www.bilibili.com/" $urlD 2>&1
Report 'app API app.bilibili.com' $bodyD

# ---------- E. sub-reply ----------
Write-Host "=== E. sub-reply /x/v2/reply/reply ==="
$root = ''
try { $root = (($bodyA | ConvertFrom-Json).data.replies | Where-Object { $_.rcount -gt 0 } | Select-Object -First 1).rpid } catch { }
if ($root) {
  $bodyE = curl.exe -s -A $ua -H "Referer: https://www.bilibili.com/" -H "Cookie: $ckA" "https://api.bilibili.com/x/v2/reply/reply?type=1&oid=$Aid&root=$root&ps=20&pn=1" 2>&1
  Report "reply/reply root=$root" $bodyE
} else {
  Write-Host "no reply with sub-replies, skipped"
}

# ---------- F. legacy ----------
Write-Host "=== F. legacy /x/v2/reply ==="
$bodyF = curl.exe -s -A $ua -H "Referer: https://www.bilibili.com/" -H "Cookie: $ckA" "https://api.bilibili.com/x/v2/reply?type=1&oid=$Aid&pn=1&ps=20&sort=2" 2>&1
Report 'legacy reply + fingerprint' $bodyF

Write-Host ""
Write-Host "=== done ==="
