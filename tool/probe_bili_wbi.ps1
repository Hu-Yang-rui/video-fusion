# Bilibili wbi signature probe (real network).
#
# Purpose: verify whether /x/v2/reply/wbi/main returns IP location
# (reply_control.location) when the request is correctly wbi-signed.
# The earlier test hit -403 because the signature was missing, so it
# never actually tested this endpoint.
#
# wbi algorithm (public, same as the browser):
#   1. GET /x/web-interface/nav -> data.wbi_img.img_url / sub_url
#   2. take both file names without extension, concat = raw
#   3. reorder raw by mixinKeyEncTab, first 32 chars = mixin_key
#   4. params + wts, sort by key, strip !'()* , urlencode
#   5. md5(query + mixin_key) = w_rid
#
# NOTE: this file is deliberately pure ASCII. Windows PowerShell 5.1 reads
# BOM-less files with the ANSI code page and would corrupt any non-ASCII
# text, which previously broke generated XML.

param(
  [long]$Aid = 117427861985029,
  [int]$Mode = 2,
  [int]$Ps = 20
)

$ErrorActionPreference = 'Stop'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'

function Get-Md5Hex([string]$text) {
  $md5 = [System.Security.Cryptography.MD5]::Create()
  $bytes = [System.Text.Encoding]::UTF8.GetBytes($text)
  $hash = $md5.ComputeHash($bytes)
  return ($hash | ForEach-Object { $_.ToString('x2') }) -join ''
}

# ---- 1. fetch wbi keys ----
$navRaw = curl.exe -s -A $ua -H "Referer: https://www.bilibili.com/" "https://api.bilibili.com/x/web-interface/nav" 2>&1
$nav = $navRaw | ConvertFrom-Json
if (-not $nav.data.wbi_img) { throw "no wbi_img: $navRaw" }

$imgKey = ($nav.data.wbi_img.img_url -split '/')[-1] -replace '\.\w+$', ''
$subKey = ($nav.data.wbi_img.sub_url -split '/')[-1] -replace '\.\w+$', ''
Write-Host "img_key=$imgKey"
Write-Host "sub_key=$subKey"

# ---- 2. mixin key ----
$tab = @(46,47,18,2,53,8,23,32,15,50,10,31,58,3,45,35,27,43,5,49,33,9,42,19,
         29,28,14,39,12,38,41,13,37,48,7,16,24,55,40,61,26,17,0,1,60,51,30,4,
         22,25,54,21,56,59,6,63,57,62,11,36,20,34,44,52)
$raw = $imgKey + $subKey
$mixin = -join ($tab | ForEach-Object { $raw[$_] })
$mixinKey = $mixin.Substring(0, 32)
Write-Host "mixin_key=$mixinKey"

# ---- 3. sign ----
function New-WbiQuery($params, [string]$mixinKey) {
  $params['wts'] = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
  $keys = $params.Keys | Sort-Object
  $pairs = foreach ($k in $keys) {
    $v = [string]$params[$k]
    $v = $v -replace "[!'()*]", ''
    "$([uri]::EscapeDataString($k))=$([uri]::EscapeDataString($v))"
  }
  $query = $pairs -join '&'
  $wRid = Get-Md5Hex ($query + $mixinKey)
  return "$query&w_rid=$wRid"
}

$params = @{
  type           = 1
  oid            = $Aid
  mode           = $Mode
  pagination_str = '{"offset":""}'
  plat           = 1
  seek_rpid      = ''
  web_location   = 1315875
}
$signed = New-WbiQuery $params $mixinKey
$url = "https://api.bilibili.com/x/v2/reply/wbi/main?$signed"

Write-Host ""
Write-Host "=== request wbi/main (mode=$Mode) ==="
$resp = curl.exe -s -A $ua -H "Referer: https://www.bilibili.com/" $url 2>&1
$resp | Out-File -Encoding utf8 "build\raw-wbi-reply.json"

$j = $resp | ConvertFrom-Json
Write-Host "code=$($j.code)  message=$($j.message)"
if ($j.code -ne 0) {
  $preview = $resp.Substring(0, [Math]::Min(300, $resp.Length))
  Write-Host "body preview: $preview"
  exit 1
}

$replies = $j.data.replies
Write-Host "replies=$($replies.Count)  bodyLen=$($resp.Length)"

# ---- 4. inspect reply_control per reply ----
Write-Host ""
Write-Host "=== first 5 reply_control ==="
$replies | Select-Object -First 5 | ForEach-Object {
  $rc = $_.reply_control
  if ($rc) {
    $keys = ($rc.PSObject.Properties | ForEach-Object Name) -join ','
    Write-Host "rpid=$($_.rpid)  keys=[$keys]  location='$($rc.location)'"
  } else {
    Write-Host "rpid=$($_.rpid)  reply_control=(null)"
  }
}

$withLoc = ($replies | Where-Object { $_.reply_control.location }).Count
Write-Host ""
Write-Host "=== replies with location: $withLoc / $($replies.Count) ==="

Write-Host ""
Write-Host "=== keyword scan over full body ==="
foreach ($kw in @('location', 'region', 'province', 'city')) {
  $n = [regex]::Matches($resp, $kw).Count
  Write-Host "$kw : $n"
}
