# ============================================
#  Amaterasu Static Deploy (ASD) - bake.ps1
#  Layout-based (no partials), idempotent.
#  - Wraps each HTML with layout.html (single <main>)
#  - Computes {{PREFIX}} per page for nested dirs
#  - Rebuilds /blog/ index list
#  - Normalizes dash-like chars to "|"
#  - Rewrites root-absolute links to prefix-relative (GP + custom domains)
#  - Regenerates robots.txt and sitemap.xml from config.site.url + real files
# ============================================

param(
  [string]$Brand = "Amaterasu Static Deploy",
  [string]$Money = "https://example.com"
)

Write-Host "[ASD] Baking site for brand: $Brand, money site: $Money"

$RootDir    = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LayoutPath = Join-Path $RootDir "layout.html"
$BlogDir    = Join-Path $RootDir "blog"
$CfgPath    = Join-Path $RootDir "config.json"
$Year       = (Get-Date).Year

if (-not (Test-Path $LayoutPath)) {
  Write-Error "[ASD] layout.html not found at $LayoutPath"
  exit 1
}
$Layout = Get-Content $LayoutPath -Raw

# --- Normalize dashes (Unicode & entities & common mojibake) to pipe "|"
function Normalize-DashesToPipe {
  param([string]$s)
  if ($null -eq $s) { return $s }
  $pipe = '|'
  # Unicode en/em dash
  $s = $s.Replace([string][char]0x2013, $pipe)  # – 
  $s = $s.Replace([string][char]0x2014, $pipe)  # —
  # HTML entities
  $s = $s.Replace('&ndash;', $pipe).Replace('&mdash;', $pipe)
  # Common UTF-8 mojibake sequences
  $seq_en  = [string]([char]0x00E2)+[char]0x0080+[char]0x0093
  $seq_em  = [string]([char]0x00E2)+[char]0x0080+[char]0x0094
  $s = $s.Replace($seq_en, $pipe).Replace($seq_em, $pipe)
  return $s
}

# --- Convert root-absolute links to prefix-relative
function Rewrite-RootLinks {
  param([string]$html, [string]$prefix)
  if ([string]::IsNullOrEmpty($html)) { return $html }
  $hrefEval = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) 'href="'  + $prefix + $m.Groups[1].Value }
  $srcEval  = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) 'src="'   + $prefix + $m.Groups[1].Value }
  $actEval  = [System.Text.RegularExpressions.MatchEvaluator]{ param($m) 'action="' + $prefix + $m.Groups[1].Value }
  $html = [regex]::Replace($html, 'href="/(?!/)([^"#?]+)',   $hrefEval)
  $html = [regex]::Replace($html, 'src="/(?!/)([^"#?]+)',    $srcEval)
  $html = [regex]::Replace($html, 'action="/(?!/)([^"#?]+)', $actEval)
  return $html
}

# --- Build absolute base URL from config.site.url
function Get-BaseUrl {
  param([string]$CfgPath)
  $base = ""
  if (Test-Path $CfgPath) {
    try {
      $cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json -ErrorAction Stop
      if ($cfg.site -and $cfg.site.url) { $base = [string]$cfg.site.url }
    } catch { }
  }
  if ([string]::IsNullOrWhiteSpace($base)) {
    Write-Warning "[ASD] config.site.url is empty; sitemap/robots will use '/' which is not ideal for SEO."
    $base = "/"
  }
  # Normalize trailing slash to exactly one
  $base = $base.Trim() + "/"
  $base = $base -replace "://", "§§"    # protect scheme
  $base = ($base -replace "/{2,}", "/") # collapse doubles
  $base = $base -replace "§§", "://"
  return $base
}

# Optional: load bake-config.json if args not provided
$BakeCfg = Join-Path $RootDir "bake-config.json"
if ((-not $PSBoundParameters.ContainsKey('Brand') -or -not $PSBoundParameters.ContainsKey('Money')) -and (Test-Path $BakeCfg)) {
  try {
    $bc = Get-Content $BakeCfg -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('Brand') -and $bc.brand) { $Brand = $bc.brand }
    if (-not $PSBoundParameters.ContainsKey('Money') -and $bc.url)   { $Money = $bc.url }
  } catch { Write-Host "[ASD] Warning: bake-config.json invalid; ignoring." }
}

# ---- Build blog index (inject into content file BEFORE wrapping)
$BlogIndex = Join-Path $BlogDir "index.html"
if (Test-Path $BlogIndex) {
  $posts = New-Object System.Collections.Generic.List[string]
  Get-ChildItem -Path $BlogDir -Filter *.html -File |
    Where-Object { $_.Name -ne "index.html" } |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object {
      $html  = Get-Content $_.FullName -Raw
      $m     = [regex]::Match($html, '<title>(.*?)</title>', 'IgnoreCase')
      $title = if ($m.Success) { $m.Groups[1].Value } else { $_.BaseName }
      $title = Normalize-DashesToPipe $title
      $date  = $_.LastWriteTime.ToString('yyyy-MM-dd')
      $rel   = $_.Name  # relative to /blog/
      $li    = ('<li><a href="./{0}">{1}</a><small> | {2}</small></li>' -f $rel, $title, $date)
      $posts.Add($li)
    }
  $bi = Get-Content $BlogIndex -Raw
  $joined = [string]::Join([Environment]::NewLine, $posts)
  $pattern = '(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->'
  $replacement = @"
<!-- POSTS_START -->
$joined
<!-- POSTS_END -->
"@
  $bi = [regex]::Replace($bi, $pattern, $replacement)
  Set-Content -Encoding UTF8 $BlogIndex $bi
  Write-Host "[ASD] Blog index updated"
}

# ---- Compute {{PREFIX}} ('' at root, '../' in subdirs)
function Get-RelPrefix {
  param([string]$FilePath)
  $fileDir = Split-Path $FilePath -Parent
  $rootSeg = ($RootDir.TrimEnd('\')).Split('\')
  $dirSeg  = ($fileDir.TrimEnd('\')).Split('\')
  $depth = $dirSeg.Length - $rootSeg.Length
  if ($depth -lt 1) { return '' }
  $p = ''
  for ($i=0; $i -lt $depth; $i++) { $p += '../' }
  return $p
}

# ---- Load/prepare config.json (nested schema; keep legacy keys)
$c = $null
if (Test-Path $CfgPath) {
  try { $c = Get-Content $CfgPath -Raw | ConvertFrom-Json -ErrorAction Stop }
  catch { $c = [pscustomobject]@{} }
} else { $c = [pscustomobject]@{} }

if (-not ($c | Get-Member -Name site   -MemberType NoteProperty)) { $c | Add-Member -NotePropertyName site   -NotePropertyValue ([pscustomobject]@{}) }
if (-not ($c | Get-Member -Name author -MemberType NoteProperty)) { $c | Add-Member -NotePropertyName author -NotePropertyValue ([pscustomobject]@{}) }

$desc = if ($c.site.PSObject.Properties.Name -contains 'description' -and $c.site.description) {
  ($c.site.description -replace '\{\{BRAND\}\}', $Brand)
} else { "Premium $Brand | quality, reliability, trust." }

$c.site.name = $Brand
if (-not ($c.site.PSObject.Properties.Name -contains 'url')) {
  $c.site | Add-Member -NotePropertyName url -NotePropertyValue ''
} elseif ($c.site.url -match 'YOUR-DOMAIN\.example') {
  $c.site.url = ''
}
$c.site.description = $desc

if ($c.author.PSObject.Properties.Name -contains 'name' -and $c.author.name) {
  $c.author.name = ($c.author.name -replace '\{\{BRAND\}\}', $Brand)
} else {
  if (-not ($c.author.PSObject.Properties.Name -contains 'name')) {
    $c.author | Add-Member -NotePropertyName name -NotePropertyValue ("{0} Team" -f $Brand)
  } else { $c.author.name = ("{0} Team" -f $Brand) }
}

# Legacy keys for older assets
if (-not ($c | Get-Member -Name brand     -MemberType NoteProperty)) { Add-Member -InputObject $c -NotePropertyName brand     -NotePropertyValue $Brand } else { $c.brand     = $Brand }
if (-not ($c | Get-Member -Name moneySite -MemberType NoteProperty)) { Add-Member -InputObject $c -NotePropertyName moneySite -NotePropertyValue $Money } else { $c.moneySite = $Money }

$c | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $CfgPath
Write-Host "[ASD] config.json updated"

# ---- Extract original page content
function Extract-Content {
  param([string]$raw)
  # Markers first
  $mark = [regex]::Match($raw, '(?is)<!--\s*ASD:CONTENT_START\s*-->(.*?)<!--\s*ASD:CONTENT_END\s*-->')
  if ($mark.Success) {
    $raw = $mark.Groups[1].Value
  } else {
    # or <body> inner
    $body = [regex]::Match($raw, '(?is)<body[^>]*>(.*?)</body>')
    if ($body.Success) { $raw = $body.Groups[1].Value }
  }
  # strip old includes/chrome
  $raw = [regex]::Replace($raw, '(?is)<!--#include\s+virtual="partials/.*?-->', '')
  $raw = [regex]::Replace($raw, '(?is)<header\b[^>]*>.*?</header>', '')
  $raw = [regex]::Replace($raw, '(?is)<nav\b[^>]*>.*?</nav>', '')
  $raw = [regex]::Replace($raw, '(?is)<footer\b[^>]*>.*?</footer>', '')
  # unwrap <main>
  $m = [regex]::Match($raw, '(?is)<main\b[^>]*>(.*?)</main>')
  if ($m.Success) { $raw = $m.Groups[1].Value }
  $raw = [regex]::Replace($raw, '(?is)</?main\b[^>]*>', '')
  return $raw
}

# ---- Wrap every HTML (except layout.html) using layout and per-page PREFIX
Get-ChildItem -Path $RootDir -Recurse -File |
  Where-Object { $_.Extension -eq ".html" -and $_.FullName -ne $LayoutPath } |
  ForEach-Object {
    $raw = Get-Content $_.FullName -Raw
    $content = Extract-Content $raw
    # Title from first <h1>, fallback to filename
    $tm = [regex]::Match($content, '(?is)<h1[^>]*>(.*?)</h1>')
    $pageTitle = if ($tm.Success) { $tm.Groups[1].Value } else { $_.BaseName }
    # Compute prefix depth
    $prefix = Get-RelPrefix -FilePath $_.FullName
    # Build final page
    $final = $Layout
    $final = $final.Replace('{{CONTENT}}', $content)
    $final = $final.Replace('{{TITLE}}', $pageTitle)
    $final = $final.Replace('{{BRAND}}', $Brand)
    $final = $final.Replace('{{DESCRIPTION}}', $desc)
    $final = $final.Replace('{{MONEY}}', $Money)
    $final = $final.Replace('{{YEAR}}', "$Year")
    $final = $final.Replace('{{PREFIX}}', $prefix)
    # Routing: rewrite root-absolute to prefix-relative
    $final = Rewrite-RootLinks $final $prefix
    # Sanitize weird dashes last
    $final = Normalize-DashesToPipe $final
    Set-Content -Encoding UTF8 $_.FullName $final
    Write-Host ("[ASD] Wrapped {0} (prefix='{1}')" -f $_.FullName.Substring($RootDir.Length+1), $prefix)
  }

# ---- Generate robots.txt and sitemap.xml from actual files
function Build-Sitemap-And-Robots {
  param([string]$BaseUrl)

  $today = (Get-Date).ToString('yyyy-MM-dd')
  $urls  = New-Object System.Collections.Generic.List[object]

  # Collect html pages (exclude layout, assets, partials, 404)
  Get-ChildItem -Path $RootDir -Recurse -File -Include *.html |
    Where-Object {
      $_.FullName -ne $LayoutPath -and
      $_.FullName -notmatch '\\assets\\' -and
      $_.FullName -notmatch '\\partials\\' -and
      $_.Name -ne '404.html'
    } |
    ForEach-Object {
      $rel = $_.FullName.Substring($RootDir.Length + 1) -replace '\\','/'
      # index handling
      if ($rel -ieq 'index.html') {
        $loc = $BaseUrl
      } elseif ($rel -match '^(.+)/index\.html$') {
        $loc = ($BaseUrl.TrimEnd('/') + '/' + $matches[1] + '/').Replace('//','/')
        $loc = $loc -replace ':/','://'
      } else {
        $loc = $BaseUrl.TrimEnd('/') + '/' + $rel
        $loc = $loc -replace ':/','://'
      }
      $last = $_.LastWriteTime.ToString('yyyy-MM-dd')
      $urls.Add([pscustomobject]@{ loc=$loc; lastmod=$last })
    }

  # Write sitemap.xml
  $sitemapPath = Join-Path $RootDir 'sitemap.xml'
  $xml = New-Object System.Text.StringBuilder
  [void]$xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
  [void]$xml.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
  foreach($u in $urls | Sort-Object loc){
    [void]$xml.AppendLine("  <url><loc>$($u.loc)</loc><lastmod>$($u.lastmod)</lastmod></url>")
  }
  [void]$xml.AppendLine('</urlset>')
  Set-Content -Encoding UTF8 $sitemapPath $xml.ToString()
  Write-Host "[ASD] sitemap.xml generated ($($urls.Count) urls)"

  # Write robots.txt with absolute sitemap URL
  $robotsPath = Join-Path $RootDir 'robots.txt'
  $smap = ($BaseUrl.TrimEnd('/') + '/sitemap.xml') -replace ':/','://'
  $robots = @"
User-agent: *
Disallow:

Sitemap: $smap
"@
  Set-Content -Encoding UTF8 $robotsPath $robots
  Write-Host "[ASD] robots.txt generated"
}

$baseUrl = Get-BaseUrl -CfgPath $CfgPath
Build-Sitemap-And-Robots -BaseUrl $baseUrl

Write-Host "[ASD] Done."
