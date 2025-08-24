param(
  [Parameter(Mandatory=$true)][string]$OldSlug,
  [Parameter(Mandatory=$true)][string]$NewSlug,
  [string]$Title,
  [switch]$LeaveRedirect,
  [switch]$Force
)

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$blog = Join-Path $Root "blog"
$old  = Join-Path $blog ($OldSlug + ".html")
$new  = Join-Path $blog ($NewSlug + ".html")

if (-not (Test-Path $old)) { Write-Error "Source not found: $old"; exit 1 }
if ((Test-Path $new) -and -not $Force) { Write-Error "Target already exists:`n$new"; exit 1 }

# Read original, compute new title if given
$src = Get-Content $old -Raw
if ($Title) {
  # <title>
  if ($src -match '(?is)<title>(.*?)</title>') {
    $src = [regex]::Replace($src,'(?is)(<title>)(.*?)(</title>)',('$1' + [regex]::Escape($Title).Replace('\','\\') + '$3'),1)
  } else {
    $src = $src -replace '(?is)<head>','<head>' + "`r`n<title>" + $Title + "</title>"
  }
  # first <h1>
  if ($src -match '(?is)<h1[^>]*>(.*?)</h1>') {
    $src = [regex]::Replace($src,'(?is)(<h1[^>]*>)(.*?)(</h1>)',('$1' + [regex]::Escape($Title).Replace('\','\\') + '$3'),1)
  }
}

# Write/overwrite target
$src | Set-Content -Encoding UTF8 $new
Write-Host "[ASD] Wrote blog/$NewSlug.html"

# Leave redirect stub on old file if requested, else delete
if ($LeaveRedirect) {
  # Build base url if available
  $base = ""
  $cfgPath = Join-Path $Root "config.json"
  if (Test-Path $cfgPath) {
    try { $cfg = Get-Content $cfgPath -Raw | ConvertFrom-Json; if ($cfg.site -and $cfg.site.url) { $base = [string]$cfg.site.url } } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($base)) {
    # fall back to repo-relative path
    $targetHref = "/blog/$NewSlug.html"
  } else {
    $base = ($base.TrimEnd('/') + "/") -replace "/{2,}","/"
    $targetHref = $base + "blog/$NewSlug.html"
  }

  $stub = @"
<!doctype html><meta charset="utf-8">
<title>Moved</title>
<meta http-equiv="refresh" content="0; url=$targetHref">
<script>location.replace("$targetHref");</script>
<p>This page has moved to <a href="$targetHref">$targetHref</a>.</p>
"@
  $stub | Set-Content -Encoding UTF8 $old
  Write-Host "[ASD] Redirect stub left at blog/$OldSlug.html -> $targetHref"

  # Also register in redirects.json
  $redirPath = Join-Path $Root "redirects.json"
  $list = @()
  if (Test-Path $redirPath) {
    try { $list = Get-Content $redirPath -Raw | ConvertFrom-Json } catch { $list = @() }
  }
  $entry = [pscustomobject]@{
    from     = "/blog/$OldSlug.html"
    to       = "/blog/$NewSlug.html"
    code     = 301
    disabled = $false
  }
  $list = @($list) + @($entry)
  ($list | ConvertTo-Json -Depth 5) | Set-Content -Encoding UTF8 $redirPath
  Write-Host "[ASD] redirects.json updated"
} else {
  Remove-Item $old -Force
  Write-Host "[ASD] Removed blog/$OldSlug.html"
}
