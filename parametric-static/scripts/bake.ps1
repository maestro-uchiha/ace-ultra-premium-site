# parametric-static/scripts/bake.ps1
<# ============================================
   Amaterasu Static Deploy (ASD) - bake.ps1
   - Uses config.json as the single source of truth
   - Generates instant redirect stubs from redirects.json
   - Wraps HTML with layout.html and {{PREFIX}} (except redirect stubs)
   - Rewrites root-absolute links -> prefix-relative
   - Normalizes dashes to "|"
   - Rebuilds /blog/ index (stable dates; respects <meta name="date">)
   - Generates sitemap.xml, robots.txt (single Sitemap line)
   - Generates RSS (feed.xml) and Atom (atom.xml)
   - Preserves file timestamps so baking doesn't change dates
   - PowerShell 5.1-safe (no ternary, no expression-form if)
   ============================================ #>

#requires -Version 5.1

. "$PSScriptRoot\_lib.ps1"

function TryParse-Date([string]$v) {
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  [datetime]$out = [datetime]::MinValue
  $ok = [datetime]::TryParse($v, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeLocal, [ref]$out)
  if ($ok) { return $out } else { return $null }
}
function Rfc1123([datetime]$dt) {
  if ($null -eq $dt) { $dt = Get-Date }
  if ($dt.Kind -ne [System.DateTimeKind]::Utc) { $dt = $dt.ToUniversalTime() }
  return $dt.ToString("R", [Globalization.CultureInfo]::InvariantCulture)
}
function Get-MetaDateFromHtml([string]$html) {
  if ([string]::IsNullOrWhiteSpace($html)) { return $null }
  $m = [regex]::Match($html,'(?is)<meta\s+name\s*=\s*["'']date["'']\s+content\s*=\s*["'']([^"''<>]+)["'']')
  if ($m.Success) {
    $dt = TryParse-Date ($m.Groups[1].Value.Trim())
    if ($dt) { return $dt.ToString('yyyy-MM-dd') }
  }
  $t = [regex]::Match($html,'(?is)<time[^>]+datetime\s*=\s*["'']([^"''<>]+)["'']')
  if ($t.Success) {
    $dt = TryParse-Date ($t.Groups[1].Value.Trim())
    if ($dt) { return $dt.ToString('yyyy-MM-dd') }
  }
  return $null
}
function Preserve-FileTimes($path,[datetime]$origCreateUtc,[datetime]$origWriteUtc){
  try { (Get-Item $path).CreationTimeUtc  = $origCreateUtc } catch {}
  try { (Get-Item $path).LastWriteTimeUtc = $origWriteUtc }  catch {}
}
function Collapse-DoubleSlashesPreserveSchemeLocal([string]$url){
  if ([string]::IsNullOrWhiteSpace($url)) { return $url }
  $m = [regex]::Match($url,'^(https?://)(.*)$')
  if ($m.Success) {
    $scheme = $m.Groups[1].Value
    $rest   = ($m.Groups[2].Value -replace '/{2,}','/')
    return $scheme + $rest
  }
  return ($url -replace '/{2,}','/')
}
function Normalize-BaseUrlLocal([string]$b){
  if ([string]::IsNullOrWhiteSpace($b)) { return "/" }
  $x = $b.Trim()
  $x = $x -replace '^/+(?=https?:)',''
  $x = $x -replace '^((?:https?):)/{1,}','$1//'
  $m = [regex]::Match($x,'^(https?://)(.+)$')
  if ($m.Success) {
    $x = $m.Groups[1].Value + $m.Groups[2].Value.TrimStart('/')
    if (-not $x.EndsWith('/')) { $x += '/' }
    return $x
  } else {
    return '/' + $x.Trim('/') + '/'
  }
}
function Resolve-RedirectTarget([string]$to,[string]$base){
  if ([string]::IsNullOrWhiteSpace($to)) { return $base }
  $t = $to.Trim()
  if ($t -match '^[a-z]+://') { return Collapse-DoubleSlashesPreserveSchemeLocal($t) }
  if ($t.StartsWith('/')) { return Collapse-DoubleSlashesPreserveSchemeLocal(($base.TrimEnd('/') + $t)) }
  return Collapse-DoubleSlashesPreserveSchemeLocal(($base.TrimEnd('/') + '/' + $t))
}
function Make-RedirectOutputPath([string]$from,[string]$root){
  if ([string]::IsNullOrWhiteSpace($from)) { return $null }
  $rel = $from.Trim()
  if ($rel.StartsWith('/')) { $rel = $rel.TrimStart('/') }
  if (-not ($rel -match '\.html?$')) {
    if ($rel.EndsWith('/')) { $rel += 'index.html' } else { $rel += '/index.html' }
  }
  $out = Join-Path $root $rel
  $dir = Split-Path $out -Parent
  New-Item -ItemType Directory -Force -Path $dir | Out-Null
  return $out
}
function HtmlEscape([string]$s){
  if ($null -eq $s) { return '' }
  return $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;')
}
function JsString([string]$s){
  if ($null -eq $s) { return '' }
  return $s.Replace('\','\\').Replace("'", "\'")
}
function Write-RedirectStub([string]$outPath,[string]$absUrl,[int]$code){
  $href = HtmlEscape($absUrl)
  $jsu  = JsString($absUrl)
  $html = @"
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><title>Redirecting…</title>
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0;url=$href">
<script>location.replace('$jsu');</script>
</head><body>
<!-- ASD:REDIRECT to="$href" code="$code" -->
<p>If you are not redirected, <a href="$href">click here</a>.</p>
</body></html>
"@
  Set-Content -Encoding UTF8 $outPath $html
}
function Generate-RedirectStubs([string]$redirectsJson,[string]$root,[string]$base){
  if (-not (Test-Path $redirectsJson)) { return 0 }
  $items = @()
  try {
    $raw = Get-Content $redirectsJson -Raw
    if (-not [string]::IsNullOrWhiteSpace($raw)) { $items = $raw | ConvertFrom-Json }
  } catch { Write-Warning "[ASD] redirects.json is invalid; skipping."; return 0 }
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
    if ($from -match '\*') { continue }
    $outPath = Make-RedirectOutputPath $from $root
    $abs     = Resolve-RedirectTarget $to $base
    Write-RedirectStub $outPath $abs $code
    $count++
  }
  return $count
}
function AddOrReplaceMetaRobots([string]$html,[string]$value){
  if ([string]::IsNullOrWhiteSpace($html)) { return $html }
  $rx  = [regex]'(?is)<meta\s+name\s*=\s*["'']robots["''][^>]*>'
  $tag = '<meta name="robots" content="' + (HtmlEscape $value) + '">'
  if ($rx.IsMatch($html)) {
    return $rx.Replace($html,$tag,1)
  } else {
    $m = [regex]::Match($html,'(?is)<head[^>]*>')
    $nl = [Environment]::NewLine
    if ($m.Success) {
      $idx = $m.Index + $m.Length
      return $html.Substring(0,$idx) + $nl + $tag + $nl + $html.Substring($idx)
    }
    return $tag + $nl + $html
  }
}
function DetermineRobotsForFile([string]$fullPath,[string]$rawHtml){
  $name = [IO.Path]::GetFileName($fullPath)
  if ($name -ieq '404.html') { return 'noindex,nofollow' }
  return 'index,follow'
}

# --- Injectors & cleaners ---

function Remove-OldThemeArtifacts([string]$html) {
  if ([string]::IsNullOrWhiteSpace($html)) { return $html }
  $patterns = @(
    '(?is)<script[^>]+id\s*=\s*["'']asd-theme-handler["''][^>]*>.*?</script>',
    '(?is)<button[^>]+id\s*=\s*["'']asd-theme-toggle["''][^>]*>.*?</button>'
  )
  foreach($p in $patterns){ $html = [regex]::Replace($html,$p,'') }
  return $html
}
function Insert-AfterHeadOpen([string]$html,[string[]]$snips){
  if ([string]::IsNullOrWhiteSpace($html)) { return $html }
  $m = [regex]::Match($html,'(?is)<head[^>]*>')
  $nl = [Environment]::NewLine
  if ($m.Success) {
    $idx = $m.Index + $m.Length
    return $html.Substring(0,$idx) + $nl + ([string]::Join($nl,$snips)) + $nl + $html.Substring($idx)
  }
  return ([string]::Join($nl,$snips)) + $nl + $html
}
function Insert-BeforeBodyClose([string]$html,[string]$snippet){
  if ([string]::IsNullOrWhiteSpace($html)) { return $html }
  $m = [regex]::Match($html,'(?is)</body\s*>')
  $nl = [Environment]::NewLine
  if ($m.Success) {
    $idx = $m.Index
    return $html.Substring(0,$idx) + $nl + $snippet + $nl + $html.Substring($idx)
  }
  return $html + $nl + $snippet + $nl
}
function Ensure-HeadFeeds([string]$html,[string]$prefix,[string]$brand){
  $needRss  = -not ([regex]::IsMatch($html,'(?is)<link[^>]+type\s*=\s*["'']application/rss\+xml["''][^>]*>'))
  $needAtom = -not ([regex]::IsMatch($html,'(?is)<link[^>]+type\s*=\s*["'']application/atom\+xml["''][^>]*>'))
  $snips = @()
  if ($needRss)  { $snips += ('<link rel="alternate" type="application/rss+xml" title="' + (HtmlEscape $brand) + ' RSS" href="' + $prefix + 'feed.xml">') }
  if ($needAtom) { $snips += ('<link rel="alternate" type="application/atom+xml" title="' + (HtmlEscape $brand) + ' Atom" href="' + $prefix + 'atom.xml">') }
  if ($snips.Count -gt 0) { $html = Insert-AfterHeadOpen $html $snips }
  return $html
}
function Ensure-BodyThemeToggle([string]$html) {
  if ([regex]::IsMatch($html,'(?is)id\s*=\s*["'']asd-theme-handler["'']')) { return $html }
  $snippet = @'
<!-- ASD:THEME_TOGGLE -->
<button class="asd-theme-toggle" id="asd-theme-toggle" type="button" title="Toggle theme" aria-label="Toggle theme">🌙 / ☀</button>
<script id="asd-theme-handler">
(function(){
  var KEY='asd-theme';
  function setTheme(t){
    document.documentElement.setAttribute('data-theme', t);
    try{ localStorage.setItem(KEY, t); }catch(e){}
  }
  function initial(){
    try{
      var s=localStorage.getItem(KEY);
      if(s==='dark'||s==='light') return s;
    }catch(e){}
    return (window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches)?'dark':'light';
  }
  function ready(fn){ if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',fn);} else {fn();} }
  ready(function(){
    try{
      var btn=document.getElementById('asd-theme-toggle');
      if(btn){
        btn.addEventListener('click', function(){
          var cur=document.documentElement.getAttribute('data-theme')||'light';
          setTheme(cur==='dark'?'light':'dark');
        });
      }
      setTheme(document.documentElement.getAttribute('data-theme')||initial());
    }catch(e){}
  });
})();
</script>
'@
  return Insert-BeforeBodyClose $html $snippet
}

# ------ Feed builders (RSS + Atom) ------
function Build-PostList($BlogDir,$Base){
  $list = New-Object System.Collections.ArrayList
  $files = Get-ChildItem -Path $BlogDir -Filter *.html -File | Where-Object { $_.Name -ne 'index.html' -and $_.Name -notmatch '^page-\d+\.html$' }
  foreach($f in $files){
    $html = Get-Content $f.FullName -Raw
    if ($html -match '(?is)<!--\s*ASD:REDIRECT\b') { continue }

    # title
    $title = $null
    $mTitle = [regex]::Match($html,'(?is)<title>(.*?)</title>')
    if ($mTitle.Success) { $title = $mTitle.Groups[1].Value }
    else {
      $mH1 = [regex]::Match($html,'(?is)<h1[^>]*>(.*?)</h1>')
      if ($mH1.Success) { $title = $mH1.Groups[1].Value } else { $title = $f.BaseName }
    }
    $title = Normalize-DashesToPipe $title

    # date
    $metaDate = Get-MetaDateFromHtml $html
    $dateText = $null; $dateDt = $null
    if ($metaDate) { $dateText = $metaDate; $dateDt = TryParse-Date $metaDate }
    else { $dateDt = $f.CreationTime; $dateText = $f.CreationTime.ToString('yyyy-MM-dd') }

    # link
    $abs = $null
    if ($Base -match '^[a-z]+://') {
      $abs = (New-Object Uri((New-Object Uri($Base)), ('blog/' + $f.Name))).AbsoluteUri
    } else {
      $abs = ($Base.TrimEnd('/') + '/blog/' + $f.Name)
    }

    [void]$list.Add([pscustomobject]@{
      Name     = $f.Name
      Title    = $title
      Date     = $dateDt
      DateText = $dateText
      Link     = Collapse-DoubleSlashesPreserveSchemeLocal $abs
    })
  }
  return ($list | Sort-Object Date -Descending)
}
function Generate-RssFeed($posts,[string]$base,[string]$title,[string]$desc,[string]$outPath,[int]$maxItems=20){
  $lines = New-Object System.Collections.Generic.List[string]
  $chTitle = HtmlEscape $title
  $chDesc  = HtmlEscape $desc
  $chLink  = $base
  if ($base -match '^[a-z]+://') {
    $chLink = (New-Object Uri((New-Object Uri($base)), '/')).AbsoluteUri
  }
  $lines.Add('<?xml version="1.0" encoding="UTF-8"?>') | Out-Null
  $lines.Add('<rss version="2.0">') | Out-Null
  $lines.Add('  <channel>') | Out-Null
  $lines.Add('    <title>' + $chTitle + '</title>') | Out-Null
  $lines.Add('    <link>' + (HtmlEscape $chLink) + '</link>') | Out-Null
  $lines.Add('    <description>' + $chDesc + '</description>') | Out-Null
  $count = 0
  foreach ($p in $posts) {
    if ($count -ge $maxItems) { break }
    $lines.Add('    <item>') | Out-Null
    $lines.Add('      <title>' + (HtmlEscape $p.Title) + '</title>') | Out-Null
    $lines.Add('      <link>' + (HtmlEscape $p.Link) + '</link>') | Out-Null
    $pub = $null
    if ($p.Date -is [datetime]) { $pub = Rfc1123 $p.Date } else { $pub = Rfc1123 (TryParse-Date $p.DateText) }
    $lines.Add('      <pubDate>' + $pub + '</pubDate>') | Out-Null
    $lines.Add('    </item>') | Out-Null
    $count++
  }
  $lines.Add('  </channel>') | Out-Null
  $lines.Add('</rss>') | Out-Null
  Set-Content -Encoding UTF8 $outPath ($lines -join [Environment]::NewLine)
}
function Generate-AtomFeed($posts,[string]$base,[string]$title,[string]$desc,[string]$outPath,[int]$maxItems=20){
  $lines   = New-Object System.Collections.Generic.List[string]
  $feedId  = $base
  if ($base -notmatch '^[a-z]+://') {
    $feedId = 'tag:local,' + (Get-Date -Format 'yyyy-MM-dd') + ':' + $base
  }
  $selfHref = $base
  if ($base -match '^[a-z]+://') {
    $selfHref = (New-Object Uri((New-Object Uri($base)),'atom.xml')).AbsoluteUri
  } else {
    $selfHref = ($base.TrimEnd('/') + '/atom.xml')
  }
  $nowIso = (Get-Date).ToUniversalTime().ToString('s') + 'Z'

  $lines.Add('<?xml version="1.0" encoding="utf-8"?>') | Out-Null
  $lines.Add('<feed xmlns="http://www.w3.org/2005/Atom">') | Out-Null
  $lines.Add('  <title>' + (HtmlEscape $title) + '</title>') | Out-Null
  $lines.Add('  <id>' + (HtmlEscape $feedId) + '</id>') | Out-Null
  $lines.Add('  <updated>' + $nowIso + '</updated>') | Out-Null
  $lines.Add('  <link rel="self" href="' + (HtmlEscape $selfHref) + '"/>') | Out-Null

  $count = 0
  foreach ($p in $posts) {
    if ($count -ge $maxItems) { break }
    $lines.Add('  <entry>') | Out-Null
    $lines.Add('    <title>' + (HtmlEscape $p.Title) + '</title>') | Out-Null
    $lines.Add('    <link href="' + (HtmlEscape $p.Link) + '"/>') | Out-Null
    $lines.Add('    <id>' + (HtmlEscape $p.Link) + '</id>') | Out-Null
    $updDt = $null
    if ($p.Date -is [datetime]) { $updDt = $p.Date } else { $updDt = TryParse-Date $p.DateText }
    if ($null -eq $updDt) { $updDt = Get-Date }
    $lines.Add('    <updated>' + ($updDt.ToUniversalTime().ToString('s') + 'Z') + '</updated>') | Out-Null
    $lines.Add('  </entry>') | Out-Null
    $count++
  }
  $lines.Add('</feed>') | Out-Null
  Set-Content -Encoding UTF8 $outPath ($lines -join [Environment]::NewLine)
}

# ---------------- start ----------------
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

# Blog index (stable dates)
$BlogIndex = Join-Path $BlogDir "index.html"
if (Test-Path $BlogIndex) {
  $entries = New-Object System.Collections.ArrayList
  $files = Get-ChildItem -Path $BlogDir -Filter *.html -File | Where-Object { $_.Name -ne "index.html" -and $_.Name -notmatch '^page-\d+\.html$' }
  foreach ($f in $files) {
    $html = Get-Content $f.FullName -Raw
    if ($html -match '(?is)<!--\s*ASD:REDIRECT\b') { continue }

    $title = $null
    $mTitle = [regex]::Match($html,'(?is)<title>(.*?)</title>')
    if ($mTitle.Success) {
      $title = $mTitle.Groups[1].Value
    } else {
      $mH1 = [regex]::Match($html,'(?is)<h1[^>]*>(.*?)</h1>')
      if ($mH1.Success) { $title = $mH1.Groups[1].Value } else { $title = $f.BaseName }
    }
    $title = Normalize-DashesToPipe $title

    $metaDate = Get-MetaDateFromHtml $html
    $dateDisplay = $null
    $sortKey = $null
    if ($metaDate) { $dateDisplay = $metaDate; $sortKey = TryParse-Date $metaDate }
    else { $dateDisplay = $f.CreationTime.ToString('yyyy-MM-dd'); $sortKey = $f.CreationTime }

    [void]$entries.Add([pscustomobject]@{ Title=$title; Href=$f.Name; DateText=$dateDisplay; SortKey=$sortKey })
  }

  $posts = New-Object System.Collections.Generic.List[string]
  foreach ($e in ($entries | Sort-Object SortKey -Descending)) {
    [void]$posts.Add('<li><a href="./' + $e.Href + '">' + $e.Title + '</a><small> | ' + $e.DateText + '</small></li>')
  }

  $bi = Get-Content $BlogIndex -Raw
  $joined = [string]::Join([Environment]::NewLine,$posts)
  $pattern = '(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->'
  $replacement = "<!-- POSTS_START -->`n$joined`n<!-- POSTS_END -->"
  $bi = [regex]::Replace($bi,$pattern,$replacement)
  Set-Content -Encoding UTF8 $BlogIndex $bi
  Write-Host "[ASD] Blog index updated"
}

# Wrap + inject per page
Get-ChildItem -Path $RootDir -Recurse -File | Where-Object { $_.Extension -eq ".html" -and $_.FullName -ne $LayoutPath } | ForEach-Object {

  # Preserve original timestamps
  $it = Get-Item $_.FullName
  $origCreateUtc = $it.CreationTimeUtc
  $origWriteUtc  = $it.LastWriteTimeUtc

  $raw = Get-Content $_.FullName -Raw
  if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') {
    Write-Host ("[ASD] Skipped wrapping redirect stub: {0}" -f $_.FullName.Substring($RootDir.Length+1))
    return
  }

  $content = Extract-Content $raw

  $tm = [regex]::Match($content,'(?is)<h1[^>]*>(.*?)</h1>')
  $pageTitle = $null
  if ($tm.Success) { $pageTitle = $tm.Groups[1].Value } else { $pageTitle = $_.BaseName }

  $prefix = Get-RelPrefix -RootDir $RootDir -FilePath $_.FullName

  $final = $Layout
  $final = $final.Replace('{{CONTENT}}',$content)
  $final = $final.Replace('{{TITLE}}',$pageTitle)
  $final = $final.Replace('{{BRAND}}',$Brand)
  $final = $final.Replace('{{DESCRIPTION}}',$Desc)
  $final = $final.Replace('{{MONEY}}',$Money)
  $final = $final.Replace('{{YEAR}}',"$Year")
  $final = $final.Replace('{{PREFIX}}',$prefix)

  $robotsVal = DetermineRobotsForFile $_.FullName $raw
  $final = AddOrReplaceMetaRobots $final $robotsVal

  # Clean old theme bits → inject feeds + theme toggle
  $final = Remove-OldThemeArtifacts $final
  $final = Ensure-HeadFeeds $final $prefix $Brand
  $final = Ensure-BodyThemeToggle $final

  # Rewrite root links + normalize dashes
  $final = Rewrite-RootLinks $final $prefix
  $final = Normalize-DashesToPipe $final

  Set-Content -Encoding UTF8 $_.FullName $final
  Preserve-FileTimes $_.FullName $origCreateUtc $origWriteUtc

  Write-Host ("[ASD] Wrapped {0} (prefix='{1}')" -f $_.FullName.Substring($RootDir.Length+1), $prefix)
}

# ---- Generate sitemap.xml and robots.txt ----
Write-Host "[ASD] Using base URL for sitemap: $Base"
$urls = New-Object System.Collections.Generic.List[object]
Get-ChildItem -Path $RootDir -Recurse -File -Include *.html |
  Where-Object { $_.FullName -ne $LayoutPath -and $_.FullName -notmatch '\\assets\\' -and $_.FullName -notmatch '\\partials\\' -and $_.Name -ne '404.html' } |
  ForEach-Object {
    $raw = Get-Content $_.FullName -Raw
    if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') { return }

    $rel = $_.FullName.Substring($RootDir.Length + 1) -replace '\\','/'
    $loc = $null
    if ($rel -ieq 'index.html') {
      $loc = $Base
    } else {
      $m = [regex]::Match($rel,'^(.+)/index\.html$')
      if ($m.Success) {
        $loc = ($Base.TrimEnd('/') + '/' + $m.Groups[1].Value + '/')
      } else {
        $loc = ($Base.TrimEnd('/') + '/' + $rel)
      }
    }
    $loc = Collapse-DoubleSlashesPreserveSchemeLocal $loc
    $last = (Get-Item $_.FullName).LastWriteTime.ToString('yyyy-MM-dd')
    $urls.Add([pscustomobject]@{ loc=$loc; lastmod=$last }) | Out-Null
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

$robotsPath = Join-Path $RootDir 'robots.txt'
$robots = if (Test-Path $robotsPath) { Get-Content $robotsPath -Raw } else { @"
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
"@ }
$robots = [regex]::Replace($robots,'(?im)^\s*Sitemap:\s*.*\r?\n?', '')
$absMap = 'sitemap.xml'
if ($Base -match '^[a-z]+://') { $absMap = (New-Object Uri((New-Object Uri($Base)),'sitemap.xml')).AbsoluteUri }
if ($robots -notmatch "\r?\n$") { $robots += [Environment]::NewLine }
$robots += "Sitemap: $absMap" + [Environment]::NewLine
Set-Content -Encoding UTF8 $robotsPath $robots
Write-Host "[ASD] robots.txt: Sitemap -> $absMap"

# Feeds
$rssPath  = Join-Path $RootDir 'feed.xml'
$atomPath = Join-Path $RootDir 'atom.xml'
$postsForFeed = Build-PostList -BlogDir $BlogDir -Base $Base
Generate-RssFeed  -posts $postsForFeed -base $Base -title $Brand -desc $Desc -outPath $rssPath  -maxItems 20
Generate-AtomFeed -posts $postsForFeed -base $Base -title $Brand -desc $Desc -outPath $atomPath -maxItems 20

Write-Host "[ASD] Done."
