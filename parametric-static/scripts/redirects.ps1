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

# Load config
$__here = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")
$__cfg   = Get-ASDConfig
$Brand   = $__cfg.SiteName
$Money   = $__cfg.StoreUrl
$Desc    = $__cfg.Description
$Base    = $__cfg.BaseUrl
$__paths = Get-ASDPaths

$Root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$DefaultFile = Join-Path $Root "redirects.json"
if (-not $File) { $File = $DefaultFile }

function Ensure-Array {
  param($x)
  if ($null -eq $x) { return @() }
  if ($x -is [System.Array]) { return $x }
  return @($x)
}

function Load-Redirects {
  param([string]$path)
  if (!(Test-Path $path)) { return @() }
  try {
    $raw = Get-Content $path -Raw
    if ($raw -notmatch '^\s*[\[\{]') { throw "Not JSON" }
    $obj = $raw | ConvertFrom-Json -ErrorAction Stop
    return (Ensure-Array $obj)
  } catch {
    Write-Warning "[redirects] Could not parse redirects.json; backing up and starting fresh. $($_.Exception.Message)"
    try { Copy-Item $path ($path + ".corrupt.bak") -Force } catch {}
    return @()
  }
}

function Save-Redirects {
  param([object[]]$items, [string]$path)
  $items = Ensure-Array $items
  # IMPORTANT: pass as InputObject, not via pipeline (PS 5.1 quirk)
  $json = ConvertTo-Json -InputObject $items -Depth 6
  Set-Content -Encoding UTF8 $path $json
  Write-Host "[redirects] Saved -> $path"
}

function Validate-Index {
  param([int]$i, [object[]]$arr)
  $arr = Ensure-Array $arr
  if ($i -lt 0 -or $i -ge $arr.Count) {
    Write-Error "Index out of range. Use -List to see entries." ; exit 1
  }
}

# ---- Load (array-safe)
$items = Load-Redirects -path $File
$items = Ensure-Array $items

# ---- Operations
if ($Add) {
  if ([string]::IsNullOrWhiteSpace($From) -or [string]::IsNullOrWhiteSpace($To)) {
    Write-Error 'Use -Add -From "/old" -To "/new-or-https://domain/path" [-Code 301]' ; exit 1
  }
  if ($From -notmatch '^(\/|https?:\/\/)') { Write-Error '-From must start with "/" or "http(s)://".' ; exit 1 }
  if ($To   -notmatch '^(\/|https?:\/\/)') { Write-Error '-To must start with "/" or "http(s)://".'   ; exit 1 }
  if ($Code -notin 301,302,307,308) { $Code = 301 }

  $new = [pscustomobject]@{
    from     = $From
    to       = $To
    code     = $Code
    disabled = $false
  }

  $items = @($items + $new)
  Save-Redirects -items $items -path $File
  Write-Host "[redirects] added: $From -> $To (code $Code)"
  Write-Host ("[redirects] total: {0}" -f $items.Count)
  exit 0
}

if ($List) {
  $items = Ensure-Array $items
  Write-Host "[redirects] entries:"
  if ($items.Count -eq 0) { Write-Host "  (none)"; exit 0 }
  for ($i = 0; $i -lt $items.Count; $i++) {
    $r = $items[$i]
    $state = if ($r.disabled) { "DISABLED" } else { "ACTIVE" }
    Write-Host ("  #{0}: {1} -> {2}  (code {3}, {4})" -f $i, $r.from, $r.to, $r.code, $state)
  }
  Write-Host ("[redirects] total: {0}" -f $items.Count)
  exit 0
}

if ($Disable) {
  $items = Ensure-Array $items
  Validate-Index -i $Index -arr $items
  if ($null -eq $items[$Index].PSObject.Properties['disabled']) {
    Add-Member -InputObject $items[$Index] -NotePropertyName disabled -NotePropertyValue $false
  }
  $items[$Index].disabled = $true
  Save-Redirects -items $items -path $File
  Write-Host ("[redirects] disabled #{0}: {1} -> {2}" -f $Index, $items[$Index].from, $items[$Index].to)
  exit 0
}

if ($Enable) {
  $items = Ensure-Array $items
  Validate-Index -i $Index -arr $items
  if ($null -eq $items[$Index].PSObject.Properties['disabled']) {
    Add-Member -InputObject $items[$Index] -NotePropertyName disabled -NotePropertyValue $false
  }
  $items[$Index].disabled = $false
  Save-Redirects -items $items -path $File
  Write-Host ("[redirects] enabled #{0}: {1} -> {2}" -f $Index, $items[$Index].from, $items[$Index].to)
  exit 0
}

if ($Remove) {
  $items = Ensure-Array $items
  Validate-Index -i $Index -arr $items
  $removed = $items[$Index]
  $keep = New-Object System.Collections.Generic.List[object]
  for ($i=0; $i -lt $items.Count; $i++) {
    if ($i -ne $Index) { $keep.Add($items[$i]) }
  }
  $items = @($keep.ToArray())
  Save-Redirects -items $items -path $File
  if ($removed) {
    Write-Host ("[redirects] removed #{0}: {1} -> {2}" -f $Index, $removed.from, $removed.to)
  } else {
    Write-Host ("[redirects] removed #{0}" -f $Index)
  }
  Write-Host ("[redirects] total: {0}" -f $items.Count)
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
