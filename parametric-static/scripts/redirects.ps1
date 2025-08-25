# parametric-static/scripts/redirects.ps1
param(
  [switch]$Add,
  [switch]$List,
  [switch]$Disable,
  [switch]$Enable,
  [switch]$Remove,
  [int]$Index = -1,
  [string]$From,
  [string]$To,
  [int]$Code = 301,
  [string]$File
)

# ---------------- env / paths ----------------
$__here = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")
$paths = Get-ASDPaths
$Root  = $paths.Root

$DefaultFile = Join-Path $Root "redirects.json"
if (-not $File) { $File = $DefaultFile }

# ---------------- helpers ----------------

function New-ArrayList { New-Object System.Collections.ArrayList }

function To-ArrayList { param($x)
  $list = New-ArrayList
  if ($null -eq $x) { return $list }
  if ($x -is [System.Collections.IEnumerable] -and -not ($x -is [string])) { foreach ($i in $x) { [void]$list.Add($i) } }
  else { [void]$list.Add($x) }
  return $list
}

function Ensure-ArrayList { param($x)
  if ($x -is [System.Collections.ArrayList]) { return $x }
  return (To-ArrayList $x)
}

function Get-Count { param($x)
  if ($null -eq $x) { return 0 }
  if ($x -is [System.Collections.ICollection]) { return $x.Count }
  if ($x -is [System.Array]) { return $x.Length }
  if ($x -is [System.Collections.IEnumerable] -and -not ($x -is [string])) { $n=0; foreach($i in $x){$n++}; return $n }
  return 1
}

function Fix-Urlish([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $s }
  $s = $s.Trim()
  # Fix single-slash schemes: https:/... -> https://...
  $s = $s -replace '^((?:https?|HTTP|Http):)/(?=[^/])', '$1//'  # PS 5.1-safe regex
  return $s
}

function Normalize-Pathish([string]$p) {
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  $p = Fix-Urlish $p
  if ($p -match '^(https?://)') { return $p }
  if (-not $p.StartsWith('/')) { $p = '/' + $p }
  return $p
}

function Migrate-Entry { param($r)
  if ($null -eq $r) { return $r }
  # old -> new: disabled => enabled
  if ($r.PSObject.Properties.Name -contains 'disabled' -and -not ($r.PSObject.Properties.Name -contains 'enabled')) {
    $enabled = -not ([bool]$r.disabled)
    if ($r.PSObject.Properties.Name -contains 'enabled') { $r.enabled = $enabled }
    else { Add-Member -InputObject $r -NotePropertyName enabled -NotePropertyValue $enabled -Force | Out-Null }
    try { $r.PSObject.Properties.Remove('disabled') | Out-Null } catch {}
  }
  if (-not ($r.PSObject.Properties.Name -contains 'enabled')) {
    Add-Member -InputObject $r -NotePropertyName enabled -NotePropertyValue $true -Force | Out-Null
  }
  if (-not ($r.PSObject.Properties.Name -contains 'code')) {
    Add-Member -InputObject $r -NotePropertyName code -NotePropertyValue 301 -Force | Out-Null
  }

  # NEW: sanitize from/to strings
  if ($r.PSObject.Properties.Match('from').Count -gt 0 -and $r.from) { $r.from = Normalize-Pathish ([string]$r.from) }
  if ($r.PSObject.Properties.Match('to').Count   -gt 0 -and $r.to)   { $r.to   = Normalize-Pathish ([string]$r.to)   }
  return $r
}

function Load-Redirects { param([string]$path)
  if (-not (Test-Path $path)) { return (New-ArrayList) }
  try {
    $raw = Get-Content $path -Raw
    if ([string]::IsNullOrWhiteSpace($raw)) { return (New-ArrayList) }
    if ($raw -notmatch '^\s*[\[\{]') { throw "Not JSON" }
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    $arr = To-ArrayList $obj
    $out = New-ArrayList
    foreach ($e in $arr) { [void]$out.Add((Migrate-Entry $e)) }
    return $out
  } catch {
    Write-Warning "[redirects] Could not parse $path; backing up and starting fresh. $($_.Exception.Message)"
    try { Copy-Item $path ($path + ".corrupt.bak") -Force } catch {}
    return (New-ArrayList)
  }
}

function Save-Redirects { param($items, [string]$path)
  $items = Ensure-ArrayList $items
  $dir = Split-Path -Parent $path
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
  $ary = @(); foreach ($i in $items) { $ary += ,$i }  # force array, keep order
  $json = ConvertTo-Json -InputObject $ary -Depth 6
  Set-Content -Encoding UTF8 $path $json
  Write-Host "[redirects] Saved -> $path"
}

function Validate-Index { param([int]$i, $arr)
  $list  = Ensure-ArrayList $arr
  $count = Get-Count $list
  if ($i -lt 0 -or $i -ge $count) {
    Write-Error "Index out of range. Use -List to see entries." ; exit 1
  }
}

# ---------------- load ----------------
$items = Ensure-ArrayList (Load-Redirects -path $File)

# ---------------- ops -----------------

if ($Add) {
  if ([string]::IsNullOrWhiteSpace($From) -or [string]::IsNullOrWhiteSpace($To)) {
    Write-Error 'Use -Add -From "/old" -To "/new" or -To "https://domain/path" [-Code 301]' ; exit 1
  }
  $From = Normalize-Pathish $From
  $To   = Normalize-Pathish $To
  if ($From -notmatch '^(\/|https?://)') { Write-Error '-From must start with "/" or "http(s)://".' ; exit 1 }
  if ($To   -notmatch '^(\/|https?://)') { Write-Error '-To must start with "/" or "http(s)://".'   ; exit 1 }
  if ($Code -notin 301,302,307,308) { $Code = 301 }

  $new = [pscustomobject]@{ from=$From; to=$To; code=$Code; enabled=$true }
  $items = Ensure-ArrayList $items
  [void]$items.Add($new)

  Save-Redirects -items $items -path $File
  Write-Host "[redirects] added: $From -> $To (code $Code)"
  Write-Host ("[redirects] total: {0}" -f (Get-Count $items))
  exit 0
}

if ($List) {
  Write-Host "[redirects] entries:"
  $items = Ensure-ArrayList $items
  $count = Get-Count $items
  if ($count -eq 0) { Write-Host "  (none)"; exit 0 }
  for ($i = 0; $i -lt $count; $i++) {
    $r = $items[$i]
    $state = if ($r.PSObject.Properties.Match('enabled').Count -gt 0 -and $r.enabled -eq $false) { "DISABLED" } else { "ENABLED" }
    $code  = if ($r.PSObject.Properties.Match('code').Count -gt 0 -and $r.code) { $r.code } else { 301 }
    $from  = if ($r.PSObject.Properties.Match('from').Count -gt 0) { $r.from } else { "(missing from)" }
    $to    = if ($r.PSObject.Properties.Match('to').Count   -gt 0) { $r.to }   else { "(missing to)" }
    Write-Host ("  #{0}: {1} -> {2}  (code {3}, {4})" -f $i, $from, $to, $code, $state)
  }
  Write-Host ("[redirects] total: {0}" -f $count)
  exit 0
}

if ($Disable) {
  $items = Ensure-ArrayList $items
  Validate-Index -i $Index -arr $items
  if ($null -eq $items[$Index].PSObject.Properties['enabled']) {
    Add-Member -InputObject $items[$Index] -NotePropertyName enabled -NotePropertyValue $true -Force | Out-Null
  }
  $items[$Index].enabled = $false
  Save-Redirects -items $items -path $File
  Write-Host ("[redirects] disabled #{0}: {1} -> {2}" -f $Index, $items[$Index].from, $items[$Index].to)
  exit 0
}

if ($Enable) {
  $items = Ensure-ArrayList $items
  Validate-Index -i $Index -arr $items
  if ($null -eq $items[$Index].PSObject.Properties['enabled']) {
    Add-Member -InputObject $items[$Index] -NotePropertyName enabled -NotePropertyValue $true -Force | Out-Null
  }
  $items[$Index].enabled = $true
  Save-Redirects -items $items -path $File
  Write-Host ("[redirects] enabled #{0}: {1} -> {2}" -f $Index, $items[$Index].from, $items[$Index].to)
  exit 0
}

if ($Remove) {
  $items = Ensure-ArrayList $items
  Validate-Index -i $Index -arr $items
  $removed = $items[$Index]
  $items.RemoveAt($Index)
  Save-Redirects -items $items -path $File
  if ($removed) { Write-Host ("[redirects] removed #{0}: {1} -> {2}" -f $Index, $removed.from, $removed.to) }
  else { Write-Host ("[redirects] removed #{0}" -f $Index) }
  Write-Host ("[redirects] total: {0}" -f (Get-Count $items))
  exit 0
}

Write-Host @"
Usage:
  redirects.ps1 -Add -From "/old" -To "/new" [-Code 301]
  redirects.ps1 -List
  redirects.ps1 -Disable -Index N
  redirects.ps1 -Enable  -Index N
  redirects.ps1 -Remove  -Index N
  (optional) -File <path\to\redirects.json>
"@
exit 0
