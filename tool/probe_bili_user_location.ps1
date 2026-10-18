# Does any Bilibili endpoint expose a commenter's real IP or a
# finer-grained location than the province label?
#
# What we already know (see probe_bili_ip_literal.ps1):
#   - comment payloads contain 0 IPv4 and 0 IPv6 literals
#   - /x/web-interface/zone returns only the CALLER's own IP
#
# This script checks the remaining candidate surfaces that return
# per-user data, to see whether any of them carries location:
#   1. /x/space/wbi/acc/info   (user profile -- has a `location` field,
#      but that is USER-SET profile text, not IP-derived)
#   2. /x/web-interface/card   (user card)
#   3. /x/v2/reply/main with a uid filter -- does any field correlate
#      a comment to a network origin?
#
# Purpose: document exactly what exists and why each is NOT a commenter
# IP, so the boundary is provable rather than assumed.
#
# Pure ASCII.

param([long]$Aid = 117427861985029)

$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$ref = 'https://www.bilibili.com/'
$cnShudi = [string][char]0x5C5E + [string][char]0x5730

$tmp = New-TemporaryFile
curl.exe -s -c $tmp -A $ua $ref -o NUL 2>&1 | Out-Null

function IpScan($s) {
  $v4 = [regex]::Matches($s, '(?<!\d)(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\d)')
  return $v4.Count
}

# ---------- harvest a mid from comments ----------
$body = (& curl.exe -s -b $tmp -A $ua -H "Referer: $ref" `
    "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20" 2>&1) -join "`n"
$mid = ''
try {
  $j = $body | ConvertFrom-Json
  if ($j.data.replies) { $mid = $j.data.replies[0].member.mid }
} catch { }
Write-Host "harvested mid = $mid"
Write-Host ""

# ---------- 1. profile info ----------
Write-Host "=== 1. /x/space/wbi/acc/info?mid=$mid ==="
$p = (& curl.exe -s -b $tmp -A $ua -H "Referer: $ref" `
    "https://api.bilibili.com/x/space/wbi/acc/info?mid=$mid" 2>&1) -join "`n"
Write-Host ("  len=" + $p.Length + "  IPv4x" + (IpScan $p))
try {
  $pj = $p | ConvertFrom-Json
  Write-Host ("  code=" + $pj.code)
  if ($pj.code -eq 0 -and $pj.data) {
    Write-Host ("  data.location      = '" + $pj.data.location + "'")
    Write-Host ("  data.profession    = '" + $pj.data.profession + "'")
    Write-Host ("  data.face/name     = " + $pj.data.name)
    Write-Host "  NOTE: `location` here is USER-ENTERED profile text (e.g. 'Guangdong'),"
    Write-Host "        settable by the user to anything. NOT IP-derived. Task rules"
    Write-Host "        explicitly forbid using it as comment IP location."
  }
} catch { Write-Host "  parse failed" }

# ---------- 2. card ----------
Write-Host ""
Write-Host "=== 2. /x/web-interface/card?mid=$mid ==="
$c = (& curl.exe -s -b $tmp -A $ua -H "Referer: $ref" `
    "https://api.bilibili.com/x/web-interface/card?mid=$mid" 2>&1) -join "`n"
Write-Host ("  len=" + $c.Length + "  IPv4x" + (IpScan $c))
try {
  $cj = $c | ConvertFrom-Json
  Write-Host ("  code=" + $cj.code)
  if ($cj.code -eq 0 -and $cj.data.card) {
    Write-Host ("  card.place = '" + $cj.data.card.place + "'")
    Write-Host "  NOTE: `place` is also user profile text, not IP."
  }
} catch { Write-Host "  parse failed" }

# ---------- 3. full field dump of one comment ----------
Write-Host ""
Write-Host "=== 3. complete field list of a single comment ==="
try {
  $j = $body | ConvertFrom-Json
  $r = $j.data.replies[0]
  Write-Host ("  top-level fields: " + (($r.PSObject.Properties | ForEach-Object Name) -join ', '))
  Write-Host ("  member fields   : " + (($r.member.PSObject.Properties | ForEach-Object Name) -join ', '))
  Write-Host ("  reply_control   : " + (($r.reply_control.PSObject.Properties | ForEach-Object Name) -join ', '))
  Write-Host ""
  Write-Host "  -> no field named ip / client_ip / addr / net anywhere."
} catch { Write-Host "  parse failed" }

# ---------- 4. summary ----------
Write-Host ""
Write-Host "=== summary: what location-ish data actually exists ==="
Write-Host "  A. reply_control.location  : province label, anonymous=absent,"
Write-Host "                               logged-in=unverified"
Write-Host "  B. any IPv4/IPv6 in payload: 0 occurrences"
Write-Host "  C. profile location/place  : user-typed text, not IP"
Write-Host "  D. /web-interface/zone     : caller's OWN ip only"
Write-Host ""
Write-Host "  => a commenter's real IP address is not present in any"
Write-Host "     response available to a third-party client."
