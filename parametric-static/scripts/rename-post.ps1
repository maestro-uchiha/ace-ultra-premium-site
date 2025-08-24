param(
  [Parameter(Mandatory=$true)][string]$OldSlug,
  [Parameter(Mandatory=$true)][string]$NewSlug,
  [switch]$LeaveRedirect
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

. "$PSScriptRoot\_lib.ps1"
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

$Base  = Ensure-AbsoluteBaseUrl $cfg.site.url

$src = Join-Path $S.Blog ($OldSlug + ".html")
$dst = Join-Path $S.Blog ($NewSlug + ".html")

if (-not (Test-Path $src)) { Write-Error "Source not found: $src"; exit 1 }
if (Test-Path $dst)        { Write-Error "Target already exists: $dst"; exit 1 }

# move file
Move-Item -Force $src $dst
Write-Host ("[ASD] Wrote blog/{0}.html" -f $NewSlug)

# leave stub/redirect if requested
if ($LeaveRedirect) {
  $abs = if ($Base -match '^[a-z]'){ ($Base.TrimEnd('/') + '/blog/' + $NewSlug + '.html') } else { ('/blog/' + $NewSlug + '.html') }
  $stub = @"
<!doctype html>
<meta http-equiv="refresh" content="0; url=$abs">
<link rel="canonical" href="$abs">
<title>Redirecting...</title>
<p>Moving to <a href="$abs">$abs</a></p>
"@
  Set-Content -Encoding UTF8 $src $stub
  Write-Host ("[ASD] Redirect stub left at blog/{0}.html -> {1}" -f $OldSlug, $abs)
}

# also update redirects.json (from old path to new path)
$redirPath = Join-Path $S.Root "redirects.json"
$items = @()
if (Test-Path $redirPath) {
  try { $items = (Get-Content $redirPath -Raw | ConvertFrom-Json -ErrorAction Stop) } catch { $items = @() }
}
if ($null -eq $items) { $items = @() }

$from = "/blog/$OldSlug.html"
$to   = "/blog/$NewSlug.html"
$newItem = [pscustomobject]@{ from = $from; to = $to; code = 301; active = $true }
$items = @($items) + @($newItem)
$items | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $redirPath
Write-Host "[ASD] redirects.json updated"
