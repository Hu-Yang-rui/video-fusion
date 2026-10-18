# Controlled follow-up to probe_bili_forged_login.ps1.
#
# The previous run showed identical reply_control key sets for every
# forged variant, but response LENGTH varied (73607 / 82080 / 10220).
# That must not be hand-waved as "noise" -- it could be an auth signal.
#
# Two decisive experiments:
#
#   1. Repeat the SAME request (no cookie) 6 times. If length varies,
#      the variation is comment-set rotation / cache, not auth.
#
#   2. Hit /x/web-interface/nav, which DOES report isLogin explicitly.
#      Compare: no cookie / forged SESSDATA / structurally valid forged
#      SESSDATA. This proves whether a forged token is accepted at all.
#
# Pure ASCII.

param([long]$Aid = 117427861985029)

$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$ref = 'https://www.bilibili.com/'

function Md5Hex([string]$s) {
  $m = [System.Security.Cryptography.MD5]::Create()
  return (($m.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))) |
    ForEach-Object { $_.ToString('x2') }) -join ''
}
function B64([byte[]]$b) { return [Convert]::ToBase64String($b) }
function RandBytes([int]$n) {
  $b = New-Object byte[] $n
  (New-Object System.Security.Cryptography.RNGCryptoServiceProvider).GetBytes($b)
  return $b
}

# ---------- experiment 1: is length noise? ----------
Write-Host "=== 1. same request (no cookie) x6 -- is length stable? ==="
$lens = @()
$keySets = @{}
for ($i = 1; $i -le 6; $i++) {
  $url = "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20"
  $b = (& curl.exe -s -A $ua -H "Referer: $ref" $url 2>&1) -join "`n"
  $n = 0; $k = ''
  try {
    $j = $b | ConvertFrom-Json
    if ($j.data.replies) {
      $n = $j.data.replies.Count
      $k = (($j.data.replies[0].reply_control.PSObject.Properties | ForEach-Object Name) -join ',')
    }
  } catch { }
  $lens += $b.Length
  if ($k) { $keySets[$k] = $true }
  Write-Host ("  run $i : len=$($b.Length) replies=$n")
  Start-Sleep -Milliseconds 400
}
$uniqLens = ($lens | Sort-Object -Unique)
Write-Host ("  distinct lengths: " + ($uniqLens -join ', '))
Write-Host ("  distinct reply_control key sets: " + $keySets.Count)
Write-Host ""
if ($uniqLens.Count -gt 1) {
  Write-Host "  -> length VARIES on identical requests: it is comment-set"
  Write-Host "     rotation, NOT an auth signal. Length differences in the"
  Write-Host "     forged-cookie run can be discarded."
} else {
  Write-Host "  -> length is stable; length differences were meaningful."
}

# ---------- experiment 2: is a forged token accepted? ----------
Write-Host ""
Write-Host "=== 2. /x/web-interface/nav reports isLogin explicitly ==="

$fakeUid = '99999999'
$ts = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()

$variants = @(
  @{ n = 'no cookie';                     c = '' },
  @{ n = 'random SESSDATA';               c = ("SESSDATA=" + (B64 (RandBytes 64))) },
  @{ n = 'structured SESSDATA, bad sig';  c = ("SESSDATA=" + (B64 ([System.Text.Encoding]::ASCII.GetBytes("$fakeUid,$ts,$(Md5Hex "$fakeUid,$ts,x")")))) },
  @{ n = 'empty SESSDATA';                c = 'SESSDATA=' },
  @{ n = 'DedeUserID only';               c = "DedeUserID=$fakeUid" }
)

foreach ($v in $variants) {
  $hdr = @()
  if ($v.c) { $hdr += @('-H', "Cookie: $($v.c)") }
  $body = (& curl.exe -s -A $ua -H "Referer: $ref" @hdr "https://api.bilibili.com/x/web-interface/nav" 2>&1) -join "`n"
  $isLogin = '?'; $code = '?'; $mid = ''
  try {
    $j = $body | ConvertFrom-Json
    $code = $j.code
    if ($null -ne $j.data.isLogin) { $isLogin = $j.data.isLogin }
    if ($j.data.mid) { $mid = $j.data.mid }
  } catch { }
  Write-Host ("  {0,-32} code={1,-6} isLogin={2,-6} mid='{3}'" -f $v.n, $code, $isLogin, $mid)
}

Write-Host ""
Write-Host "  Interpretation:"
Write-Host "  - if every forged variant reports isLogin=false, the server"
Write-Host "    validated and REJECTED the token -> forging cannot produce"
Write-Host "    an authenticated state, therefore cannot unlock location."
Write-Host "  - if any forged variant reported isLogin=true, that would be a"
Write-Host "    real authentication bypass and would need immediate reporting."
