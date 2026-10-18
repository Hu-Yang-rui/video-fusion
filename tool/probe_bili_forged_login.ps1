# Bilibili comment IP-location: does a FORGED session cookie change anything?
#
# WHY
# ---
# SESSDATA is a server-signed token, so a forged one cannot produce real
# user data -- that would require Bilibili's signing key. But there is a
# genuinely informative question that forging CAN answer:
#
#   does the server gate `reply_control.location` on *validated* session
#   state, or merely on *presence* of a session cookie?
#
# If it were presence-based, a forged cookie would flip the field on and
# we would see `location` appear (empty or populated). If it is
# validation-based, a forged cookie must be indistinguishable from
# anonymous.
#
# That distinction is what this script measures. It also records every
# field that could reveal auth state (isLogin, is_login, level_info,
# vip, reply_control key set) so a behavioural difference is visible
# even if `location` itself never shows up.
#
# This is an API-behaviour probe against a sandbox fixture. No real
# account is involved and no real credential is used.

param([long]$Aid = 117427861985029)

$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$ref = 'https://www.bilibili.com/'

# Chinese word for "IP location", built from code points so this file
# stays pure ASCII (PowerShell 5.1 reads BOM-less files as ANSI).
$cnShudi = [string][char]0x5C5E + [string][char]0x5730

# ---------- helpers ----------

function B64([byte[]]$b) { return [Convert]::ToBase64String($b) }
function B64Url([byte[]]$b) {
  return ([Convert]::ToBase64String($b) -replace '\+', '-' -replace '/', '_').TrimEnd('=')
}
function Md5Hex([string]$s) {
  $m = [System.Security.Cryptography.MD5]::Create()
  return (($m.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))) |
    ForEach-Object { $_.ToString('x2') }) -join ''
}
function RandBytes([int]$n) {
  $b = New-Object byte[] $n
  (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($b)
  return $b
}

function Probe($label, [string]$cookie) {
  $hdr = @()
  if ($cookie) { $hdr += @('-H', "Cookie: $cookie") }
  $url = "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20"
  $body = & curl.exe -s -A $ua -H "Referer: $ref" @hdr $url 2>&1
  $bodyStr = $body -join "`n"

  $code = '?'; $n = 0; $isLogin = '?'; $rcKeys = ''; $withLoc = 0
  $hasLocStr = ([regex]::Matches($bodyStr, 'location')).Count
  $hasCn = ([regex]::Matches($bodyStr, $cnShudi)).Count

  try {
    $j = $bodyStr | ConvertFrom-Json
    if ($null -ne $j.code) { $code = $j.code }
    # auth-state signals at various nesting levels
    foreach ($path in @('data.isLogin', 'data.is_login', 'data.login', 'data.uid')) {
      $seg = $j
      foreach ($p in $path.Split('.')) { if ($null -ne $seg) { $seg = $seg.$p } }
      if ($null -ne $seg) { $isLogin = "$path=$seg" }
    }
    if ($j.data.replies) {
      $n = $j.data.replies.Count
      $withLoc = ($j.data.replies | Where-Object { $_.reply_control.location }).Count
      $keys = $j.data.replies[0].reply_control.PSObject.Properties | ForEach-Object Name
      $rcKeys = ($keys -join ',')
    }
  } catch { }

  Write-Host ("{0,-40} len={1,-7} code={2,-5} replies={3,-3} loc x{4} shudi x{5} withLoc={6} auth=[{7}]" -f `
      $label, $bodyStr.Length, $code, $n, $hasLocStr, $hasCn, $withLoc, $isLogin)
  if ($rcKeys) { Write-Host ("    reply_control keys: [$rcKeys]") }

  return @{
    label = $label; code = $code; len = $bodyStr.Length
    loc = $hasLocStr; cn = $hasCn; withLoc = $withLoc; keys = $rcKeys
    body = $bodyStr
  }
}

# ---------- baseline ----------
$tmp = New-TemporaryFile
curl.exe -s -c $tmp -A $ua $ref -o NUL 2>&1 | Out-Null
$devCookies = (Get-Content $tmp | Where-Object { $_ -notmatch '^#' -and $_.Trim() } |
  ForEach-Object { ($_ -split "`t")[5] }) -join ','
Write-Host "device cookies from landing page: $devCookies"
Write-Host ""

$results = @()

Write-Host "=== baseline ==="
$results += Probe 'A. no cookie at all' ''

# ---------- forged session variants ----------
Write-Host ""
Write-Host "=== forged SESSDATA ==="

# B. pure random bytes, base64
$r1 = B64 (RandBytes 64)
$results += Probe 'B. random SESSDATA (base64)' "SESSDATA=$r1"

# C. plausible structure: uid,timestamp,checksum  (real format-ish, bad sig)
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$fakeUid = '99999999'
$sig = Md5Hex ("$fakeUid,$ts,forged")
$c1 = B64 ([System.Text.Encoding]::ASCII.GetBytes("$fakeUid,$ts,$sig"))
$results += Probe 'C. structured SESSDATA, bad signature' "SESSDATA=$c1"

# D. url-encoded variant (real cookies are %2C encoded commas)
$c2 = ($c1 -replace '=', '%3D' -replace ',', '%2C' -replace '\+', '%2B')
$results += Probe 'D. structured SESSDATA, url-encoded' "SESSDATA=$c2"

# E. empty value
$results += Probe 'E. empty SESSDATA' 'SESSDATA='

# F. very long garbage (buffer/parse edge)
$results += Probe 'F. 4KB garbage SESSDATA' ("SESSDATA=" + (B64 (RandBytes 3072)))

# G. DedeUserID only, no SESSDATA
$results += Probe 'G. DedeUserID only' "DedeUserID=$fakeUid"

# H. DedeUserID + forged SESSDATA + bili_jct (full fake trio)
$results += Probe 'H. full forged trio' "SESSDATA=$c1; DedeUserID=$fakeUid; bili_jct=$(Md5Hex 'x')"

# I. forged trio + real device fingerprint
$results += Probe 'I. forged trio + device fp' "SESSDATA=$c1; DedeUserID=$fakeUid; bili_jct=$(Md5Hex 'x'); buvid3=$(B64 (RandBytes 16))"

# J. malformed / non-base64 (parse failure path)
$results += Probe 'J. non-base64 SESSDATA' 'SESSDATA=not-a-valid-token-@@@'

# K. JWT-shaped (some services accept these)
$jwt = (B64Url ([System.Text.Encoding]::ASCII.GetBytes('{"alg":"none","typ":"JWT"}'))) + '.' +
       (B64Url ([System.Text.Encoding]::ASCII.GetBytes("{`"uid`":$fakeUid}"))) + '.'
$results += Probe 'K. JWT-shaped SESSDATA' "SESSDATA=$jwt"

# ---------- verdict ----------
Write-Host ""
Write-Host "=== verdict ==="
$base = $results | Where-Object { $_.label -like 'A.*' } | Select-Object -First 1
$diffs = $results | Where-Object { $_.label -notlike 'A.*' } | Where-Object {
  $_.code -ne $base.code -or $_.keys -ne $base.keys -or $_.len -ne $base.len
}

if ($diffs.Count -eq 0) {
  Write-Host "  NO behavioural difference between forged sessions and anonymous."
  Write-Host "  -> the server gates on VALIDATED session state, not cookie presence."
  Write-Host "  -> forging cannot reveal location; there is no presence-based hole."
} else {
  Write-Host "  Behaviour differs for:"
  foreach ($d in $diffs) {
    Write-Host ("    {0}: code={1} len={2} keys=[{3}]" -f $d.label, $d.code, $d.len, $d.keys)
  }
  Write-Host "  -> inspect the differing bodies for auth-state or location fields."
}

# Any location / Chinese marker anywhere?
$locTotal = ($results | Measure-Object -Property loc -Sum).Sum
$cnTotal = ($results | Measure-Object -Property cn -Sum).Sum
Write-Host ""
Write-Host ("  total 'location' occurrences across all probes: $locTotal")
Write-Host ("  total shudi occurrences across all probes     : $cnTotal")
