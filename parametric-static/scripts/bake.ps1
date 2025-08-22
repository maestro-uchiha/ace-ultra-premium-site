# ============================================
#  Amaterasu Static Deploy (ASD) - bake.ps1
#  Works on GitHub Pages (project subpath) and custom domains
#  - Wraps HTML with layout.html and {{PREFIX}}
#  - Rewrites root-absolute links → prefix-relative
#  - Normalizes en/em dashes (and mojibake) to "|"
#  - Rebuilds /blog/ index (now prefers <title>, falls back to first <h1>)
#  - Regenerates robots.txt and sitemap.xml from config.site.url + actual files
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

# --- Normalize dashes (UTF-8 and common mojibake) to pipe
function Normalize-DashesToPipe {
  param([string]$s)
  if ($null -eq $s) { return $s }
  $pipe = '|'
  $s = $s.Replace([string][char]0x2013, $pipe) # –
  $s = $s.Replace([string][char]0x2014, $pipe) # —
  $s = $s.Replace('&ndash;', $pipe).Replace('&mdash;', $pipe)
  $seq_en = [string]([char]0x00E2)+[char]0x0080+[char]0x0093
  $seq_em = [string]([char]0x00E2)+[char]0x0080+[char]0x0094
  $s = $s.Replace($seq_en, $pipe).Replace($seq_em, $pipe)
  return $s
}

# --- Convert root-absolute links (href/src/action="/...") to prefix-relative
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

# --- Get canonical base URL from config.site.url (absolute, with trailing /)
function Get-BaseUrl {
  param([string]$CfgPath)
  $base = ""
  if (Test-Path $CfgPath) {
    try {
      $cfg = Get-Content $CfgPath -Raw | ConvertFrom-Json -ErrorAction Stop
      if ($cfg.site -and $cfg.site.url) { $base = [string]$cfg.site.url }
    } catch {}
  }
  if ([string]::IsNullOrWhiteSpace($base)) {
    Write-Warning "[ASD] config.site.url is empty; set it to your live origin (e.g., https://user.github.io/repo/)"
    $base = "/"
  }
  $base = $base.Trim()
  # Ensure exactly one trailing slash; collapse doubles in the path
  $base = $base -replace "://", "§§"
  $base = ($base.TrimEnd('/') + "/") -replace "/{2,}", "/"
  $base = $base -replace "§§", "://"
  return $base
}

# --- Optional CLI fallback from bake-config.json
$BakeCfg = Join-Path $RootDir "bake-config.json"
if ((-not $PSBoundParameters.ContainsKey('Brand') -or -not $PSBoundParameters.ContainsKey('Money')) -and (Test-Path $BakeCfg)) {
  try {
    $bc = Get-Content $BakeCfg -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('Brand') -and $bc.brand) { $Brand = $bc.brand }
    if (-not $PSBoundParameters.ContainsKey('Money') -and $bc.url)   { $Money = $bc.url }
  } catch { Write-Host "[ASD] Warning: bake-config.json invalid; ignoring." }
}

# ---- Build blog index list BEFORE wrapping (title: <title> or fallback to first <h1>)
$BlogIndex = Join-Path $BlogDir "index.html"
if (Test-Path $BlogIndex) {
  $posts = New-Object System.Collections.Generic.List[string]
  Get-ChildItem -Path $BlogDir -Filter *.html -File |
    Where-Object { $_.Name -ne "index.html" } |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object {
      $html  = Get-Content $_.FullName -Raw

      # Prefer <title>, else first <h1>, else filename
      $mTitle = [regex]::Match($html, '<title>(.*?)</title>', 'IgnoreCase')
      if ($mTitle.Success) {
        $title = $mTitle.Groups[1].Value
      } else {
        $mH1 = [regex]::Match($html, '(?is)<h1[^>]*>(.*?)</h1>')
        $title = if ($mH1.Success) { $mH1.Groups[1].Value } else { $_.BaseName }
      }

      $title = Normalize-DashesToPipe $title
      $date  = $_.LastWriteTime.ToString('yyyy-MM-dd')
      $rel   = $_.Name
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

# Legacy keys for back-compat
if (-not ($c | Get-Member -Name brand     -MemberType NoteProperty)) { Add-Member -InputObject $c -NotePropertyName brand     -NotePropertyValue $Brand } else { $c.brand     = $Brand }
if (-not ($c | Get-Member -Name moneySite -MemberType NoteProperty)) { Add-Member -InputObject $c -NotePropertyName moneySite -NotePropertyValue $Money } else { $c.moneySite = $Money }

$c | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $CfgPath
Write-Host "[ASD] config.json updated"

# ---- Extract original page content (markers > body > strip chrome; single <main> in layout)
function Extract-Content {
  param([string]$raw)
  $mark = [regex]::Match($raw, '(?is)<!--\s*ASD:CONTENT_START\s*-->(.*?)<!--\s*ASD:CONTENT_END\s*-->')
  if ($mark.Success) {
    $raw = $mark.Groups[1].Value
  } else {
    $body = [regex]::Match($raw, '(?is)<body[^>]*>(.*?)</body>')
    if ($body.Success) { $raw = $body.Groups[1].Value }
  }
  $raw = [regex]::Replace($raw, '(?is)<!--#include\s+virtual="partials/.*?-->', '')
  $raw = [regex]::Replace($raw, '(?is)<header\b[^>]*>.*?</header>', '')
  $raw = [regex]::Replace($raw, '(?is)<nav\b[^>]*>.*?</nav>', '')
  $raw = [regex]::Replace($raw, '(?is)<footer\b[^>]*>.*?</footer>', '')
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

    # Title: prefer first <h1> in content, fallback to filename
    $tm = [regex]::Match($content, '(?is)<h1[^>]*>(.*?)</h1>')
    $pageTitle = if ($tm.Success) { $tm.Groups[1].Value } else { $_.BaseName }

    # Compute prefix depth
    $prefix = Get-RelPrefix -FilePath $_.FullName

    # Build final page with markers embedded
    $final = $Layout
    $final = $final.Replace('{{CONTENT}}', $content)
    $final = $final.Replace('{{TITLE}}', $pageTitle)
    $final = $final.Replace('{{BRAND}}', $Brand)
    $final = $final.Replace('{{DESCRIPTION}}', $desc)
    $final = $final.Replace('{{MONEY}}', $Money)
    $final = $final.Replace('{{YEAR}}', "$Year")
    $final = $final.Replace('{{PREFIX}}', $prefix)

    # Fix absolute-root links and normalize dashes last
    $final = Rewrite-RootLinks $final $prefix
    $final = Normalize-DashesToPipe $final

    Set-Content -Encoding UTF8 $_.FullName $final
    Write-Host ("[ASD] Wrapped {0} (prefix='{1}')" -f $_.FullName.Substring($RootDir.Length+1), $prefix)
  }

# ---- Generate robots.txt and sitemap.xml from actual files + base URL
function Build-Sitemap-And-Robots {
  param([string]$BaseUrl)

  Write-Host "[ASD] Using base URL for sitemap/robots: $BaseUrl"

  $urls = New-Object System.Collections.Generic.List[object]

  Get-ChildItem -Path $RootDir -Recurse -File -Include *.html |
    Where-Object {
      $_.FullName -ne $LayoutPath -and
      $_.FullName -notmatch '\\assets\\' -and
      $_.FullName -notmatch '\\partials\\' -and
      $_.Name -ne '404.html'
    } |
    ForEach-Object {
      $rel = $_.FullName.Substring($RootDir.Length + 1) -replace '\\','/'
      # Convert "index" files to directory URLs
      if ($rel -ieq 'index.html') {
        $loc = $BaseUrl
      } elseif ($rel -match '^(.+)/index\.html$') {
        $loc = ($BaseUrl.TrimEnd('/') + '/' + $matches[1] + '/')
      } else {
        $loc = ($BaseUrl.TrimEnd('/') + '/' + $rel)
      }
      # Normalize accidental doubles after concat (keep scheme)
      $loc = $loc -replace ':/','://' -replace '/{2,}','/'
      $loc = $loc -replace '://','§§' -replace '/{2,}','/' -replace '§§','://'

      $last = $_.LastWriteTime.ToString('yyyy-MM-dd')
      $urls.Add([pscustomobject]@{ loc=$loc; lastmod=$last })
    }

  # sitemap.xml
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

  # robots.txt
  $robotsPath = Join-Path $RootDir 'robots.txt'
  $smap = ($BaseUrl.TrimEnd('/') + '/sitemap.xml')
  $smap = $smap -replace ':/','://' -replace '/{2,}','/'
  $smap = $smap -replace '://','§§' -replace '/{2,}','/' -replace '§§','://'
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
