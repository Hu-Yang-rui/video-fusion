# Bilibili comment payload: does it contain an actual IP ADDRESS?
#
# Earlier rounds searched for the string "location" and for province
# names -- i.e. the *coarsened* IP-location label. This script answers a
# different question: does any raw IPv4/IPv6 literal appear anywhere in
# the response, which would be a real IP leak?
#
# Checks:
#   1. Regex IPv4 (dotted quad, with octet range validation)
#   2. Regex IPv6 (hex groups with :: shorthand)
#   3. Known IP-bearing field names (ip, client_ip, remote_addr, x-forwarded)
#   4. /x/web-interface/zone -- returns the REQUESTER's own IP; proves the
#      server knows your IP while never publishing other users'
#
# Pure ASCII.

param([long]$Aid = 117427861985029)

$ErrorActionPreference = 'Continue'
$ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/124.0.0.0 Safari/537.36'
$ref = 'https://www.bilibili.com/'

$tmp = New-TemporaryFile
curl.exe -s -c $tmp -A $ua $ref -o NUL 2>&1 | Out-Null

function ScanIps($label, $body) {
  if ($null -eq $body) { Write-Host "  $label : (null)"; return }
  $len = $body.Length
  Write-Host "  $label : len=$len"

  # IPv4: four octets 0-255
  $v4 = [regex]::Matches($body, '(?<!\d)(?:(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)\.){3}(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)(?!\d)')
  $v4uniq = $v4 | ForEach-Object { $_.Value } | Sort-Object -Unique
  Write-Host ("    IPv4 literals: " + $v4.Count + " (distinct " + $v4uniq.Count + ")")
  if ($v4uniq.Count -gt 0) {
    foreach ($ip in ($v4uniq | Select-Object -First 20)) {
      # show context so we can tell CDN host vs leak
      $idx = $body.IndexOf($ip)
      $ctx = $body.Substring([Math]::Max(0, $idx - 40), [Math]::Min(90, $body.Length - [Math]::Max(0, $idx - 40)))
      $ctx = $ctx -replace "`n", ' ' -replace "`r", ' '
      Write-Host ("      $ip   ctx=...$ctx...")
    }
  }

  # IPv6: at least two groups plus :: or 8 groups
  $v6 = [regex]::Matches($body, '(?<![0-9a-fA-F:])(?:[0-9a-fA-F]{1,4}:){2,7}[0-9a-fA-F]{0,4}(?![0-9a-fA-F:])')
  $v6uniq = $v6 | ForEach-Object { $_.Value } | Where-Object { $_.Contains(':') -and ($_.Contains('::') -or ($_ -split ':').Count -ge 6) } | Sort-Object -Unique
  Write-Host ("    IPv6 candidates: " + $v6uniq.Count)
  foreach ($ip in ($v6uniq | Select-Object -First 8)) { Write-Host "      $ip" }

  # field-name hunt
  foreach ($kw in @('"ip"', 'client_ip', 'remote_addr', 'x-forwarded', 'ip_addr', 'ipaddr', 'clientip')) {
    $n = ([regex]::Matches($body, [regex]::Escape($kw))).Count
    if ($n -gt 0) { Write-Host "    field '$kw' x$n" }
  }
}

# ---------- 1. comment payload ----------
Write-Host "=== 1. comment response: raw IP scan ==="
$url = "https://api.bilibili.com/x/v2/reply/main?type=1&oid=$Aid&mode=2&next=0&ps=20"
$body = (& curl.exe -s -b $tmp -A $ua -H "Referer: $ref" $url 2>&1) -join "`n"
ScanIps 'reply/main' $body
$body | Out-File -Encoding utf8 'build\ipscan-reply.json'

# ---------- 2. also check the wbi variant + sub-reply ----------
Write-Host ""
Write-Host "=== 2. other comment surfaces ==="
$body2 = (& curl.exe -s -b $tmp -A $ua -H "Referer: $ref" "https://api.bilibili.com/x/v2/reply?type=1&oid=$Aid&pn=1&ps=20&sort=2" 2>&1) -join "`n"
ScanIps 'legacy reply' $body2

# ---------- 3. requester's own IP ----------
Write-Host ""
Write-Host "=== 3. /x/web-interface/zone : the REQUESTER's own IP ==="
$z = (& curl.exe -s -b $tmp -A $ua -H "Referer: $ref" "https://api.bilibili.com/x/web-interface/zone" 2>&1) -join "`n"
Write-Host "  raw: $z"
try {
  $zj = $z | ConvertFrom-Json
  Write-Host ("  code=" + $zj.code)
  Write-Host ("  addr    = " + $zj.data.addr)
  Write-Host ("  country = " + $zj.data.country)
  Write-Host ("  province= " + $zj.data.province)
  Write-Host ("  city    = " + $zj.data.city)
  Write-Host ("  isp     = " + $zj.data.isp)
  Write-Host ""
  Write-Host "  NOTE: this is YOUR OWN egress IP, returned because you are"
  Write-Host "  the caller. It is not any commenter's IP."
} catch { Write-Host "  parse failed" }

Write-Host ""
Write-Host "=== done ==="
