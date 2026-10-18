# Bilibili comment IP-location: video AGE / comment-SYSTEM coverage.
#
# GENUINE GAP in rounds 1-6
# -------------------------
# Every earlier probe used either the popular feed (all recent videos) or
# one fixed A2O video. Those all return reply_control with:
#
#     is_note_v2: true, biz_scene: opus_xxxxx
#
# i.e. the NEW opus/note comment system. Older videos use the TRADITIONAL
# comment system, which may populate a different field set -- including
# location. Testing only new videos would therefore systematically miss
# the field if it only exists on the legacy path.
#
# This script samples videos across a wide age range and reports the
# reply_control key set for each, so the two systems can be compared.
#
# Pure ASCII.

param()

$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$ref = 'https://www.bilibili.com/'
$cnShudi = [string][char]0x5C5E + [string][char]0x5730

$tmp = New-TemporaryFile
curl.exe -s -c $tmp -A $ua $ref -o NUL 2>&1 | Out-Null

function Get-Json($url) {
  $b = (& curl.exe -s -b $tmp -A $ua -H "Referer: $ref" $url 2>&1) -join "`n"
  try { return @{ raw = $b; json = ($b | ConvertFrom-Json) } } catch { return @{ raw = $b; json = $null } }
}

# Known-good old BVIDs spanning 2019-2024 (well-known videos, high comment
# counts). These predate the opus/note comment system.
$oldBvids = @(
  'BV1GJ411x7h7',   # 2019
  'BV1uT4y1P7CX',   # 2020
  'BV1fK4y1t7hj',   # 2021
  'BV1xx411c7mD',   # classic
  'BV17x411w7KC',   # classic
  'BV1BE411W7aB'    # 2018
)

Write-Host "=== sampling videos across ages ==="
Write-Host ""

$seen = @{}
$rows = @()

foreach ($bv in ($oldBvids | Select-Object -Unique)) {
  # bvid -> aid
  $v = Get-Json "https://api.bilibili.com/x/web-interface/view?bvid=$bv"
  if (-not $v.json -or $v.json.code -ne 0) {
    Write-Host "  $bv : view failed (code=$(if($v.json){$v.json.code}else{'?'}))"
    continue
  }
  $aid = $v.json.data.aid
  $pub = [DateTimeOffset]::FromUnixTimeSeconds($v.json.data.pubdate).ToString('yyyy-MM-dd')
  $title = $v.json.data.title
  if ($title.Length -gt 22) { $title = $title.Substring(0,22) + '...' }

  $c = Get-Json "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$aid&mode=2&next=0&ps=20"
  $code = '?'; $n = 0; $keys = ''; $isNote = ''
  if ($c.json) {
    if ($null -ne $c.json.code) { $code = $c.json.code }
    if ($c.json.data.replies) {
      $n = $c.json.data.replies.Count
      $rc = $c.json.data.replies[0].reply_control
      $keys = (($rc.PSObject.Properties | ForEach-Object Name) -join ',')
      if ($null -ne $rc.is_note_v2) { $isNote = $rc.is_note_v2 }
    }
  }
  $loc = ([regex]::Matches($c.raw, 'location')).Count
  $cn = ([regex]::Matches($c.raw, $cnShudi)).Count

  Write-Host ("  {0}  {1}  aid={2,-16} rep={3,-3} code={4,-5} loc x{5} shudi x{6}" -f `
      $pub, $bv, $aid, $n, $code, $loc, $cn)
  Write-Host ("      title: $title")
  Write-Host ("      keys : [$keys]")
  if ($isNote -ne '') { Write-Host ("      is_note_v2: $isNote") }
  Write-Host ""

  $rows += [pscustomobject]@{
    bvid = $bv; aid = $aid; pub = $pub; rep = $n
    loc = $loc; cn = $cn; keys = $keys; isNote = $isNote
  }
  Start-Sleep -Milliseconds 350
}

# ---------- also: popular feed with dm params, all 20 videos ----------
Write-Host "=== popular feed, 20 videos, key-set census ==="
$pop = Get-Json "https://api.bilibili.com/x/web-interface/popular?ps=20&pn=1"
$keySets = @{}
$locTotal = 0
if ($pop.json -and $pop.json.data.list) {
  foreach ($v in $pop.json.data.list) {
    $c = Get-Json "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$($v.aid)&mode=2&next=0&ps=20"
    $locTotal += ([regex]::Matches($c.raw, 'location')).Count
    if ($c.json -and $c.json.data.replies -and $c.json.data.replies.Count -gt 0) {
      $k = (($c.json.data.replies[0].reply_control.PSObject.Properties | ForEach-Object Name) -join ',')
      $keySets[$k] = ($keySets[$k] + 1)
    }
    Start-Sleep -Milliseconds 250
  }
}
Write-Host "  distinct reply_control key sets across 20 videos:"
foreach ($k in $keySets.Keys) { Write-Host ("    x$($keySets[$k])  [$k]") }
Write-Host ("  total 'location' occurrences: $locTotal")

# ---------- summary ----------
Write-Host ""
Write-Host "=== summary ==="
$anyLoc = ($rows | Measure-Object -Property loc -Sum).Sum
if ($anyLoc -gt 0) {
  Write-Host "  LOCATION FOUND in at least one sample -- inspect rows above."
} else {
  Write-Host "  No location in any sampled video, across 2018-2024."
  Write-Host "  Key sets seen:"
  $rows | ForEach-Object { Write-Host ("    [$($_.keys)]") } | Select-Object -Unique
}
