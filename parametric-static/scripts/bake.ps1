<# ============================================
   Amaterasu Static Deploy (ASD) - bake.ps1
   - Uses config.json as the single source of truth
   - Generates instant redirect stubs from redirects.json
   - Wraps HTML with layout.html and {{PREFIX}} (except redirect stubs)
   - Rewrites root-absolute links -> prefix-relative
   - Normalizes dashes to "|"
   - Rebuilds /blog/ index (basic) while skipping redirect stubs
   - Generates sitemap.xml and preserves robots.txt + appends one Sitemap line
   - Generates RSS feed.xml (well-formed, absolute links)
   - Preserves file timestamps so baking doesn't change dates
   - Trims content block and collapses extra blank lines around <main>
   - Homepage: inject recent posts
   - POSTS: byline + reading time, TOC, heading anchors, breadcrumbs,
            back-to-blog, prev/next, related, share links, lazy images,
            external-link hygiene, responsive embeds, per-post description & og:image,
            optional series banner, Article JSON-LD, copy button for code blocks
   - Idempotent injections via ASD markers to prevent duplicates
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

function Get-Meta([string]$html, [string]$nameOrProp, [switch]$IsProperty) {
  if ($IsProperty) {
    $m = [regex]::Match($html, '(?is)<meta\s+property\s*=\s*(?:"|'')' + [regex]::Escape($nameOrProp) + '(?:"|'')\s+content\s*=\s*(?:"|'')([^"''<>]+)(?:"|'')')
  } else {
    $m = [regex]::Match($html, '(?is)<meta\s+name\s*=\s*(?:"|'')' + [regex]::Escape($nameOrProp) + '(?:"|'')\s+content\s*=\s*(?:"|'')([^"''<>]+)(?:"|'')')
  }
  if ($m.Success) { return $m.Groups[1].Value.Trim() } else { return $null }
}

function Get-MetaDateFromHtml([string]$html) {
  $a = Get-Meta $html 'date'
  if ($a) {
    $dt = TryParse-Date $a
    if ($dt) { return $dt.ToString('yyyy-MM-dd') }
  }
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

# --- BaseUrl normalization ---
function Normalize-BaseUrlLocal([string]$b) {
  if ([string]::IsNullOrWhiteSpace($b)) { return "/" }
  $b = $b.Trim()
  $b = $b -replace '^/+(?=https?:)', ''      # drop accidental leading slash before scheme
  $b = $b -replace '^((?:https?):)/{1,}', '$1//'
  if ($b -match '^(https?://)(.+)$') {
    $scheme = $matches[1]; $rest = $matches[2]
    $rest = $rest.TrimStart('/')             # avoid https:///host
    $b = $scheme + $rest
    if (-not $b.EndsWith('/')) { $b += '/' }
    return $b
  } else {
    return '/' + $b.Trim('/') + '/'
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
  $s = $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'","&apos;")
  return $s
}

function JsString([string]$s) {
  if ($null -eq $s) { return '' }
  return $s.Replace('\','\\').Replace("'", "\'")
}

function UrlEncode([string]$s) {
  if ($null -eq $s) { return '' }
  return [System.Uri]::EscapeDataString($s)
}

function Write-RedirectStub([string]$outPath, [string]$absUrl, [int]$code) {
  $href = HtmlEscape $absUrl
  $jsu  = JsString $absUrl
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

# --- Content whitespace normalization ---
function Trim-OuterWhitespace([string]$s) {
  if ($null -eq $s) { return '' }
  $s = [regex]::Replace($s, '^\s+', '')
  $s = [regex]::Replace($s, '\s+$', '')
  return $s
}

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

function Normalize-MainWhitespace([string]$html) {
  if ([string]::IsNullOrWhiteSpace($html)) { return $html }
  $html = [regex]::Replace($html, '(?is)\r?\n\s*\r?\n\s*(?=<main\b)', "`r`n")            # before <main>
  $html = [regex]::Replace($html, '(?is)(</main>)\s*(\r?\n\s*){2,}', '$1' + "`r`n")      # after </main>
  return $html
}

# --- Home: Build recent posts ---
function Build-RecentPostsHtml([string]$blogDir, [int]$max = 5) {
  if (-not (Test-Path $blogDir)) { return '' }
  $entries = @()
  Get-ChildItem -Path $blogDir -Filter *.html -File |
    Where-Object { $_.Name -ne 'index.html' -and $_.Name -notmatch '^page-\d+\.html$' } |
    ForEach-Object {
      $raw = Get-Content $_.FullName -Raw
      if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') { return }
      $mTitle = [regex]::Match($raw, '(?is)<title>(.*?)</title>')
      if ($mTitle.Success) { $title = $mTitle.Groups[1].Value } else {
        $mH1 = [regex]::Match($raw, '(?is)<h1[^>]*>(.*?)</h1>'); $title = if ($mH1.Success){$mH1.Groups[1].Value}else{$_.BaseName}
      }
      $title = Normalize-DashesToPipe $title
      $metaDate = Get-MetaDateFromHtml $raw
      if ($metaDate) { $dateDisplay = $metaDate; $sortKey = TryParse-Date $metaDate }
      else           { $dateDisplay = $_.CreationTime.ToString('yyyy-MM-dd'); $sortKey = $_.CreationTime }
      $entries += [pscustomobject]@{ Title = $title; Href = ('blog/{0}' -f $_.Name); Date = $dateDisplay; Sort = $sortKey }
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

# --- Post helpers ---
function Strip-Html([string]$s) {
  if ($null -eq $s) { return '' }
  $s = [regex]::Replace($s, '(?is)<script.*?</script>', '')
  $s = [regex]::Replace($s, '(?is)<style.*?</style>', '')
  $s = [regex]::Replace($s, '(?is)<[^>]+>', ' ')
  $s = [regex]::Replace($s, '\s+', ' ')
  return $s.Trim()
}

function Compute-ReadingTimeMinutes([string]$html) {
  $txt = Strip-Html $html
  if ([string]::IsNullOrWhiteSpace($txt)) { return 1 }
  $words = ([regex]::Matches($txt, '\b\w+\b')).Count
  $mins  = [math]::Ceiling($words / 200.0)
  if ($mins -lt 1) { $mins = 1 }
  return [int]$mins
}

function Build-PostBreadcrumbs([string]$title) {
  $titleEsc = HtmlEscape $title
  return '<nav class="breadcrumbs"><a href="/index.html">Home</a> / <a href="/blog/">Blog</a> / <span>' + $titleEsc + '</span></nav>'
}

# Add IDs + small anchor for h2/h3; collect TOC items
function Add-HeadingAnchors([string]$html, [ref]$tocItems) {
  $ids = @{}
  $toc = New-Object System.Collections.Generic.List[object]
  $pattern = '(?is)<h([23])(\s[^>]*)?>(.*?)</h\1>'
  $evaluator = {
    param($m)
    $lvl  = $m.Groups[1].Value
    $attr = $m.Groups[2].Value
    $inner= $m.Groups[3].Value
    $id   = $null

    $idMatch = [regex]::Match($attr, '(?i)\sid\s*=\s*["'']([^"'']+)["'']')
    if ($idMatch.Success) { $id = $idMatch.Groups[1].Value }
    if (-not $id) {
      $textOnly = Strip-Html $inner
      $id = ($textOnly.ToLower() -replace '[^a-z0-9]+','-').Trim('-')
      if ([string]::IsNullOrWhiteSpace($id)) { $id = 'section-' + [guid]::NewGuid().ToString('N').Substring(0,8) }
      $base = $id; $n = 1
      while ($ids.ContainsKey($id)) { $id = $base + '-' + $n; $n++ }
      $attr = ($attr + ' id="' + $id + '"')
    }
    $ids[$id] = $true
    $toc.Add([pscustomobject]@{ Level=[int]$lvl; Id=$id; Text=(Strip-Html $inner) }) | Out-Null
    return ('<h{0}{1}>{2}<a class="h-anchor" href="#{3}" aria-label="Link to section">#</a></h{0}>' -f $lvl, $attr, $inner, $id)
  }
  $out = [regex]::Replace($html, $pattern, $evaluator)
  $tocItems.Value = $toc
  return $out
}

function Build-TocHtml($tocItems) {
  if ($null -eq $tocItems -or $tocItems.Count -eq 0) { return '' }
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('<nav class="toc"><div class="toc-title">On this page</div><ul>')
  foreach ($it in $tocItems) {
    $cls = if ($it.Level -eq 3) { ' class="toc-sub"' } else { '' }
    [void]$sb.AppendLine( ('  <li{0}><a href="#{1}">{2}</a></li>' -f $cls, $it.Id, (HtmlEscape $it.Text)) )
  }
  [void]$sb.AppendLine('</ul></nav>')
  return $sb.ToString()
}

function Insert-AfterFirstH1([string]$content, [string]$insertHtml) {
  if ([string]::IsNullOrWhiteSpace($insertHtml)) { return $content }
  return [regex]::Replace($content, '(?is)(</h1>)', ('$1' + "`r`n" + $insertHtml), 1)
}

# --- NEW: cleanup old duplicates & idempotent upserts ---
function Remove-OldPostExtras([string]$content) {
  if ([string]::IsNullOrWhiteSpace($content)) { return $content }
  # Strip any previous unmarked injections (from earlier bakes)
  $content = [regex]::Replace($content, '(?is)\s*<nav\s+class="breadcrumbs".*?</nav>\s*', '')
  $content = [regex]::Replace($content, '(?is)\s*<div\s+class="byline".*?</div>\s*', '')
  $content = [regex]::Replace($content, '(?is)\s*<div\s+class="series-banner".*?</div>\s*', '')
  $content = [regex]::Replace($content, '(?is)\s*<nav\s+class="toc".*?</nav>\s*', '')
  $content = [regex]::Replace($content, '(?is)\s*<hr>\s*(?=<div\s+class="share-row")', '')
  $content = [regex]::Replace($content, '(?is)\s*<div\s+class="share-row".*?</div>\s*', '')
  $content = [regex]::Replace($content, '(?is)\s*<nav\s+class="post-nav".*?</nav>\s*', '')
  $content = [regex]::Replace($content, '(?is)\s*<section\s+class="related".*?</section>\s*', '')
  $content = [regex]::Replace($content, '(?is)\s*<p\s+class="back-blog".*?</p>\s*', '')
  return $content
}

function Upsert-Block([string]$content, [string]$startMarker, [string]$endMarker, [string]$html, [switch]$AppendIfMissing, [switch]$AfterH1) {
  $wrapped = $startMarker + "`r`n" + $html + "`r`n" + $endMarker
  $pat = '(?is)' + [regex]::Escape($startMarker) + '.*?' + [regex]::Escape($endMarker)
  if ([regex]::IsMatch($content, $pat)) {
    return [regex]::Replace($content, $pat, $wrapped, 1)
  }
  if ($AfterH1) { return Insert-AfterFirstH1 $content $wrapped }
  if ($AppendIfMissing) { return ($content + "`r`n" + $wrapped) }
  return $content
}

function Lazyify-Images([string]$html) { return [regex]::Replace($html, '(?i)<img\b(?![^>]*\bloading=)', '<img loading="lazy" ') }

function Wrap-Embeds([string]$html) {
  $pattern = '(?is)(<iframe\b[^>]*\bsrc\s*=\s*["''](?:https?:)?//(?:www\.)?(?:youtube\.com|youtu\.be|player\.vimeo\.com)[^"''<>]*["''][^>]*></iframe>)'
  $e = { param($m) return '<div class="video">' + $m.Groups[1].Value + '</div>' }
  return [regex]::Replace($html, $pattern, $e)
}

# FIXED: use $baseHost (not $Host)
function External-Link-Hygiene([string]$html, [string]$base) {
  $baseHost = $null
  try { $u = [Uri]$base; $baseHost = $u.Host.ToLower() } catch {}
  $pattern = '(?is)<a\b([^>]*?)\shref\s*=\s*["''](https?://[^"''<>]+)["'']([^>]*)>'
  $e = {
    param($m)
    $pre = $m.Groups[1].Value
    $url = $m.Groups[2].Value
    $post= $m.Groups[3].Value
    $target = if ($m.Value -match '(?i)\btarget\s*=') { '' } else { ' target="_blank"' }
    $rel    = if ($m.Value -match '(?i)\brel\s*=')    { '' } else { ' rel="noopener"' }
    try {
      $uh = ([Uri]$url).Host.ToLower()
      if ($baseHost -and $uh -eq $baseHost) { $target = ''; $rel = '' }
    } catch { }
    return '<a' + $pre + ' href="' + $url + '"' + $target + $rel + $post + '>'
  }
  return [regex]::Replace($html, $pattern, $e)
}

function Build-ShareRow([string]$absUrl, [string]$title) {
  $u = UrlEncode $absUrl
  $t = UrlEncode $title
  $x = 'https://twitter.com/intent/tweet?url=' + $u + '&text=' + $t
  $li= 'https://www.linkedin.com/sharing/share-offsite/?url=' + $u
  $fb= 'https://www.facebook.com/sharer/sharer.php?u=' + $u
  return '<div class="share-row">Share: <a href="' + $x + '">X/Twitter</a> · <a href="' + $li + '">LinkedIn</a> · <a href="' + $fb + '">Facebook</a></div>'
}

function Apply-HeadOverrides([string]$html, [string]$desc, [string]$ogImageAbs) {
  $out = $html
  if ($desc) {
    $out = [regex]::Replace($out, '(?is)<meta\s+name\s*=\s*(?:"|'')description(?:"|'')\s+content\s*=\s*(?:"|'')[^"''<>]*(?:"|'')\s*/?>', ('<meta name="description" content="' + (HtmlEscape $desc) + '">'), 1)
    $out = [regex]::Replace($out, '(?is)<meta\s+property\s*=\s*(?:"|'')og:description(?:"|'')\s+content\s*=\s*(?:"|'')[^"''<>]*(?:"|'')\s*/?>', ('<meta property="og:description" content="' + (HtmlEscape $desc) + '">'), 1)
  }
  if ($ogImageAbs) {
    $out = [regex]::Replace($out, '(?is)<meta\s+property\s*=\s*(?:"|'')og:image(?:"|'')\s+content\s*=\s*(?:"|'')[^"''<>]*(?:"|'')\s*/?>', ('<meta property="og:image" content="' + (HtmlEscape $ogImageAbs) + '">'), 1)
  }
  return $out
}

function Build-JsonLd([string]$headline, [string]$author, [string]$datePub, [string]$dateMod, [string]$absUrl, [string]$imgAbs) {
  $headline = ($headline -replace '"','\"')
  $author   = ($author   -replace '"','\"')
  $imgJson  = if ($imgAbs) { '"image": ["' + $imgAbs + '"],' } else { '' }
  $json = @"
<!-- ASD:JSONLD_START -->
<script type="application/ld+json">{
  "@context": "https://schema.org",
  "@type": "Article",
  "headline": "$headline",
  $imgJson
  "datePublished": "$datePub",
  "dateModified": "$dateMod",
  "author": { "@type": "Person", "name": "$author" },
  "mainEntityOfPage": { "@type": "WebPage", "@id": "$absUrl" }
}</script>
<!-- ASD:JSONLD_END -->
"@
  return $json
}

function Strip-JsonLdMarkers([string]$html) { return [regex]::Replace($html, '(?is)<!--\s*ASD:JSONLD_START\s*-->.*?<!--\s*ASD:JSONLD_END\s*-->', '', 1) }

function Inject-IntoHead([string]$html, [string]$snippet) {
  if ([string]::IsNullOrWhiteSpace($snippet)) { return $html }
  if ($html -match '(?is)</head>') { return [regex]::Replace($html, '(?is)</head>', ($snippet + "`r`n</head>"), 1) }
  return $html + "`r`n" + $snippet
}

function Inject-BottomScript([string]$html, [string]$snippet, [string]$markerName) {
  if ([string]::IsNullOrWhiteSpace($snippet)) { return $html }
  $start = '<!-- ASD:' + $markerName + '_START -->'
  $end   = '<!-- ASD:' + $markerName + '_END -->'
  $wrapped = $start + "`r`n" + $snippet + "`r`n" + $end
  $pat = '(?is)' + [regex]::Escape($start) + '.*?' + [regex]::Escape($end)
  if ($html -match $pat) { return [regex]::Replace($html, $pat, $wrapped, 1) }
  if ($html -match '(?is)</body>') { return [regex]::Replace($html, '(?is)</body>', ($wrapped + "`r`n</body>"), 1) }
  return $html + "`r`n" + $wrapped
}

function Collect-AllPosts($blogDir) {
  $list = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path $blogDir)) { return $list }
  Get-ChildItem -Path $blogDir -Filter *.html -File |
    Where-Object { $_.Name -ne "index.html" -and $_.Name -notmatch '^page-\d+\.html$' } |
    ForEach-Object {
      $raw = Get-Content $_.FullName -Raw
      if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') { return }
      $mTitle = [regex]::Match($raw, '(?is)<title>(.*?)</title>')
      if ($mTitle.Success) { $title = $mTitle.Groups[1].Value } else {
        $mH1 = [regex]::Match($raw, '(?is)<h1[^>]*>(.*?)</h1>'); $title = if ($mH1.Success){$mH1.Groups[1].Value}else{$_.BaseName}
      }
      $title = Normalize-DashesToPipe $title

      $author = (Get-Meta $raw 'author'); if (-not $author) { $author = 'Maestro' }
      $date   = Get-MetaDateFromHtml $raw
      $dateDt = if ($date) { TryParse-Date $date } else { $_.CreationTime }
      $date   = if ($date) { $date } else { $_.CreationTime.ToString('yyyy-MM-dd') }

      $desc   = Get-Meta $raw 'description'
      $tags   = Get-Meta $raw 'tags';   $tagsArr = @()
      if ($tags) { $tagsArr = @($tags.Split(',') | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ -ne '' }) }
      $series = Get-Meta $raw 'series'
      $ogimg  = Get-Meta $raw 'og:image' -IsProperty

      $list.Add([pscustomobject]@{
        Name=$_.Name; Title=$title; Author=$author; DateText=$date; Date=$dateDt;
        Desc=$desc; Tags=$tagsArr; Series=$series; OgImage=$ogimg
      }) | Out-Null
    }
  return $list
}

function Find-PrevNext($all, [string]$name) {
  $sorted = $all | Sort-Object Date -Descending
  $i = 0; for ($i=0; $i -lt $sorted.Count; $i++){ if ($sorted[$i].Name -eq $name){ break } }
  $prev = $null; $next = $null
  if ($i -lt $sorted.Count) {
    if ($i -gt 0) { $prev = $sorted[$i-1] }
    if ($i + 1 -lt $sorted.Count) { $next = $sorted[$i+1] }
  }
  return @($prev, $next)
}

function Find-Related($all, [string]$name, $tags, [int]$max=3) {
  $pool = $all | Where-Object { $_.Name -ne $name }
  $byTag = @()
  if ($tags -and $tags.Count -gt 0) {
    $byTag = $pool | Where-Object {
      ($_.Tags | ForEach-Object { $tags -contains $_ }) -contains $true
    }
  }
  if ($byTag.Count -eq 0) {
    return ($pool | Sort-Object Date -Descending | Select-Object -First $max)
  } else {
    return ($byTag | Sort-Object Date -Descending | Select-Object -First $max)
  }
}

# --- RSS helpers ---
function Rfc1123([datetime]$dt) {
  if ($null -eq $dt) { $dt = Get-Date }
  return $dt.ToUniversalTime().ToString('r')  # e.g., Mon, 25 Aug 2025 19:08:00 GMT
}

function Build-Rss([object[]]$posts, [string]$base, [string]$title, [string]$desc, [string]$outPath, [int]$maxItems = 20) {
  $base = Normalize-BaseUrlLocal $base
  $chTitle = HtmlEscape $title
  $chDesc  = HtmlEscape $desc
  $chLink  = $base  # already normalized (absolute or rooted)
  $chLinkEsc = HtmlEscape $chLink
  $selfHref = if ($base -match '^[a-z]+://') { (New-Object Uri((New-Object Uri($base)), 'feed.xml')).AbsoluteUri } else { ($base.TrimEnd('/') + '/feed.xml') }

  $lines = New-Object System.Collections.Generic.List[string]
  $lines.Add('<?xml version="1.0" encoding="UTF-8"?>') | Out-Null
  $lines.Add('<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">') | Out-Null
  $lines.Add('  <channel>') | Out-Null
  $lines.Add('    <title>' + $chTitle + '</title>') | Out-Null
  $lines.Add('    <link>' + $chLinkEsc + '</link>') | Out-Null
  $lines.Add('    <description>' + $chDesc + '</description>') | Out-Null
  $lines.Add('    <generator>ASD</generator>') | Out-Null
  $lines.Add('    <lastBuildDate>' + (Rfc1123 (Get-Date)) + '</lastBuildDate>') | Out-Null
  $lines.Add('    <atom:link href="' + (HtmlEscape $selfHref) + '" rel="self" type="application/rss+xml" />') | Out-Null

  $i = 0
  foreach ($p in ($posts | Sort-Object Date -Descending)) {
    if ($i -ge $maxItems) { break }
    $i++

    $itemTitle = HtmlEscape $p.Title
    $itemLink  = Collapse-DoubleSlashesPreserveSchemeLocal ($base.TrimEnd('/') + '/blog/' + $p.Name)
    $pub       = if ($p.Date -is [datetime]) { Rfc1123 $p.Date } else { Rfc1123 (TryParse-Date $p.DateText) }
    $guid      = $itemLink

    $lines.Add('    <item>') | Out-Null
    $lines.Add('      <title>' + $itemTitle + '</title>') | Out-Null
    $lines.Add('      <link>' + (HtmlEscape $itemLink) + '</link>') | Out-Null
    $lines.Add('      <guid isPermaLink="true">' + (HtmlEscape $guid) + '</guid>') | Out-Null
    $lines.Add('      <pubDate>' + $pub + '</pubDate>') | Out-Null
    if ($p.Desc) {
      $lines.Add('      <description>' + (HtmlEscape $p.Desc) + '</description>') | Out-Null
    }
    $lines.Add('    </item>') | Out-Null
  }

  $lines.Add('  </channel>') | Out-Null
  $lines.Add('</rss>') | Out-Null

  Set-Content -Encoding UTF8 $outPath ($lines -join "`r`n")
}

# --- Build / Bake ---
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

# Redirect stubs
$made = Generate-RedirectStubs -redirectsJson $paths.Redirects -root $RootDir -base $Base
if ($made -gt 0) { Write-Host "[ASD] Redirect stubs generated: $made" }

if (-not (Test-Path $LayoutPath)) { Write-Error "[ASD] layout.html not found at $LayoutPath"; exit 1 }
$Layout = Get-Content $LayoutPath -Raw

# Pre-collect posts
$AllPosts = Collect-AllPosts $BlogDir

# Blog index refresh
$BlogIndex = Join-Path $BlogDir "index.html"
if (Test-Path $BlogIndex) {
  $posts = New-Object System.Collections.Generic.List[string]
  foreach($e in ($AllPosts | Sort-Object Date -Descending)) {
    $posts.Add( ('<li><a href="./{0}">{1}</a><small> | {2}</small></li>' -f $e.Name, $e.Title, $e.DateText) )
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

# Wrap every HTML (except layout.html)
Get-ChildItem -Path $RootDir -Recurse -File |
  Where-Object { $_.Extension -eq ".html" -and $_.FullName -ne $LayoutPath } |
  ForEach-Object {
    $it = Get-Item $_.FullName
    $origCreateUtc = $it.CreationTimeUtc
    $origWriteUtc  = $it.LastWriteTimeUtc

    $raw = Get-Content $_.FullName -Raw

    if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') {
      Write-Host ("[ASD] Skipped wrapping redirect stub: {0}" -f $_.FullName.Substring($RootDir.Length+1))
      return
    }

    $content = Extract-Content $raw
    $content = Normalize-ContentForLayout $content

    # Homepage: inject recent posts
    $isHome = ([System.IO.Path]::GetFileName($_.FullName)).ToLower() -eq 'index.html' -and `
              ([System.IO.Path]::GetDirectoryName($_.FullName)).TrimEnd('\') -eq $RootDir.TrimEnd('\')
    if ($isHome) { $content = Inject-RecentPosts-IntoContent -content $content -blogDir $BlogDir -max 5 }

    # Detect top-level blog post file
    $isPost = ([System.IO.Path]::GetDirectoryName($_.FullName)).TrimEnd('\') -eq $BlogDir.TrimEnd('\') -and `
              ([System.IO.Path]::GetFileName($_.FullName)).ToLower() -notmatch '^index\.html$|^page-\d+\.html$'

    # Title (from content)
    $tm = [regex]::Match($content, '(?is)<h1[^>]*>(.*?)</h1>')
    $pageTitle = if ($tm.Success) { $tm.Groups[1].Value } else { $_.BaseName }
    $pageTitle = Normalize-DashesToPipe $pageTitle

    # ----- POST ENHANCEMENTS -----
    $postMeta = $null
    $hasCode  = $false
    if ($isPost) {
      $content = Remove-OldPostExtras $content  # one-time cleanup for old duplicates

      $thisName = $_.Name
      $postMeta = ($AllPosts | Where-Object { $_.Name -eq $thisName } | Select-Object -First 1)
      if ($null -eq $postMeta) {
        $postMeta = [pscustomobject]@{ Name=$thisName; Title=$pageTitle; Author='Maestro'; DateText=$_.CreationTime.ToString('yyyy-MM-dd'); Date=$_.CreationTime; Desc=$null; Tags=@(); Series=$null; OgImage=$null }
      }

      # Anchors + TOC
      $tocItems = $null
      $content  = Add-HeadingAnchors $content ([ref]$tocItems)
      $tocHtml  = Build-TocHtml $tocItems

      # Reading time
      $readMin = Compute-ReadingTimeMinutes $content

      # Breadcrumbs + Byline + TOC (idempotent insert after first H1)
      $crumbs = Build-PostBreadcrumbs $pageTitle
      $byline = ('<div class="byline"><span class="byline-item">{0}</span><span class="byline-dot">·</span><time datetime="{1}">{1}</time><span class="byline-dot">·</span><span class="byline-read">{2} min read</span></div>' -f (HtmlEscape $postMeta.Author), $postMeta.DateText, $readMin)
      $seriesHtml = if ($postMeta.Series) { '<div class="series-banner">Part of the <strong>' + (HtmlEscape $postMeta.Series) + '</strong> series.</div>' } else { '' }
      $topBlock = $crumbs + $byline + $seriesHtml + $tocHtml
      $content  = Upsert-Block -content $content -startMarker '<!-- ASD:POST_TOP_START -->' -endMarker '<!-- ASD:POST_TOP_END -->' -html $topBlock -AfterH1

      # Bottom: Prev/Next + Related + Back + Share (idempotent append)
      $pn = Find-PrevNext $AllPosts $thisName
      $prev = $pn[0]; $next = $pn[1]
      $prevHtml = if ($prev) { '<a class="prev" href="/blog/' + $prev.Name + '">← ' + (HtmlEscape $prev.Title) + '</a>' } else { '' }
      $nextHtml = if ($next) { '<a class="next" href="/blog/' + $next.Name + '">' + (HtmlEscape $next.Title) + ' →</a>' } else { '' }
      $postNav  = '<nav class="post-nav">' + $prevHtml + '<span></span>' + $nextHtml + '</nav>'

      $related = Find-Related $AllPosts $thisName $postMeta.Tags 3
      $relItems = New-Object System.Collections.Generic.List[string]
      foreach ($r in $related) { $relItems.Add('<li><a href="/blog/' + $r.Name + '">' + (HtmlEscape $r.Title) + '</a><small> | ' + $r.DateText + '</small></li>') }
      $relList = if ($relItems.Count -gt 0) { '<section class="related"><h2>Related posts</h2><ul class="posts">' + ([string]::Join('', $relItems)) + '</ul></section>' } else { '' }

      $back = '<p class="back-blog"><a href="/blog/">← Back to all posts</a></p>'

      $absPostUrl = Collapse-DoubleSlashesPreserveSchemeLocal ($Base.TrimEnd('/') + '/blog/' + $thisName)
      $share = Build-ShareRow $absPostUrl $pageTitle

      $bottomBlock = '<hr>' + $share + $postNav + $relList + $back
      $content     = Upsert-Block -content $content -startMarker '<!-- ASD:POST_BOTTOM_START -->' -endMarker '<!-- ASD:POST_BOTTOM_END -->' -html $bottomBlock -AppendIfMissing

      # Hygiene + embeds + lazy images
      $content = Lazyify-Images $content
      $content = Wrap-Embeds $content
      $content = External-Link-Hygiene $content $Base

      if ($content -match '(?is)<pre[^>]*>\s*<code') { $hasCode = $true }
    }

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

    # Link fixes & dash normalization
    $final = Rewrite-RootLinks $final $prefix
    $final = Normalize-DashesToPipe $final

    # Collapse blanks around <main>
    $final = Normalize-MainWhitespace $final

    # SEO robots + 404 fix
    $is404 = ([System.IO.Path]::GetFileName($_.FullName)).ToLower() -eq '404.html'
    if ($is404) {
      $final = Upsert-RobotsMeta $final 'noindex,follow'
      $final = Inject-404Fix $final $Base
    } else {
      $final = Ensure-RobotsIndexMeta $final
    }

    # Post head overrides & JSON-LD & copy JS
    if ($isPost -and $postMeta) {
      # Per-post description/og:image overrides
      $absImg = $null
      if ($postMeta.OgImage) {
        if     ($postMeta.OgImage -match '^[a-z]+://') { $absImg = $postMeta.OgImage }
        elseif ($postMeta.OgImage.StartsWith('/'))     { $absImg = Collapse-DoubleSlashesPreserveSchemeLocal ($Base.TrimEnd('/') + $postMeta.OgImage) }
        else                                           { $absImg = Collapse-DoubleSlashesPreserveSchemeLocal ($Base.TrimEnd('/') + '/' + $postMeta.OgImage) }
      }
      $final = Apply-HeadOverrides $final $postMeta.Desc $absImg

      # JSON-LD Article (idempotent)
      $absPostUrl = Collapse-DoubleSlashesPreserveSchemeLocal ($Base.TrimEnd('/') + '/blog/' + $postMeta.Name)
      $final = Strip-JsonLdMarkers $final
      $jsonld = Build-JsonLd $pageTitle $postMeta.Author $postMeta.DateText ((Get-Item $_.FullName).LastWriteTime.ToString('yyyy-MM-dd')) $absPostUrl $absImg
      $final = Inject-IntoHead $final $jsonld

      # Copy button JS (idempotent via marker)
      if ($hasCode) {
        $copyJs = @"
<script>(function(){try{
  var blocks=document.querySelectorAll('pre>code'); if(!blocks.length) return;
  for(var i=0;i<blocks.length;i++){
    var pre=blocks[i].parentNode;
    pre.style.position='relative';
    if(pre.querySelector('button.code-copy')) continue;
    var btn=document.createElement('button');
    btn.type='button'; btn.className='code-copy'; btn.textContent='Copy';
    btn.addEventListener('click', (function(c){return function(){
      try{ var t=c.innerText||c.textContent; navigator.clipboard.writeText(t).then(function(){btn.textContent='Copied!'; setTimeout(function(){btn.textContent='Copy';},1200);}); }catch(e){}
    };})(blocks[i]));
    pre.appendChild(btn);
  }
}catch(e){}})();</script>
"@
        $final = Inject-BottomScript -html $final -snippet $copyJs -markerName 'COPYJS'
      }
    }

    Set-Content -Encoding UTF8 $_.FullName $final
    Preserve-FileTimes $_.FullName $origCreateUtc $origWriteUtc

    Write-Host ("[ASD] Wrapped {0} (prefix='{1}')" -f $_.FullName.Substring($RootDir.Length+1), $prefix)
  }

# ---- Generate sitemap.xml ----
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

# ---- Generate RSS feed.xml (well-formed) ----
$feedPath = Join-Path $RootDir 'feed.xml'
Build-Rss -posts $AllPosts -base $Base -title $Brand -desc $Desc -outPath $feedPath -maxItems 20
Write-Host "[ASD] feed.xml generated ($([Math]::Min(20, ($AllPosts | Measure-Object).Count)) items)"

# robots.txt: preserve/create, then single canonical Sitemap line
$robotsPath = Join-Path $RootDir 'robots.txt'
$robots = if (Test-Path $robotsPath) { Get-Content $robotsPath -Raw } else {
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
$robots = [regex]::Replace($robots, '(?im)^\s*Sitemap:\s*.*\r?\n?', '')
if ($Base -match '^[a-z]+://') { $absMap = (New-Object Uri((New-Object Uri($Base)), 'sitemap.xml')).AbsoluteUri } else { $absMap = 'sitemap.xml' }
if ($robots -notmatch "\r?\n$") { $robots += "`r`n" }
$robots += "Sitemap: $absMap`r`n"
Set-Content -Encoding UTF8 $robotsPath $robots
Write-Host "[ASD] robots.txt: Sitemap -> $absMap"

Write-Host "[ASD] Done."
