# Bilibili comment IP-location: content TYPE coverage + pinned comment + deep pages.
#
# Real gaps left by earlier rounds:
#
#   1. `type` param. All earlier probes used type=1 (video). Bilibili's
#      comment API also serves:
#        type=11  image/text post (图文)
#        type=12  article (专栏)
#        type=17  dynamic (动态 / opus)
#      These can be different backends. If `location` exists anywhere,
#      it may only be populated for some content types.
#
#   2. `upper.top` -- the pinned (UP-owned) comment is returned in a
#      SEPARATE field from `replies`. Earlier scans only walked
#      `data.replies`, so a pinned comment's location would be missed.
#      Also `data.top` and `data.top_replies`.
#
#   3. Deeper pagination -- `next` cursor page 2/3. Field sets can
#      differ between page 1 (which may be cached/prewarmed) and
#      later pages.
#
# Pure ASCII.

param([long]$Aid = 117427861985029, [string]$Bvid = 'BV1VVpo6gEYg')

$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$ref = 'https://www.bilibili.com/'
$cnShudi = [string][char]0x5C5E + [string][char]0x5730

function Get-Json($url) {
  $b = (& curl.exe -s -A $ua -H "Referer: $ref" $url 2>&1) -join "`n"
  try { return @{ raw = $b; json = ($b | ConvertFrom-Json) } } catch { return @{ raw = $b; json = $null } }
}

function Describe($label, $raw, $json) {
  $code = '?'; $n = 0; $keySet = ''; $withLoc = 0
  $loc = ([regex]::Matches($raw, 'location')).Count
  $cn = ([regex]::Matches($raw, $cnShudi)).Count
  if ($json) {
    if ($null -ne $json.code) { $code = $json.code }
    if ($json.data.replies) {
      $n = $json.data.replies.Count
      $withLoc = ($json.data.replies | Where-Object { $_.reply_control.location }).Count
      $keySet = (($json.data.replies[0].reply_control.PSObject.Properties | ForEach-Object Name) -join ',')
    }
  }
  Write-Host ("{0,-40} len={1,-7} code={2,-6} replies={3,-3} loc x{4} shudi x{5} withLoc={6}" -f `
      $label, $raw.Length, $code, $n, $loc, $cn, $withLoc)
  if ($keySet) { Write-Host ("    keys: [$keySet]") }
}

$tmp = New-TemporaryFile
curl.exe -s -c $tmp -A $ua $ref -o NUL 2>&1 | Out-Null

# ---------- harvest real oids of other content types ----------
Write-Host "=== harvest oids from a video's comments ==="
$vid = Get-Json "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20"
$cvids = @(); $dynids = @()
if ($vid.json -and $vid.json.data.replies) {
  foreach ($r in $vid.json.data.replies) {
    if ($r.note_cvid_str) { $cvids += $r.note_cvid_str }
    if ($r.dynamic_id_str -and $r.dynamic_id_str -ne '0') { $dynids += $r.dynamic_id_str }
  }
}
Write-Host ("  cvid candidates: " + ($(if ($cvids) { $cvids -join ',' } else { 'none' })))
Write-Host ("  dynamic id candidates: " + ($(if ($dynids) { $dynids -join ',' } else { 'none' })))

# opus id seen in reply_control.biz_scene earlier
$opus = ''
if ($vid.json -and $vid.json.data.replies) {
  foreach ($r in $vid.json.data.replies) {
    if ($r.reply_control.biz_scene -and $r.reply_control.biz_scene -like 'opus_*') {
      $opus = ($r.reply_control.biz_scene -replace '^opus_', '')
      break
    }
  }
}
Write-Host ("  opus id: " + $(if ($opus) { $opus } else { 'none' }))
Write-Host ""

# ---------- 1. content types ----------
Write-Host "=== 1. content type coverage ==="
Describe 'type=1  video' $vid.raw $vid.json

if ($cvids.Count -gt 0) {
  $r = Get-Json "https://api.bilibili.com/x/v2/reply/main?type=12&oid=$($cvids[0])&mode=2&next=0&ps=20"
  Describe "type=12 article oid=$($cvids[0])" $r.raw $r.json
} else {
  Write-Host "  type=12 article: no cvid harvested, skipped"
}

if ($dynids.Count -gt 0) {
  $r = Get-Json "https://api.bilibili.com/x/v2/reply/main?type=17&oid=$($dynids[0])&mode=2&next=0&ps=20"
  Describe "type=17 dynamic oid=$($dynids[0])" $r.raw $r.json
} else {
  Write-Host "  type=17 dynamic: no dynamic id harvested, skipped"
}

if ($opus) {
  $r = Get-Json "https://api.bilibili.com/x/v2/reply/main?type=17&oid=$opus&mode=2&next=0&ps=20"
  Describe "type=17 opus oid=$opus" $r.raw $r.json
}

# type=11 (image/text post) -- try the opus id too, plus the aid
foreach ($oid in @($Aid, $opus) | Where-Object { $_ }) {
  $r = Get-Json "https://api.bilibili.com/x/v2/reply/main?type=11&oid=$oid&mode=2&next=0&ps=20"
  Describe "type=11 imagepost oid=$oid" $r.raw $r.json
}

# ---------- 2. pinned comment fields ----------
Write-Host ""
Write-Host "=== 2. pinned / top comment fields (missed by earlier scans) ==="
if ($vid.json -and $vid.json.data) {
  $d = $vid.json.data
  foreach ($slot in @('top', 'top_replies', 'upper', 'note')) {
    $val = $d.$slot
    if ($null -eq $val) { Write-Host "  data.$slot = (absent)"; continue }
    $s = $val | ConvertTo-Json -Depth 6 -Compress
    $loc = ([regex]::Matches($s, 'location')).Count
    $cn = ([regex]::Matches($s, $cnShudi)).Count
    Write-Host ("  data.{0} len={1} loc x{2} shudi x{3}" -f $slot, $s.Length, $loc, $cn)
    if ($slot -eq 'upper' -and $d.upper.top) {
      $ut = $d.upper.top
      $k = ''
      if ($ut.reply_control) {
        $k = ($ut.reply_control.PSObject.Properties | ForEach-Object Name) -join ','
      }
      Write-Host ("    upper.top reply_control keys: [{0}]" -f $k)
      Write-Host ("    upper.top location: '{0}'" -f $ut.reply_control.location)
    }
    if ($slot -eq 'top' -and $val.reply_control) {
      $k = ($val.reply_control.PSObject.Properties | ForEach-Object Name) -join ','
      Write-Host ("    top reply_control keys: [{0}]" -f $k)
    }
  }
}

# ---------- 3. deeper pages ----------
Write-Host ""
Write-Host "=== 3. deeper pagination (page 2/3) ==="
$next = 0
if ($vid.json -and $vid.json.data.cursor) { $next = $vid.json.data.cursor.next }
$page = 1
while ($next -gt 0 -and $page -le 3) {
  $r = Get-Json "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=$next&ps=20"
  Describe "page $($page+1) next=$next" $r.raw $r.json
  if ($r.json -and $r.json.data.cursor) {
    $newNext = $r.json.data.cursor.next
    if (-not $newNext -or $newNext -eq $next) { break }
    $next = $newNext
  } else { break }
  $page++
  Start-Sleep -Milliseconds 300
}

Write-Host ""
Write-Host "=== done ==="
