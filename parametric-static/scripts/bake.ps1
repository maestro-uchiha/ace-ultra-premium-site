<# ============================================
   Amaterasu Static Deploy (ASD) - bake.ps1
   - Uses config.json as the single source of truth
   - Generates instant redirect stubs from redirects.json
   - Wraps HTML with layout.html and {{PREFIX}} (except redirect stubs)
   - Rewrites root-absolute links -> prefix-relative
   - Normalizes dashes to "|"
   - Rebuilds /blog/ index (basic) while skipping redirect stubs
   - Generates sitemap.xml and preserves robots.txt + appends one Sitemap line
   - Preserves file timestamps so baking doesn't change dates
   ============================================ #>

# Load shared helpers
. "$PSScriptRoot\_lib.ps1"

# --- local helpers (PS 5.1-safe) ---
function TryParse-Date([string]$v) {
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  [datetime]$out = [datetime]::MinValue
  $ok = [datetime]::TryParse(
    $v,
    [System.Globalization.CultureInfo]::InvariantCulture,
    [System.Globalization.DateTimeStyles]::AssumeLocal,
    [ref]$out
  )
  if ($ok) { return $out } else { return $null }
}

function Get-MetaDateFromHtml([string]$html) {
  if ([string]::IsNullOrWhiteSpace($html)) { return $null }

  # 1) <meta name="date" content="YYYY-MM-DD">
  $m = [regex]::Match($html, '(?is)<meta\s+name\s*=\s*["'']date["'']\s+content\s*=\s*["'']([^"''<>]+)["'']')
  if ($m.Success) {
    $dt = TryParse-Date ($m.Groups[1].Value.Trim())
    if ($dt) { return $dt.ToString('yyyy-MM-dd') }
  }

  # 2) <time datetime="...">
  $t = [regex]::Match($html, '(?is)<time[^>]+datetime\s*=\s*["'']([^"''<>]+)["'']')
  if ($t.Success) {
    $dt = TryParse-Date ($t.Groups[1].Value.Trim())
    if ($dt) { return $dt.ToString('yyyy-MM-dd') }
  }

  return $null
}

function Preserve-FileTimes($path, [datetime]$origCreateUtc, [datetime]$origWriteUtc) {
  try { (Get-Item $path).CreationTimeUtc  = $origCreateUtc } catch {}
  try { (Get-Item $path).LastWriteTimeUtc = $origWriteUtc  } catch {}
}

function Collapse-DoubleSlashesPreserveSchemeLocal([string]$url) {
  if ([string]::IsNullOrWhiteSpace($url)) { return $url }
  if ($url -match '^(https?://)(.*)$') {
    $scheme = $matches[1]
    $rest   = $matches[2] -replace '/{2,}','/'
    return $scheme + $rest
  }
  return ($url -replace '/{2,}','/')
}

# --- BaseUrl normalization (prevents https:/ and https:/// variants) ---
function Normalize-BaseUrlLocal([string]$b) {
  if ([string]::IsNullOrWhiteSpace($b)) { return "/" }
  $b = $b.Trim()
  # Drop accidental leading slashes before scheme: "/https://..." -> "https://..."
  $b = $b -replace '^/+(?=https?:)', ''
  # Force exactly two slashes after scheme
  $b = $b -replace '^((?:https?):)/{1,}', '$1//'
  if ($b -match '^(https?://)(.+)$') {
    $scheme = $matches[1]; $rest = $matches[2]
    # Avoid "https:///host..." by trimming leading slash from the rest
    $rest = $rest.TrimStart('/')
    $b = $scheme + $rest
    if (-not $b.EndsWith('/')) { $b += '/' }
    return $b
  } else {
    # rooted path form (e.g., "/repo/" or "repo")
    $b = '/' + $b.Trim('/') + '/'
    return $b
  }
}

function Resolve-RedirectTarget([string]$to, [string]$base) {
  if ([string]::IsNullOrWhiteSpace($to)) { return $base }
  $to = $to.Trim()
  if ($to -match '^[a-z]+://') {
    return Collapse-DoubleSlashesPreserveSchemeLocal($to)
  }
  if ($to.StartsWith('/')) {
    return Collapse-DoubleSlashesPreserveSchemeLocal(($base.TrimEnd('/') + $to))
  }
  # relative path -> root relative under $base
  return Collapse-DoubleSlashesPreserveSchemeLocal(($base.TrimEnd('/') + '/' + $to))
}

function Make-RedirectOutputPath([string]$from, [string]$root) {
  if ([string]::IsNullOrWhiteSpace($from)) { return $null }
  $rel = $from.Trim()
  if ($rel.StartsWith('/')) { $rel = $rel.TrimStart('/') }

  # If it's a folder (no .html extension), use index.html inside it.
  if (-not ($rel -match '\.html?$')) {
    if ($rel.EndsWith('/')) {
      $rel = $rel + 'index.html'
    } else {
      $rel = $rel + '/index.html'
    }
  }

  $out = Join-Path $root $rel
  $dir = Split-Path $out -Parent
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  return $out
}

function HtmlEscape([string]$s) {
  if ($null -eq $s) { return '' }
  $s = $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
  return $s
}

function JsString([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace('\','\\').Replace("'", "\'")
}

function Write-RedirectStub([string]$outPath, [string]$absUrl, [int]$code) {
  # Keep very small, meta refresh (instant) + JS replace + fallback link
  $href = HtmlEscape($absUrl)
  $jsu  = JsString($absUrl)

  $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Redirectingâ€¦</title>
  <meta name="robots" content="noindex">
  <meta http-equiv="refresh" content="0;url=$href">
  <script>location.replace('$jsu');</script>
</head>
<body>
<!-- ASD:REDIRECT to="$href" code="$code" -->
  <p>If you are not redirected, <a href="$href">click here</a>.</p>
</body>
</html>
"@
  Set-Content -Encoding UTF8 $outPath $html
}

function Generate-RedirectStubs([string]$redirectsJson, [string]$root, [string]$base) {
  if (-not (Test-Path $redirectsJson)) { return 0 }
  $items = @()
  try {
    $raw = Get-Content $redirectsJson -Raw
    if (-not [string]::IsNullOrWhiteSpace($raw)) {
      $items = $raw | ConvertFrom-Json
    }
  } catch {
    Write-Warning "[ASD] redirects.json is invalid; skipping."
    return 0
  }
  if ($null -eq $items) { return 0 }
  $count = 0
  foreach ($r in $items) {
    $enabled = $true
    if ($r.PSObject.Properties.Name -contains 'enabled') {
      $enabled = [bool]$r.enabled
    }
    if (-not $enabled) { continue }

    $from = $null; $to = $null; $code = 301
    if ($r.PSObject.Properties.Name -contains 'from') { $from = [string]$r.from }
    if ($r.PSObject.Properties.Name -contains 'to')   { $to   = [string]$r.to }
    if ($r.PSObject.Properties.Name -contains 'code') { try { $code = [int]$r.code } catch { $code = 301 } }

    if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) { continue }

    # Only support exact paths (static hosting); skip wildcards like "/*"
    if ($from -match '\*') { continue }

    $outPath = Make-RedirectOutputPath $from $root
    $abs     = Resolve-RedirectTarget $to $base
    Write-RedirectStub $outPath $abs $code
    $count++
  }
  return $count
}

$paths = Get-ASDPaths
$cfg   = Get-ASDConfig

$RootDir    = $paths.Root
$LayoutPath = $paths.Layout
$BlogDir    = $paths.Blog

$Brand = $cfg.SiteName
$Money = $cfg.StoreUrl
$Desc  = $cfg.Description
# Normalize BaseUrl aggressively here to avoid malformed scheme/host/path
$Base  = Normalize-BaseUrlLocal ([string]$cfg.BaseUrl)
$Year  = (Get-Date).Year

Write-Host "[ASD] Baking... brand='$Brand' store='$Money' base='$Base'"

# --- Generate redirect stubs from redirects.json (instant redirect) ---
$made = Generate-RedirectStubs -redirectsJson $paths.Redirects -root $RootDir -base $Base
if ($made -gt 0) { Write-Host "[ASD] Redirect stubs generated: $made" }

if (-not (Test-Path $LayoutPath)) {
  Write-Error "[ASD] layout.html not found at $LayoutPath"
  exit 1
}
$Layout = Get-Content $LayoutPath -Raw

# ---- Build /blog/ index (stable dates: meta date, else CreationTime) ----
$BlogIndex = Join-Path $BlogDir "index.html"
if (Test-Path $BlogIndex) {

  # Collect post metadata first (skip stubs), then sort by explicit date key
  $entries = New-Object System.Collections.ArrayList

  Get-ChildItem -Path $BlogDir -Filter *.html -File |
    Where-Object { $_.Name -ne "index.html" } |
    ForEach-Object {
      $html  = Get-Content $_.FullName -Raw

      # Skip redirect stubs
      if ($html -match '(?is)<!--\s*ASD:REDIRECT\b') { return }

      # Title: prefer <title>, else first <h1>, else filename (then normalize dashes)
      $mTitle = [regex]::Match($html, '(?is)<title>(.*?)</title>')
      if ($mTitle.Success) {
        $title = $mTitle.Groups[1].Value
      } else {
        $mH1 = [regex]::Match($html, '(?is)<h1[^>]*>(.*?)</h1>')
        $title = if ($mH1.Success) { $mH1.Groups[1].Value } else { $_.BaseName }
      }
      $title = Normalize-DashesToPipe $title

      # Date: prefer meta; else file CreationTime (stable, not modified by bake)
      $metaDate = Get-MetaDateFromHtml $html
      if ($metaDate) {
        $dateDisplay = $metaDate
        $sortKey     = TryParse-Date $metaDate
      } else {
        $dateDisplay = $_.CreationTime.ToString('yyyy-MM-dd')
        $sortKey     = $_.CreationTime
      }

      $null = $entries.Add([pscustomobject]@{
        Title     = $title
        Href      = $_.Name
        DateText  = $dateDisplay
        SortKey   = $sortKey
      })
    }

  # Sort by SortKey (desc), then build list items
  $posts = New-Object System.Collections.Generic.List[string]
  foreach ($e in ($entries | Sort-Object SortKey -Descending)) {
    $li = ('<li><a href="./{0}">{1}</a><small> | {2}</small></li>' -f $e.Href, $e.Title, $e.DateText)
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

# ---- Wrap every HTML (except layout.html) using layout and per-page PREFIX ----
Get-ChildItem -Path $RootDir -Recurse -File |
  Where-Object { $_.Extension -eq ".html" -and $_.FullName -ne $LayoutPath } |
  ForEach-Object {
    # Save original timestamps so the bake doesn't change them
    $it = Get-Item $_.FullName
    $origCreateUtc = $it.CreationTimeUtc
    $origWriteUtc  = $it.LastWriteTimeUtc

    $raw = Get-Content $_.FullName -Raw

    # Skip wrapping redirect stubs completely (keep them tiny/fast)
    if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') {
      Write-Host ("[ASD] Skipped wrapping redirect stub: {0}" -f $_.FullName.Substring($RootDir.Length+1))
      return
    }

    $content = Extract-Content $raw

    # Title: prefer first <h1> in content, fallback to filename
    $tm = [regex]::Match($content, '(?is)<h1[^>]*>(.*?)</h1>')
    $pageTitle = if ($tm.Success) { $tm.Groups[1].Value } else { $_.BaseName }

    # Compute prefix depth
    $prefix = Get-RelPrefix -RootDir $RootDir -FilePath $_.FullName

    # Build final page with markers embedded
    $final = $Layout
    $final = $final.Replace('{{CONTENT}}', $content)
    $final = $final.Replace('{{TITLE}}', $pageTitle)
    $final = $final.Replace('{{BRAND}}', $Brand)
    $final = $final.Replace('{{DESCRIPTION}}', $Desc)
    $final = $final.Replace('{{MONEY}}', $Money)
    $final = $final.Replace('{{YEAR}}', "$Year")
    $final = $final.Replace('{{PREFIX}}', $prefix)

    # Fix absolute-root links and normalize dashes last
    $final = Rewrite-RootLinks $final $prefix
    $final = Normalize-DashesToPipe $final

    Set-Content -Encoding UTF8 $_.FullName $final

    # Restore timestamps (preserve original dates)
    Preserve-FileTimes $_.FullName $origCreateUtc $origWriteUtc

    Write-Host ("[ASD] Wrapped {0} (prefix='{1}')" -f $_.FullName.Substring($RootDir.Length+1), $prefix)
  }

# ---- Generate sitemap.xml and preserve robots.txt while appending one Sitemap line ----
Write-Host "[ASD] Using base URL for sitemap: $Base"

$urls = New-Object System.Collections.Generic.List[object]
Get-ChildItem -Path $RootDir -Recurse -File -Include *.html |
  Where-Object {
    $_.FullName -ne $LayoutPath -and
    $_.FullName -notmatch '\\assets\\' -and
    $_.FullName -notmatch '\\partials\\' -and
    $_.Name -ne '404.html'
  } |
  ForEach-Object {
    $raw = Get-Content $_.FullName -Raw
    # Skip redirect stubs in sitemap
    if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') { return }

    $rel = $_.FullName.Substring($RootDir.Length + 1) -replace '\\','/'

    if ($rel -ieq 'index.html') {
      $loc = $Base
    } elseif ($rel -match '^(.+)/index\.html$') {
      $loc = ($Base.TrimEnd('/') + '/' + $matches[1] + '/')
    } else {
      $loc = ($Base.TrimEnd('/') + '/' + $rel)
    }
    $loc = Collapse-DoubleSlashesPreserveSchemeLocal $loc

    # After restoring times, LastWriteTime reflects real content changes
    $last = (Get-Item $_.FullName).LastWriteTime.ToString('yyyy-MM-dd')
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

# robots.txt: preserve or create default, then write ONE canonical Sitemap line
$robotsPath = Join-Path $RootDir 'robots.txt'

$robots = if (Test-Path $robotsPath) {
  Get-Content $robotsPath -Raw
} else {
@"
# Allow trusted search engine bots
User-agent: Googlebot
Disallow:

User-agent: Bingbot
Disallow:

User-agent: Slurp
Disallow:

User-agent: DuckDuckBot
Disallow:

User-agent: YandexBot
Disallow:

# Allow reputable AI bots
User-agent: ChatGPT-User
Disallow:

User-agent: GPTBot
Disallow:

User-agent: PerplexityBot
Disallow:

User-agent: YouBot
Disallow:

User-agent: Google-Extended
Disallow:

User-agent: AnthropicBot
Disallow:

User-agent: Neevabot
Disallow:

User-agent: Amazonbot
Disallow:

# Block SEO/backlink crawlers
User-agent: AhrefsBot
Disallow: /

User-agent: SemrushBot
Disallow: /

User-agent: MJ12bot
Disallow: /

User-agent: rogerbot
Disallow: /

User-agent: dotbot
Disallow: /

User-agent: Ubersuggest
Disallow: /

# Catch-all: Block everything else
User-agent: *
Disallow: /
"@
}

# Strip any prior Sitemap lines
$robots = [regex]::Replace($robots, '(?im)^\s*Sitemap:\s*.*\r?\n?', '')

# Build sitemap reference: absolute if Base is absolute; else relative
if ($Base -match '^[a-z]+://') {
  $absMap = (New-Object Uri((New-Object Uri($Base)), 'sitemap.xml')).AbsoluteUri
} else {
  $absMap = 'sitemap.xml'
}

# Ensure trailing newline and append the single canonical Sitemap line
if ($robots -notmatch "\r?\n$") { $robots += "`r`n" }
$robots += "Sitemap: $absMap`r`n"

Set-Content -Encoding UTF8 $robotsPath $robots
Write-Host "[ASD] robots.txt: Sitemap -> $absMap"

Write-Host "[ASD] Done."

