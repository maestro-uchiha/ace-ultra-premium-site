param(
  [ValidateSet("add","remove","disable","enable","list","test","clean","backup","restore")]
  [Parameter(Mandatory=$true)][string]$Action,

  [string]$From,       # e.g. /blog/old.html  (supports *)
  [string]$To,         # e.g. /blog/new.html  (relative or absolute)
  [int]$Code = 301,    # 301 default
  [int]$Index,         # for remove/disable/enable by number from list
  [string]$Path,       # for test, e.g. /blog/old.html
  [string]$BackupFile  # for restore
)

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root
$JsonPath = Join-Path $Root "redirects.json"

function Ensure-Array($x) {
  if ($null -eq $x) { return @() }
  if ($x -is [System.Collections.IEnumerable] -and -not ($x -is [string])) { return @($x) }
  return @($x)
}
function Load-Redirects {
  if (Test-Path $JsonPath) {
    try { return (Get-Content $JsonPath -Raw | ConvertFrom-Json | Ensure-Array) } catch { return @() }
  } else { return @() }
}
function Save-Redirects($arr) {
  $arr | ConvertTo-Json -Depth 8 | Set-Content -Encoding UTF8 $JsonPath
  Write-Host ("[redirects] saved -> redirects.json ({0} rules)" -f $arr.Count)
}
function Normalize-Path([string]$p) {
  if (-not $p) { return $null }
  $p = $p.Trim()
  $p = $p -replace '^[a-z]+://[^/]+',''  # strip scheme/host if absolute
  if ($p -notmatch '^/') { $p = '/' + $p }
  $p = $p -replace '/+','/'
  return $p
}
function Pattern-ToRegex([string]$pattern) {
  $esc = [regex]::Escape($pattern)
  return '^' + ($esc -replace '\\\*','.*') + '$'
}

$rules = Load-Redirects

switch ($Action) {

  'list' {
    if ($rules.Count -eq 0) { Write-Host "(no redirects)"; break }
    $i = 1
    foreach ($r in $rules) {
      $code = 301
      if ($r.PSObject.Properties.Name -contains 'type' -and $r.type) { $code = [int]$r.type }
      $flag = if ($r.PSObject.Properties.Name -contains 'disabled' -and $r.disabled) { 'DISABLED' } else { 'OK' }
      Write-Host ("{0,3}. {1}  ->  {2}  [{3}]  {4}" -f $i, $r.from, $r.to, $code, $flag)
      $i++
    }
  }

  'add' {
    $fromN = Normalize-Path $From
    if (-not $fromN) { throw "add: -From required" }
    if (-not $To)    { throw "add: -To required" }
    $toN = if ($To -match '^(https?:)?//') { $To.Trim() } else { Normalize-Path $To }

    $existing = $rules | Where-Object { $_.from -eq $fromN -and $_.to -eq $toN }
    if ($existing) {
      $existing[0].type = $Code
      if (-not ($existing[0].PSObject.Properties.Name -contains 'disabled')) { $existing[0] | Add-Member disabled $false } else { $existing[0].disabled = $false }
      Write-Host "[redirects] updated existing rule"
    } else {
      $rules += [pscustomobject]@{ from=$fromN; to=$toN; type=$Code; disabled=$false }
      Write-Host ("[redirects] added: {0} -> {1} [{2}]" -f $fromN, $toN, $Code)
    }
    $rules = $rules | Sort-Object -Property from, to
    Save-Redirects $rules
  }

  'remove' {
    if ($Index) {
      if ($Index -lt 1 -or $Index -gt $rules.Count) { throw "remove: index out of range" }
      $removed = $rules[$Index-1]
      $new = New-Object System.Collections.Generic.List[object]
      for ($i=0; $i -lt $rules.Count; $i++) { if ($i -ne ($Index-1)) { $new.Add($rules[$i]) } }
      $rules = $new
      Write-Host ("[redirects] removed #{0}: {1} -> {2}" -f $Index, $removed.from, $removed.to)
    } elseif ($From) {
      $fromN = Normalize-Path $From
      $before = $rules.Count
      $rules = $rules | Where-Object { $_.from -ne $fromN }
      Write-Host ("[redirects] removed all with from={0} (removed {1})" -f $fromN, ($before - $rules.Count))
    } else {
      throw "remove: specify -Index or -From"
    }
    Save-Redirects $rules
  }

  'disable' {
    if ($Index) {
      if ($Index -lt 1 -or $Index -gt $rules.Count) { throw "disable: index out of range" }
      if (-not ($rules[$Index-1].PSObject.Properties.Name -contains 'disabled')) { $rules[$Index-1] | Add-Member disabled $true } else { $rules[$Index-1].disabled = $true }
      Write-Host ("[redirects] disabled #{0}" -f $Index)
    } elseif ($From) {
      $fromN = Normalize-Path $From; $n = 0
      foreach ($r in $rules) { if ($r.from -eq $fromN) { if (-not ($r.PSObject.Properties.Name -contains 'disabled')) { $r | Add-Member disabled $true } else { $r.disabled = $true }; $n++ } }
      Write-Host ("[redirects] disabled {0} rule(s) with from={1}" -f $n, $fromN)
    } else { throw "disable: specify -Index or -From" }
    Save-Redirects $rules
  }

  'enable' {
    if ($Index) {
      if ($Index -lt 1 -or $Index -gt $rules.Count) { throw "enable: index out of range" }
      if (-not ($rules[$Index-1].PSObject.Properties.Name -contains 'disabled')) { $rules[$Index-1] | Add-Member disabled $false } else { $rules[$Index-1].disabled = $false }
      Write-Host ("[redirects] enabled #{0}" -f $Index)
    } elseif ($From) {
      $fromN = Normalize-Path $From; $n = 0
      foreach ($r in $rules) { if ($r.from -eq $fromN) { if (-not ($r.PSObject.Properties.Name -contains 'disabled')) { $r | Add-Member disabled $false } else { $r.disabled = $false }; $n++ } }
      Write-Host ("[redirects] enabled {0} rule(s) with from={1}" -f $n, $fromN)
    } else { throw "enable: specify -Index or -From" }
    Save-Redirects $rules
  }

  'test' {
    if (-not $Path) { throw "test: -Path required (e.g., /blog/old.html)" }
    $p = Normalize-Path $Path
    $hit = $null
    foreach ($r in $rules) {
      if ($r.PSObject.Properties.Name -contains 'disabled' -and $r.disabled) { continue }
      $re = [regex](Pattern-ToRegex $r.from)
      if ($re.IsMatch($p)) { $hit = $r; break }
    }
    if ($hit) {
      $cfg = $null; if (Test-Path ".\config.json") { try { $cfg = Get-Content .\config.json -Raw | ConvertFrom-Json } catch {} }
      $base = if ($cfg -and $cfg.site -and $cfg.site.url) { $cfg.site.url } else { "https://YOUR-DOMAIN.example/" }
      $dest = $hit.to
      if ($dest -notmatch '^(https?:)?//') {
        $dest = (New-Object System.Uri((New-Object System.Uri($base)), $dest.TrimStart('/'))).AbsoluteUri
      }
      $code = 301; if ($hit.PSObject.Properties.Name -contains 'type' -and $hit.type) { $code = [int]$hit.type }
      Write-Host ("MATCH: {0}  ->  {1}  [{2}]" -f $p, $dest, $code)
    } else {
      Write-Host ("NO MATCH: {0}" -f $p)
    }
  }

  'clean' {
    $out  = New-Object System.Collections.Generic.List[object]
    $seen = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($r in ($rules | Sort-Object -Property from, to)) {
      if (-not $r.from -or -not $r.to) { continue }
      $key = "{0}|{1}" -f $r.from, $r.to
      if ($seen.Add($key)) { $out.Add($r) }
    }
    Save-Redirects $out
  }

  'backup' {
    $dir = Join-Path $Root ".redirects-backup"
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir | Out-Null }
    $stamp = (Get-Date -Format 'yyyyMMdd-HHmmss')
    $file = Join-Path $dir ("redirects-$stamp.json")
    if (Test-Path $JsonPath) {
      Copy-Item $JsonPath $file -Force
      Write-Host ("[redirects] backup -> {0}" -f $file)
    } else {
      Write-Host "[redirects] nothing to backup"
    }
  }

  'restore' {
    if (-not $BackupFile) { throw "restore: -BackupFile required" }
    if (-not (Test-Path $BackupFile)) { throw "restore: file not found: $BackupFile" }
    Copy-Item $BackupFile $JsonPath -Force
    Write-Host ("[redirects] restored from {0}" -f $BackupFile)
  }
}
