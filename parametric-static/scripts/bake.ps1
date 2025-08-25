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
   - Trims content block and collapses extra blank lines around <main>
   - NEW: Inject recent posts into index.html between ASD markers
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
  $m = [regex]::Match($html, '(?is)<meta\s+name\s*=\s*(?:"|'')date(?:"|'')\s+content\s*=\s*(?:"|'')([^"''<>]+)(?:"|'')')
  if ($m.Success) {
    $dt = TryParse-Date ($m.Groups[1].Value.Trim())
    if ($dt) { return $dt.ToString('yyyy-MM-dd') }
  }

  # 2) <time datetime="...">
  $t = [regex]::Match($html, '(?is)<time[^>]+datetime\s*=\s*(?:"|'')([^"''<>]+)(?:"|'')')
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
  # Ensure exactly two slashes after scheme
  $b = $b -replace '^((?:https?):)/{1,}', '$1//'
  if ($b -match '^(https?://)(.+)$') {
    $scheme = $matches[1]; $rest = $matches[2]
    $rest = $rest.TrimStart('/')       # avoid https:///host
    $b = $scheme + $rest
    if (-not $b.EndsWith('/')) { $b += '/' }
    return $b
  } else {
    return '/' + $b.Trim('/') + '/'    # rooted path form
  }
}

function Resolve-RedirectTarget([string]$to, [string]$base) {
  if ([string]::IsNullOrWhiteSpace($to)) { return $base }
  $to = $to.Trim()
  if ($to -match '^[a-z]+://') { return Collapse-DoubleSlashesPreserveSchemeLocal($to) }
  if ($to.StartsWith('/'))     { return Collapse-DoubleSlashesPreserveSchemeLocal(($base.TrimEnd('/') + $to)) }
  return Collapse-DoubleSlashesPreserveSchemeLocal(($base.TrimEnd('/') + '/' + $to))
}

function Make-RedirectOutputPath([string]$from, [string]$root) {
  if ([string]::IsNullOrWhiteSpace($from)) { return $null }
  $rel = $from.Trim()
  if ($rel.StartsWith('/')) { $rel = $rel.TrimStart('/') }
  if (-not ($rel -match '\.html?$')) {
    if ($rel.EndsWith('/')) { $rel = $rel + 'index.html' } else { $rel = $rel + '/index.html' }
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
  $href = HtmlEscape($absUrl)
  $jsu  = JsString($absUrl)
  $html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>Redirecting…</title>
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
    if (-not [string]::IsNullOrWhiteSpace($raw)) { $items = $raw | ConvertFrom-Json }
  } catch {
    Write-Warning "[ASD] redirects.json is invalid; skipping."
    return 0
  }
  if ($null -eq $items) { return 0 }
  $count = 0
  foreach ($r in $items) {
    $enabled = $true
    if ($r.PSObject.Properties.Name -contains 'enabled') { $enabled = [bool]$r.enabled }
    if (-not $enabled) { continue }

    $from = $null; $to = $null; $code = 301
    if ($r.PSObject.Properties.Name -contains 'from') { $from = [string]$r.from }
    if ($r.PSObject.Properties.Name -contains 'to')   { $to   = [string]$r.to }
    if ($r.PSObject.Properties.Name -contains 'code') { try { $code = [int]$r.code } catch { $code = 301 } }

    if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)) { continue }
    if ($from -match '\*') { continue } # no wildcards

    $outPath = Make-RedirectOutputPath $from $root
    $abs     = Resolve-RedirectTarget $to $base
    Write-RedirectStub $outPath $abs $code
    $count++
  }
  return $count
}

# --- 404 helpers (absolute CSS + home link) ---
function Inject-404Fix([string]$html, [string]$absBase) {
  if ([string]::IsNullOrWhiteSpace($absBase)) { return $html }
  $absBase = Normalize-BaseUrlLocal $absBase
  $snip = @"
<script>(function(){var BASE='$absBase';
function isAbs(u){return /^[a-z]+:\/\//i.test(u);}
function abs(u){if(!u)return u;if(isAbs(u))return u;if(u.charAt(0)=='/')return BASE.replace(/\/$/,'')+u;return BASE+u.replace(/^\.\//,'');}
function fix(){
  try{
    var links=document.querySelectorAll('link[rel="stylesheet"][href]');
    for(var i=0;i<links.length;i++){
      var href=links[i].getAttribute('href')||'';
      if(!isAbs(href)){ links[i].setAttribute('href', abs(href)); }
    }
  }catch(e){}
  try{
    var sels=['a[data-asd-home]','a[href="index.html"]','a[href="/"]','a[href="/index.html"]'];
    for(var s=0;s<sels.length;s++){
      var list=document.querySelectorAll(sels[s]);
      for(var j=0;j<list.length;j++){ list[j].setAttribute('href', BASE); }
    }
  }catch(e){}
}
if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',fix);}else{fix();}
})();</script>
"@
  if ($html -match '(?is)</body>') {
    return [regex]::Replace($html, '(?is)</body>', ($snip + "`r`n</body>"), 1)
  } elseif ($html -match '(?is)</head>') {
    return [regex]::Replace($html, '(?is)</head>', ($snip + "`r`n</head>"), 1)
  } else {
    return $html + "`r`n" + $snip
  }
}

# --- Robots helpers (SEO-safe) ---
function Upsert-RobotsMeta([string]$html, [string]$value) {
  if ([string]::IsNullOrWhiteSpace($html)) { return $html }
  $tag = '<meta name="robots" content="' + $value + '">'
  $pattern = '(?is)<meta\s+name\s*=\s*(?:"|'')robots(?:"|'')[^>]*>'
  if ($html -match $pattern) {
    return [regex]::Replace($html, $pattern, $tag, 1)
  }
  if ($html -match '(?is)</head>') {
    return [regex]::Replace($html, '(?is)</head>', ('  ' + $tag + "`r`n</head>"), 1)
  }
  return ($tag + "`r`n" + $html)
}

function Ensure-RobotsIndexMeta([string]$html) {
  if ([string]::IsNullOrWhiteSpace($html)) { return $html }
  if ($html -match '(?is)<meta\s+name\s*=\s*(?:"|'')robots(?:"|'')') { return $html }
  $tag = '<meta name="robots" content="index,follow">'
  if ($html -match '(?is)</head>') {
    return [regex]::Replace($html, '(?is)</head>', ('  ' + $tag + "`r`n</head>"), 1)
  }
  return ($tag + "`r`n" + $html)
}

# --- NEW: Trim content block; collapse extra blank lines around <main> ---
function Trim-OuterWhitespace([string]$s) {
  if ($null -eq $s) { return '' }
  $s = [regex]::Replace($s, '^\s+', '')
  $s = [regex]::Replace($s, '\s+$', '')
  return $s
}

# If markers exist, trim the whitespace just INSIDE the markers.
# Ensures exactly one CRLF padding after START and before END.
function Normalize-ContentForLayout([string]$s) {
  if ($null -eq $s) { return '' }
  $pat = '(?is)(<!--\s*ASD:(?:CONTENT|BODY)_START\s*-->)(.*?)(<!--\s*ASD:(?:CONTENT|BODY)_END\s*-->)'
  if ([regex]::IsMatch($s, $pat)) {
    return [regex]::Replace($s, $pat, {
      param($m)
      $inner = Trim-OuterWhitespace $m.Groups[2].Value
      return $m.Groups[1].Value + "`r`n" + $inner + "`r`n" + $m.Groups[3].Value
    }, 1)
  }
  return Trim-OuterWhitespace $s
}

# Collapse duplicate blank lines immediately before <main> and after </main>
function Normalize-MainWhitespace([string]$html) {
  if ([string]::IsNullOrWhiteSpace($html)) { return $html }
  # Before <main>
  $html = [regex]::Replace($html, '(?is)\r?\n\s*\r?\n\s*(?=<main\b)', "`r`n")
  # After </main>
  $html = [regex]::Replace($html, '(?is)(</main>)\s*(\r?\n\s*){2,}', '$1' + "`r`n")
  return $html
}

# --- NEW: Build "Recent Posts" HTML for homepage ---
function Build-RecentPostsHtml([string]$blogDir, [int]$max = 5) {
  if (-not (Test-Path $blogDir)) { return '' }
  $entries = @()

  Get-ChildItem -Path $blogDir -Filter *.html -File |
    Where-Object { $_.Name -ne 'index.html' -and $_.Name -notmatch '^page-\d+\.html$' } |
    ForEach-Object {
      $raw = Get-Content $_.FullName -Raw
      if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') { return }

      $mTitle = [regex]::Match($raw, '(?is)<title>(.*?)</title>')
      if ($mTitle.Success) {
        $title = $mTitle.Groups[1].Value
      } else {
        $mH1 = [regex]::Match($raw, '(?is)<h1[^>]*>(.*?)</h1>')
        $title = if ($mH1.Success) { $mH1.Groups[1].Value } else { $_.BaseName }
      }
      $title = Normalize-DashesToPipe $title

      $metaDate = Get-MetaDateFromHtml $raw
      if ($metaDate) { $dateDisplay = $metaDate; $sortKey = TryParse-Date $metaDate }
      else           { $dateDisplay = $_.CreationTime.ToString('yyyy-MM-dd'); $sortKey = $_.CreationTime }

      $entries += [pscustomobject]@{
        Title = $title
        Href  = ('blog/{0}' -f $_.Name)  # from site root index.html
        Date  = $dateDisplay
        Sort  = $sortKey
      }
    }

  if ($entries.Count -eq 0) { return '<p class="muted">No posts yet.</p>' }

  $items = New-Object System.Collections.Generic.List[string]
  foreach ($e in ($entries | Sort-Object Sort -Descending | Select-Object -First $max)) {
    $items.Add( ('<li><a href="{0}">{1}</a><small> | {2}</small></li>' -f $e.Href, $e.Title, $e.Date) )
  }
  $listHtml = [string]::Join([Environment]::NewLine, $items)
  return "<ul class=""posts"">`r`n$listHtml`r`n</ul>"
}

function Inject-RecentPosts-IntoContent([string]$content, [string]$blogDir, [int]$max = 5) {
  if ([string]::IsNullOrWhiteSpace($content)) { return $content }
  $pat = '(?is)<!--\s*ASD:RECENT_POSTS_START\s*-->.*?<!--\s*ASD:RECENT_POSTS_END\s*-->'
  if (-not [regex]::IsMatch($content, $pat)) { return $content }

  $recent = Build-RecentPostsHtml -blogDir $blogDir -max $max
  $replacement = @"
<!-- ASD:RECENT_POSTS_START -->
$recent
<!-- ASD:RECENT_POSTS_END -->
"@
  return [regex]::Replace($content, $pat, $replacement, 1)
}

$paths = Get-ASDPaths
$cfg   = Get-ASDConfig

$RootDir    = $paths.Root
$LayoutPath = $paths.Layout
$BlogDir    = $paths.Blog

$Brand = $cfg.SiteName
$Money = $cfg.StoreUrl
$Desc  = $cfg.Description
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

  $entries = New-Object System.Collections.ArrayList

  Get-ChildItem -Path $BlogDir -Filter *.html -File |
    Where-Object { $_.Name -ne "index.html" } |
    ForEach-Object {
      $html  = Get-Content $_.FullName -Raw

      # Skip redirect stubs
      if ($html -match '(?is)<!--\s*ASD:REDIRECT\b') { return }

      # Title
      $mTitle = [regex]::Match($html, '(?is)<title>(.*?)</title>')
      if ($mTitle.Success) {
        $title = $mTitle.Groups[1].Value
      } else {
        $mH1 = [regex]::Match($html, '(?is)<h1[^>]*>(.*?)</h1>')
        $title = if ($mH1.Success) { $mH1.Groups[1].Value } else { $_.BaseName }
      }
      $title = Normalize-DashesToPipe $title

      # Date
      $metaDate = Get-MetaDateFromHtml $html
      if ($metaDate) { $dateDisplay = $metaDate; $sortKey = TryParse-Date $metaDate }
      else           { $dateDisplay = $_.CreationTime.ToString('yyyy-MM-dd'); $sortKey = $_.CreationTime }

      $null = $entries.Add([pscustomobject]@{
        Title     = $title
        Href      = $_.Name
        DateText  = $dateDisplay
        SortKey   = $sortKey
      })
    }

  $posts = New-Object System.Collections.Generic.List[string]
  foreach ($e in ($entries | Sort-Object SortKey -Descending)) {
    $posts.Add( ('<li><a href="./{0}">{1}</a><small> | {2}</small></li>' -f $e.Href, $e.Title, $e.DateText) )
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
    # Preserve timestamps
    $it = Get-Item $_.FullName
    $origCreateUtc = $it.CreationTimeUtc
    $origWriteUtc  = $it.LastWriteTimeUtc

    $raw = Get-Content $_.FullName -Raw

    # Skip redirect stubs
    if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') {
      Write-Host ("[ASD] Skipped wrapping redirect stub: {0}" -f $_.FullName.Substring($RootDir.Length+1))
      return
    }

    # Extract and normalize just the content block
    $content = Extract-Content $raw
    $content = Normalize-ContentForLayout $content

    # SPECIAL: Inject recent posts into homepage marker region
    $isHome = ([System.IO.Path]::GetFileName($_.FullName)).ToLower() -eq 'index.html' -and `
              ([System.IO.Path]::GetDirectoryName($_.FullName)).TrimEnd('\') -eq $RootDir.TrimEnd('\')
    if ($isHome) {
      $content = Inject-RecentPosts-IntoContent -content $content -blogDir $BlogDir -max 5
    }

    # Title: prefer first <h1>, else filename
    $tm = [regex]::Match($content, '(?is)<h1[^>]*>(.*?)</h1>')
    $pageTitle = if ($tm.Success) { $tm.Groups[1].Value } else { $_.BaseName }

    # Compute prefix depth
    $prefix = Get-RelPrefix -RootDir $RootDir -FilePath $_.FullName

    # Build final page
    $final = $Layout
    $final = $final.Replace('{{CONTENT}}', $content)
    $final = $final.Replace('{{TITLE}}', $pageTitle)
    $final = $final.Replace('{{BRAND}}', $Brand)
    $final = $final.Replace('{{DESCRIPTION}}', $Desc)
    $final = $final.Replace('{{MONEY}}', $Money)
    $final = $final.Replace('{{YEAR}}', "$Year")
    $final = $final.Replace('{{PREFIX}}', $prefix)

    # Fix links & normalize dashes
    $final = Rewrite-RootLinks $final $prefix
    $final = Normalize-DashesToPipe $final

    # NEW: collapse extra blank lines around <main>
    $final = Normalize-MainWhitespace $final

    # SEO robots:
    $is404 = ([System.IO.Path]::GetFileName($_.FullName)).ToLower() -eq '404.html'
    if ($is404) {
      # 404: enforce noindex,follow + fix CSS/Home links
      $final = Upsert-RobotsMeta $final 'noindex,follow'
      $final = Inject-404Fix $final $Base
    } else {
      # All other pages: ensure index,follow if missing
      $final = Ensure-RobotsIndexMeta $final
    }

    Set-Content -Encoding UTF8 $_.FullName $final

    # Restore timestamps
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
