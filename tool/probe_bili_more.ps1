# Bilibili comment IP-location: the remaining untested request surfaces.
#
# Already ruled out (see probe_bili_location.ps1 / probe_bili_wbi.ps1 /
# probe_bili_grpc.mjs):
#   web reply/main, wbi/main, legacy reply, sub-reply,
#   full device fingerprint, bili_ticket, app appkey signing,
#   gRPC protobuf MainList + View/View
#
# New here:
#   1. reply/main with pagination_str (cursor form) instead of numeric next
#   2. reply/main with different `plat` values (1/2/3/4/5/7/8)
#   3. TV endpoint (api.snm0516.aisee.tv) with TV appkey
#   4. International endpoint (api.biliintl.com)
#   5. Video page HTML (SSR payload) -- does the page itself embed location?
#
# Pure ASCII (PowerShell 5.1 reads BOM-less files as ANSI).

param([long]$Aid = 117427861985029, [string]$Bvid = 'BV1VVpo6gEYg')

$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

$cnShudi = [string][char]0x5C5E + [string][char]0x5730   # "shudi"

function Report($label, $body, [string]$extra = '') {
  $len = if ($body) { $body.Length } else { 0 }
  $code = '?'
  $n = 0
  $withLoc = 0
  try {
    $j = $body | ConvertFrom-Json
    if ($null -ne $j.code) { $code = $j.code }
    if ($j.data.replies) {
      $n = $j.data.replies.Count
      $withLoc = ($j.data.replies | Where-Object { $_.reply_control.location }).Count
    }
  } catch { }
  $hasLoc = ([regex]::Matches($body, 'location')).Count
  $hasCn = ([regex]::Matches($body, $cnShudi)).Count
  Write-Host ("{0,-44} len={1,-8} code={2,-6} replies={3,-4} 'location'x{4,-3} shudi x{5,-3} withLoc={6} {7}" -f `
      $label, $len, $code, $n, $hasLoc, $hasCn, $withLoc, $extra)
}

$tmp = New-TemporaryFile
curl.exe -s -c $tmp -A $ua "https://www.bilibili.com/" -o NUL 2>&1 | Out-Null

# ---------- 1. pagination_str ----------
Write-Host "=== 1. reply/main with pagination_str (cursor) ==="
$pag = '{"offset":""}'
$pagEnc = [uri]::EscapeDataString($pag)
$b1 = curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/" `
  "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&pagination_str=$pagEnc&plat=1&web_location=1315875" 2>&1
Report 'reply/main + pagination_str' $b1

# ---------- 2. plat sweep ----------
Write-Host "=== 2. plat sweep ==="
foreach ($plat in 1, 2, 3, 4, 5, 7, 8) {
  $b = curl.exe -s -b $tmp -A $ua -H "Referer: https://www.bilibili.com/" `
    "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20&plat=$plat" 2>&1
  Report "reply/main plat=$plat" $b
}

# ---------- 3. TV endpoint ----------
Write-Host "=== 3. TV endpoint (api.snm0516.aisee.tv) ==="
function Get-Md5Hex([string]$text) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $hash = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($text))
  return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
}
# TV appkey/appsec pairs that circulate publicly
$tvPairs = @(
  @{ k = '4409e2ce8ffd12b8'; s = '59b43e04ad6965f34319062b478f83dd' },
  @{ k = '7d089525d3611b1c'; s = 'acd495b248ec528c2eed1e862d393126' },
  @{ k = 'iVGUTjsxvpLeuDCf'; s = 'aHRmhWMLkdeMuILqORnYZocWFcdGUHMo' }
)
foreach ($pair in $tvPairs) {
  $p = @{
    appkey = $pair.k; build = '107000'; channel = 'master'; mobi_app = 'android_tv_yst'
    oid = $Aid; platform = 'android'; pn = 1; ps = 20; sort = 2; type = 1
  }
  $keys = $p.Keys | Sort-Object
  $q = ($keys | ForEach-Object { "$_=$([uri]::EscapeDataString([string]$p[$_]))" }) -join '&'
  $sign = Get-Md5Hex ($q + $pair.s)
  $url = "https://api.snm0516.aisee.tv/x/v2/reply?$q&sign=$sign"
  $b = curl.exe -s -A "Mozilla/5.0 BiliTV/1.6.6 (bbcallen@gmail.com)" -H "Referer: https://www.bilibili.com/" $url 2>&1
  Report "TV appkey=$($pair.k.Substring(0,6)).." $b
}

# ---------- 4. International ----------
Write-Host "=== 4. International (api.biliintl.com) ==="
$b4 = curl.exe -s -A $ua -H "Referer: https://www.bilibili.tv/" `
  "https://api.biliintl.com/intl/gateway/v2/ogv/view/app/season?season_id=1" 2>&1
Report 'biliintl season probe' $b4
$b4b = curl.exe -s -A $ua -H "Referer: https://www.bilibili.tv/" `
  "https://api.biliintl.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20" 2>&1
Report 'biliintl reply/main' $b4b

# ---------- 5. video page HTML ----------
Write-Host "=== 5. video page HTML (SSR) ==="
$html = curl.exe -s -A $ua -H "Referer: https://www.bilibili.com/" "https://www.bilibili.com/video/$Bvid/" 2>&1
$htmlStr = $html -join "`n"
Write-Host ("  html length: " + $htmlStr.Length)
foreach ($kw in @('location', 'reply_control', 'ip_label', 'ipLocation')) {
  Write-Host ("  '$kw' x" + ([regex]::Matches($htmlStr, $kw)).Count)
}
Write-Host ("  shudi x" + ([regex]::Matches($htmlStr, $cnShudi)).Count)
Write-Host ("  __INITIAL_STATE__ present: " + $htmlStr.Contains('__INITIAL_STATE__'))
Write-Host ("  replyList present: " + $htmlStr.Contains('replyList'))

# save for manual inspection
$htmlStr | Out-File -Encoding utf8 "build\video-page.html"

Write-Host ""
Write-Host "=== done ==="
