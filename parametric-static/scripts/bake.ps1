<# ============================================
   Amaterasu Static Deploy (ASD) - bake.ps1
   - Single source of truth: config.json
   - Redirect stubs from redirects.json
   - Wraps pages with layout.html + {{PREFIX}}
   - Rewrites root-absolute links -> prefix-relative
   - Normalizes dashes " – — " -> "|"
   - Blog index refresh (stable dates)
   - Homepage: inject recent posts (ASD:RECENT_POSTS_* markers)
   - SEO robots: index all, 404 noindex
   - 404 absolute CSS + canonical home link fix
   - Sitemap (absolute or rooted)
   - RSS + Atom feeds
   - Client-side search index (assets/search-index.json)
   - Post UX: breadcrumbs, byline, reading time, TOC, anchors,
              prev/next, related, back-to-blog, share row, copy buttons,
              lazy images, responsive embeds, external-link hygiene,
              per-post head overrides (description/og:image), JSON-LD
   - Responsive images: width/height + @2x srcset (if available)
   - OG image auto-build (assets/img/og/<slug>.png) when missing
   - Perf tweaks: preload CSS + noscript fallback; defer external scripts
   - Trims extra blank lines around <main>
   - Preserves original file timestamps
   ============================================ #>

# Load shared helpers
. "$PSScriptRoot\_lib.ps1"

# ---------- Utils ----------
function TryParse-Date([string]$v) {
  if ([string]::IsNullOrWhiteSpace($v)) { return $null }
  [datetime]$out = [datetime]::MinValue
  $ok = [datetime]::TryParse($v,[Globalization.CultureInfo]::InvariantCulture,[Globalization.DateTimeStyles]::AssumeLocal,[ref]$out)
  if ($ok) { return $out } else { return $null }
}
function HtmlEscape([string]$s) {
  if ($null -eq $s) { return '' }
  $s = $s.Replace('&','&amp;').Replace('<','&lt;').Replace('>','&gt;').Replace('"','&quot;').Replace("'","&apos;")
  return $s
}
function JsString([string]$s) { if ($null -eq $s){return ''}; return $s.Replace('\','\\').Replace("'", "\'") }
function UrlEncode([string]$s){ if ($null -eq $s){return ''}; [Uri]::EscapeDataString($s) }
function Strip-Html([string]$s){
  if ($null -eq $s){return ''}
  $s = [regex]::Replace($s,'(?is)<script.*?</script>','')
  $s = [regex]::Replace($s,'(?is)<style.*?</style>','')
  $s = [regex]::Replace($s,'(?is)<[^>]+>',' ')
  $s = [regex]::Replace($s,'\s+',' ')
  $s.Trim()
}
function Rfc1123([datetime]$dt){ if ($null -eq $dt){$dt=Get-Date}; $dt.ToUniversalTime().ToString('r') }

function Preserve-FileTimes($path,[datetime]$c,[datetime]$w){
  try{(Get-Item $path).CreationTimeUtc=$c}catch{}
  try{(Get-Item $path).LastWriteTimeUtc=$w}catch{}
}
function Collapse-DoubleSlashesPreserveSchemeLocal([string]$url){
  if ([string]::IsNullOrWhiteSpace($url)){return $url}
  if ($url -match '^(https?://)(.*)$'){
    $scheme=$matches[1]; $rest=$matches[2] -replace '/{2,}','/'; return $scheme+$rest
  }
  ($url -replace '/{2,}','/')
}

# ---- BaseUrl normalization ----
function Normalize-BaseUrlLocal([string]$b){
  if ([string]::IsNullOrWhiteSpace($b)){ return "/" }
  $b = $b.Trim()
  $b = $b -replace '^/+(?=https?:)',''   # drop accidental leading slash before scheme
  $b = $b -replace '^((?:https?):)/{1,}','$1//'
  if ($b -match '^(https?://)(.+)$'){
    $scheme=$matches[1]; $rest=$matches[2].TrimStart('/')
    if (-not $b.EndsWith('/')){ $b = $scheme+$rest+'/' } else { $b = $scheme+$rest }
    return $b
  } else {
    return '/' + $b.Trim('/') + '/'
  }
}

# ---- Meta helpers ----
function Get-Meta([string]$html,[string]$nameOrProp,[switch]$IsProperty){
  if ($IsProperty) {
    $m = [regex]::Match($html,'(?is)<meta\s+property\s*=\s*(?:"|'')'+[regex]::Escape($nameOrProp)+'(?:"|'')\s+content\s*=\s*(?:"|'')([^"''<>]+)(?:"|'')')
  } else {
    $m = [regex]::Match($html,'(?is)<meta\s+name\s*=\s*(?:"|'')'+[regex]::Escape($nameOrProp)+'(?:"|'')\s+content\s*=\s*(?:"|'')([^"''<>]+)(?:"|'')')
  }
  if ($m.Success){ $m.Groups[1].Value.Trim() } else { $null }
}
function Get-MetaDateFromHtml([string]$html){
  $a = Get-Meta $html 'date'
  if ($a){ $dt=TryParse-Date $a; if($dt){ return $dt.ToString('yyyy-MM-dd') } }
  $t = [regex]::Match($html,'(?is)<time[^>]+datetime\s*=\s*(?:"|'')([^"''<>]+)(?:"|'')')
  if ($t.Success){ $dt=TryParse-Date ($t.Groups[1].Value.Trim()); if($dt){ return $dt.ToString('yyyy-MM-dd') } }
  $null
}

# ---- Redirect stubs ----
function Resolve-RedirectTarget([string]$to,[string]$base){
  if ([string]::IsNullOrWhiteSpace($to)){ return $base }
  $to=$to.Trim()
  if ($to -match '^[a-z]+://'){ return Collapse-DoubleSlashesPreserveSchemeLocal($to) }
  if ($to.StartsWith('/'))    { return Collapse-DoubleSlashesPreserveSchemeLocal($base.TrimEnd('/') + $to) }
  Collapse-DoubleSlashesPreserveSchemeLocal($base.TrimEnd('/') + '/' + $to)
}
function Make-RedirectOutputPath([string]$from,[string]$root){
  if ([string]::IsNullOrWhiteSpace($from)) { return $null }
  $rel = $from.Trim(); if ($rel.StartsWith('/')) { $rel=$rel.TrimStart('/') }
  if (-not ($rel -match '\.html?$')) { if ($rel.EndsWith('/')){ $rel+='index.html' } else { $rel+='/index.html' } }
  $out = Join-Path $root $rel; New-Item -ItemType Directory -Force -Path (Split-Path $out -Parent) | Out-Null; $out
}
function Write-RedirectStub([string]$outPath,[string]$absUrl,[int]$code){
  $href = HtmlEscape $absUrl; $jsu=JsString $absUrl
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
function Generate-RedirectStubs([string]$redirectsJson,[string]$root,[string]$base){
  if (-not (Test-Path $redirectsJson)){ return 0 }
  $items=@(); try{ $raw=Get-Content $redirectsJson -Raw; if(-not [string]::IsNullOrWhiteSpace($raw)){ $items=$raw|ConvertFrom-Json } }catch{ Write-Warning "[ASD] redirects.json is invalid; skipping."; return 0 }
  if ($null -eq $items){ return 0 }
  $count=0
  foreach($r in $items){
    $enabled=$true; if ($r.PSObject.Properties.Name -contains 'enabled'){ $enabled=[bool]$r.enabled }
    if (-not $enabled){ continue }
    $from=$null; $to=$null; $code=301
    if ($r.PSObject.Properties.Name -contains 'from'){ $from=[string]$r.from }
    if ($r.PSObject.Properties.Name -contains 'to')  { $to  =[string]$r.to   }
    if ($r.PSObject.Properties.Name -contains 'code'){ try{$code=[int]$r.code}catch{$code=301} }
    if ([string]::IsNullOrWhiteSpace($from) -or [string]::IsNullOrWhiteSpace($to)){ continue }
    if ($from -match '\*'){ continue }
    $out=Make-RedirectOutputPath $from $root
    $abs=Resolve-RedirectTarget $to $base
    Write-RedirectStub $out $abs $code
    $count++
  }
  $count
}

# ---- 404 absolute CSS + home link fixer ----
function Inject-404Fix([string]$html,[string]$absBase){
  if ([string]::IsNullOrWhiteSpace($absBase)){ return $html }
  $absBase = Normalize-BaseUrlLocal $absBase
  $snip = @"
<script>(function(){var BASE='$absBase';
function isAbs(u){return /^[a-z]+:\/\//i.test(u);}
function abs(u){if(!u)return u;if(isAbs(u))return u;if(u.charAt(0)=='/')return BASE.replace(/\/$/,'')+u;return BASE+u.replace(/^\.\//,'');}
function fix(){
  try{var links=document.querySelectorAll('link[rel="stylesheet"][href]');for(var i=0;i<links.length;i++){var h=links[i].getAttribute('href')||'';if(!isAbs(h)){links[i].setAttribute('href',abs(h));}}}catch(e){}
  try{var sels=['a[data-asd-home]','a[href="index.html"]','a[href="/"]','a[href="/index.html"]'];for(var s=0;s<sels.length;s++){var list=document.querySelectorAll(sels[s]);for(var j=0;j<list.length;j++){list[j].setAttribute('href',BASE);}}}catch(e){}
}
if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',fix);}else{fix();}
})();</script>
"@
  if ($html -match '(?is)</body>'){ return [regex]::Replace($html,'(?is)</body>',($snip+"`r`n</body>"),1) }
  elseif ($html -match '(?is)</head>'){ return [regex]::Replace($html,'(?is)</head>',($snip+"`r`n</head>"),1) }
  else { return $html + "`r`n" + $snip }
}

# ---- Robots meta ----
function Upsert-RobotsMeta([string]$html,[string]$value){
  if ([string]::IsNullOrWhiteSpace($html)){return $html}
  $tag = '<meta name="robots" content="' + $value + '">'
  $pattern='(?is)<meta\s+name\s*=\s*(?:"|'')robots(?:"|'')[^>]*>'
  if ($html -match $pattern){ return [regex]::Replace($html,$pattern,$tag,1) }
  if ($html -match '(?is)</head>'){ return [regex]::Replace($html,'(?is)</head>',('  '+$tag+"`r`n</head>"),1) }
  ($tag+"`r`n"+$html)
}
function Ensure-RobotsIndexMeta([string]$html){
  if ([string]::IsNullOrWhiteSpace($html)){return $html}
  if ($html -match '(?is)<meta\s+name\s*=\s*(?:"|'')robots(?:"|'')'){return $html}
  $tag = '<meta name="robots" content="index,follow">'
  if ($html -match '(?is)</head>'){ return [regex]::Replace($html,'(?is)</head>',('  '+$tag+"`r`n</head>"),1) }
  ($tag+"`r`n"+$html)
}

# ---- Content whitespace normalization ----
function Trim-OuterWhitespace([string]$s){
  if ($null -eq $s){return ''}
  $s=[regex]::Replace($s,'^\s+','')
  $s=[regex]::Replace($s,'\s+$','')
  $s
}
function Normalize-ContentForLayout([string]$s){
  if ($null -eq $s){return ''}
  $pat='(?is)(<!--\s*ASD:(?:CONTENT|BODY)_START\s*-->)(.*?)(<!--\s*ASD:(?:CONTENT|BODY)_END\s*-->)'
  if ([regex]::IsMatch($s,$pat)){
    return [regex]::Replace($s,$pat,{
      param($m)
      $inner=Trim-OuterWhitespace $m.Groups[2].Value
      $m.Groups[1].Value + "`r`n" + $inner + "`r`n" + $m.Groups[3].Value
    },1)
  }
  Trim-OuterWhitespace $s
}
function Normalize-MainWhitespace([string]$html){
  if ([string]::IsNullOrWhiteSpace($html)){return $html}
  $html=[regex]::Replace($html,'(?is)\r?\n\s*\r?\n\s*(?=<main\b)',"`r`n")
  $html=[regex]::Replace($html,'(?is)(</main>)\s*(\r?\n\s*){2,}','$1'+"`r`n")
  $html
}

# ---- Homepage recent posts ----
function Build-RecentPostsHtml([string]$blogDir,[int]$max=5){
  if (-not (Test-Path $blogDir)){ return '<p class="muted">No posts yet.</p>' }
  $entries=@()
  Get-ChildItem -Path $blogDir -Filter *.html -File |
    Where-Object { $_.Name -ne 'index.html' -and $_.Name -notmatch '^page-\d+\.html$' } |
    ForEach-Object {
      $raw=Get-Content $_.FullName -Raw
      if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b'){ return }
      $mTitle=[regex]::Match($raw,'(?is)<title>(.*?)</title>')
      if ($mTitle.Success){ $title=$mTitle.Groups[1].Value } else {
        $mH1=[regex]::Match($raw,'(?is)<h1[^>]*>(.*?)</h1>'); $title=if($mH1.Success){$mH1.Groups[1].Value}else{$_.BaseName}
      }
      $title=Normalize-DashesToPipe $title
      $metaDate=Get-MetaDateFromHtml $raw
      if ($metaDate){ $date=$metaDate; $sort=TryParse-Date $metaDate } else { $date=$_.CreationTime.ToString('yyyy-MM-dd'); $sort=$_.CreationTime }
      $entries += [pscustomobject]@{ Title=$title; Href=('blog/{0}' -f $_.Name); Date=$date; Sort=$sort }
    }
  if ($entries.Count -eq 0){ return '<p class="muted">No posts yet.</p>' }
  $items = New-Object System.Collections.Generic.List[string]
  foreach($e in ($entries|Sort-Object Sort -Descending|Select-Object -First $max)){
    $items.Add('<li><a href="'+$e.Href+'">'+$e.Title+'</a><small> | '+$e.Date+'</small></li>') | Out-Null
  }
  "<ul class=""posts"">`r`n"+([string]::Join([Environment]::NewLine,$items))+"`r`n</ul>"
}
function Inject-RecentPosts-IntoContent([string]$content,[string]$blogDir,[int]$max=5){
  if ([string]::IsNullOrWhiteSpace($content)){return $content}
  $pat='(?is)<!--\s*ASD:RECENT_POSTS_START\s*-->.*?<!--\s*ASD:RECENT_POSTS_END\s*-->'
  if (-not [regex]::IsMatch($content,$pat)){ return $content }
  $recent = Build-RecentPostsHtml -blogDir $blogDir -max $max
  $replacement = @"
<!-- ASD:RECENT_POSTS_START -->
$recent
<!-- ASD:RECENT_POSTS_END -->
"@
  [regex]::Replace($content,$pat,$replacement,1)
}

# ---- Post UX helpers ----
function Compute-ReadingTimeMinutes([string]$html){
  $txt = Strip-Html $html
  if ([string]::IsNullOrWhiteSpace($txt)){ return 1 }
  $words=([regex]::Matches($txt,'\b\w+\b')).Count
  $mins=[math]::Ceiling($words/200.0); if ($mins -lt 1){$mins=1}; [int]$mins
}
function Build-PostBreadcrumbs([string]$title){
  '<nav class="breadcrumbs"><a href="/index.html">Home</a> / <a href="/blog/">Blog</a> / <span>'+ (HtmlEscape $title) +'</span></nav>'
}
function Add-HeadingAnchors([string]$html,[ref]$tocItems){
  $ids=@{}; $toc=New-Object System.Collections.Generic.List[object]
  $pattern='(?is)<h([23])(\s[^>]*)?>(.*?)</h\1>'
  $e={
    param($m)
    $lvl=$m.Groups[1].Value; $attr=$m.Groups[2].Value; $inner=$m.Groups[3].Value; $id=$null
    $idMatch=[regex]::Match($attr,'(?i)\sid\s*=\s*["'']([^"'']+)["'']'); if ($idMatch.Success){ $id=$idMatch.Groups[1].Value }
    if (-not $id){
      $textOnly=Strip-Html $inner; $id=($textOnly.ToLower() -replace '[^a-z0-9]+','-').Trim('-')
      if ([string]::IsNullOrWhiteSpace($id)){ $id='section-'+[guid]::NewGuid().ToString('N').Substring(0,8) }
      $base=$id; $n=1; while($ids.ContainsKey($id)){ $id=$base+'-'+$n; $n++ }
      $attr = ($attr + ' id="' + $id + '"')
    }
    $ids[$id]=$true; $toc.Add([pscustomobject]@{Level=[int]$lvl; Id=$id; Text=(Strip-Html $inner)})|Out-Null
    '<h'+$lvl+$attr+'>'+ $inner +'<a class="h-anchor" href="#'+$id+'" aria-label="Link to section">#</a></h'+$lvl+'>'
  }
  $out=[regex]::Replace($html,$pattern,$e); $tocItems.Value=$toc; $out
}
function Build-TocHtml($tocItems){
  if ($null -eq $tocItems -or $tocItems.Count -eq 0){ return '' }
  $sb=New-Object Text.StringBuilder
  [void]$sb.AppendLine('<nav class="toc"><div class="toc-title">On this page</div><ul>')
  foreach($it in $tocItems){ $cls = if ($it.Level -eq 3){' class="toc-sub"'} else {''}; [void]$sb.AppendLine('  <li'+$cls+'><a href="#'+$it.Id+'">'+(HtmlEscape $it.Text)+'</a></li>') }
  [void]$sb.AppendLine('</ul></nav>'); $sb.ToString()
}
function Insert-AfterFirstH1([string]$content,[string]$insertHtml){
  if ([string]::IsNullOrWhiteSpace($insertHtml)){return $content}
  [regex]::Replace($content,'(?is)(</h1>)',('$1'+"`r`n"+$insertHtml),1)
}
function Remove-OldPostExtras([string]$content){
  if ([string]::IsNullOrWhiteSpace($content)){return $content}
  $content=[regex]::Replace($content,'(?is)\s*<nav\s+class="breadcrumbs".*?</nav>\s*','')
  $content=[regex]::Replace($content,'(?is)\s*<div\s+class="byline".*?</div>\s*','')
  $content=[regex]::Replace($content,'(?is)\s*<div\s+class="series-banner".*?</div>\s*','')
  $content=[regex]::Replace($content,'(?is)\s*<nav\s+class="toc".*?</nav>\s*','')
  $content=[regex]::Replace($content,'(?is)\s*<hr>\s*(?=<div\s+class="share-row")','')
  $content=[regex]::Replace($content,'(?is)\s*<div\s+class="share-row".*?</div>\s*','')
  $content=[regex]::Replace($content,'(?is)\s*<nav\s+class="post-nav".*?</nav>\s*','')
  $content=[regex]::Replace($content,'(?is)\s*<section\s+class="related".*?</section>\s*','')
  $content=[regex]::Replace($content,'(?is)\s*<p\s+class="back-blog".*?</p>\s*','')
  $content
}
function Upsert-Block([string]$content,[string]$startMarker,[string]$endMarker,[string]$html,[switch]$AppendIfMissing,[switch]$AfterH1){
  $wrapped=$startMarker+"`r`n"+$html+"`r`n"+$endMarker
  $pat='(?is)'+[regex]::Escape($startMarker)+'.*?'+[regex]::Escape($endMarker)
  if ([regex]::IsMatch($content,$pat)){ return [regex]::Replace($content,$pat,$wrapped,1) }
  if ($AfterH1){ return Insert-AfterFirstH1 $content $wrapped }
  if ($AppendIfMissing){ return ($content+"`r`n"+$wrapped) }
  $content
}
function Lazyify-Images([string]$html){ [regex]::Replace($html,'(?i)<img\b(?![^>]*\bloading=)','<img loading="lazy" ') }
function Wrap-Embeds([string]$html){
  $pattern='(?is)(<iframe\b[^>]*\bsrc\s*=\s*["''](?:https?:)?//(?:www\.)?(?:youtube\.com|youtu\.be|player\.vimeo\.com)[^"''<>]*["''][^>]*></iframe>)'
  [regex]::Replace($html,$pattern,{ param($m) '<div class="video">'+$m.Groups[1].Value+'</div>' })
}
function External-Link-Hygiene([string]$html,[string]$base){
  $baseHost=$null; try{$u=[Uri]$base; $baseHost=$u.Host.ToLower()}catch{}
  $pattern='(?is)<a\b([^>]*?)\shref\s*=\s*["''](https?://[^"''<>]+)["'']([^>]*)>'
  $e={
    param($m)
    $pre=$m.Groups[1].Value; $url=$m.Groups[2].Value; $post=$m.Groups[3].Value
    $target= if ($m.Value -match '(?i)\btarget\s*=') { '' } else { ' target="_blank"' }
    $rel   = if ($m.Value -match '(?i)\brel\s*=')    { '' } else { ' rel="noopener"' }
    try{ $uh=([Uri]$url).Host.ToLower(); if ($baseHost -and $uh -eq $baseHost){ $target=''; $rel='' } }catch{}
    '<a'+$pre+' href="'+$url+'"'+$target+$rel+$post+'>'
  }
  [regex]::Replace($html,$pattern,$e)
}

# ---- Image enhancement: width/height + @2x srcset ----
function Ensure-SystemDrawing {
  if (-not ([AppDomain]::CurrentDomain.GetAssemblies() | Where-Object { $_.GetName().Name -eq 'System.Drawing' })) {
    try { Add-Type -AssemblyName System.Drawing } catch {}
  }
}
function Resolve-ImgPath([string]$src,[string]$pageDir,[string]$root){
  if ([string]::IsNullOrWhiteSpace($src)){ return $null }
  if ($src -match '^[a-z]+://'){ return $null }
  if ($src.StartsWith('/')) { return Join-Path $root ($src.TrimStart('/') -replace '/','\') }
  Join-Path $pageDir ($src -replace '/','\')
}
function Enhance-Images([string]$html,[string]$pageDir,[string]$root){
  Ensure-SystemDrawing
  $pattern='(?is)<img\b([^>]*?)\bsrc\s*=\s*["'']([^"''<>]+)["'']([^>]*)>'
  $e={
    param($m)
    $pre=$m.Groups[1].Value; $src=$m.Groups[2].Value; $post=$m.Groups[3].Value
    $orig = $m.Value
    $path = Resolve-ImgPath $src $using:pageDir $using:root
    if (-not $path -or -not (Test-Path $path)){ return $orig }
    try{
      $img=[System.Drawing.Image]::FromFile($path)
      $w=$img.Width; $h=$img.Height; $img.Dispose()
      if ($orig -notmatch '(?i)\bwidth=') { $pre += ' width="'+$w+'"' }
      if ($orig -notmatch '(?i)\bheight='){ $pre += ' height="'+$h+'"' }
      # @2x partner
      $dir=[IO.Path]::GetDirectoryName($path); $name=[IO.Path]::GetFileNameWithoutExtension($path); $ext=[IO.Path]::GetExtension($path)
      $path2x = Join-Path $dir ($name+'@2x'+$ext)
      if (Test-Path $path2x){
        if ($orig -notmatch '(?i)\bsrcset='){
          $post = ' srcset="'+$src+' 1x, '+([IO.Path]::Combine([IO.Path]::GetDirectoryName($src),[IO.Path]::GetFileName($src)) -replace '\\','/')+'@2x'+$ext+' 2x"'+$post
        }
      }
      '<img'+$pre+' src="'+$src+'"'+$post+'>'
    } catch { $orig }
  }
  [regex]::Replace($html,$pattern,$e)
}

# ---- Head overrides & JSON-LD ----
function Apply-HeadOverrides([string]$html,[string]$desc,[string]$ogImageAbs){
  $out=$html
  if ($desc){
    $out=[regex]::Replace($out,'(?is)<meta\s+name\s*=\s*(?:"|'')description(?:"|'')\s+content\s*=\s*(?:"|'')[^"''<>]*(?:"|'')\s*/?>','<meta name="description" content="'+(HtmlEscape $desc)+'">',1)
    $out=[regex]::Replace($out,'(?is)<meta\s+property\s*=\s*(?:"|'')og:description(?:"|'')\s+content\s*=\s*(?:"|'')[^"''<>]*(?:"|'')\s*/?>','<meta property="og:description" content="'+(HtmlEscape $desc)+'">',1)
  }
  if ($ogImageAbs){
    $out=[regex]::Replace($out,'(?is)<meta\s+property\s*=\s*(?:"|'')og:image(?:"|'')\s+content\s*=\s*(?:"|'')[^"''<>]*(?:"|'')\s*/?>','<meta property="og:image" content="'+(HtmlEscape $ogImageAbs)+'">',1)
  }
  $out
}
function Build-JsonLd([string]$headline,[string]$author,[string]$datePub,[string]$dateMod,[string]$absUrl,[string]$imgAbs){
  $headline=$headline -replace '"','\"'; $author=$author -replace '"','\"'
  $imgJson= if ($imgAbs){ '"image": ["'+$imgAbs+'"],' } else { '' }
@"
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
}
function Strip-JsonLdMarkers([string]$html){ [regex]::Replace($html,'(?is)<!--\s*ASD:JSONLD_START\s*-->.*?<!--\s*ASD:JSONLD_END\s*-->','',1) }
function Inject-IntoHead([string]$html,[string]$snippet){ if ([string]::IsNullOrWhiteSpace($snippet)){return $html}; if ($html -match '(?is)</head>'){ return [regex]::Replace($html,'(?is)</head>',($snippet+"`r`n</head>"),1) } else { return $html+"`r`n"+$snippet } }
function Inject-BottomScript([string]$html,[string]$snippet,[string]$markerName){
  if ([string]::IsNullOrWhiteSpace($snippet)){return $html}
  $start='<!-- ASD:'+$markerName+'_START -->'; $end='<!-- ASD:'+ $markerName +'_END -->'
  $wrapped=$start+"`r`n"+$snippet+"`r`n"+$end
  $pat='(?is)'+[regex]::Escape($start)+'.*?'+[regex]::Escape($end)
  if ($html -match $pat){ return [regex]::Replace($html,$pat,$wrapped,1) }
  if ($html -match '(?is)</body>'){ return [regex]::Replace($html,'(?is)</body>',($wrapped+"`r`n</body>"),1) }
  $html+"`r`n"+$wrapped
}

# ---- Collect posts ----
function Collect-AllPosts($blogDir){
  $list=New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path $blogDir)){ return $list }
  Get-ChildItem -Path $blogDir -Filter *.html -File |
    Where-Object { $_.Name -ne 'index.html' -and $_.Name -notmatch '^page-\d+\.html$' } |
    ForEach-Object {
      $raw=Get-Content $_.FullName -Raw
      if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b'){ return }
      $mTitle=[regex]::Match($raw,'(?is)<title>(.*?)</title>')
      if ($mTitle.Success){ $title=$mTitle.Groups[1].Value } else {
        $mH1=[regex]::Match($raw,'(?is)<h1[^>]*>(.*?)</h1>'); $title=if($mH1.Success){$mH1.Groups[1].Value}else{$_.BaseName}
      }
      $title=Normalize-DashesToPipe $title
      $author=(Get-Meta $raw 'author'); if (-not $author){ $author='Maestro' }
      $date   = Get-MetaDateFromHtml $raw; $dateDt = if($date){ TryParse-Date $date } else { $_.CreationTime }
      $date   = if($date){ $date } else { $_.CreationTime.ToString('yyyy-MM-dd') }
      $desc   = Get-Meta $raw 'description'
      $tags   = Get-Meta $raw 'tags'; $tagsArr=@(); if ($tags){ $tagsArr=@($tags.Split(',')|ForEach-Object{$_.Trim().ToLower()}|Where-Object{$_ -ne ''}) }
      $series = Get-Meta $raw 'series'
      $ogimg  = Get-Meta $raw 'og:image' -IsProperty
      $contentSegment = Extract-Content $raw
      $excerpt = ($contentSegment -replace '(?is)<!--.*?-->',''); $excerpt = Strip-Html $excerpt; if ($excerpt.Length -gt 240){ $excerpt = $excerpt.Substring(0,240).Trim()+'…' }
      $list.Add([pscustomobject]@{ Name=$_.Name; Title=$title; Author=$author; DateText=$date; Date=$dateDt; Desc=$desc; Tags=$tagsArr; Series=$series; OgImage=$ogimg; Excerpt=$excerpt })|Out-Null
    }
  $list
}

function Find-PrevNext($all,[string]$name){
  $sorted=$all|Sort-Object Date -Descending
  $i=0; for($i=0;$i -lt $sorted.Count;$i++){ if ($sorted[$i].Name -eq $name){ break } }
  $prev=$null; $next=$null
  if ($i -lt $sorted.Count){ if ($i -gt 0){ $prev=$sorted[$i-1] }; if ($i+1 -lt $sorted.Count){ $next=$sorted[$i+1] } }
  @($prev,$next)
}
function Find-Related($all,[string]$name,$tags,[int]$max=3){
  $pool=$all|Where-Object { $_.Name -ne $name }
  $byTag=@()
  if ($tags -and $tags.Count -gt 0){
    $byTag=$pool|Where-Object { ($_.Tags | ForEach-Object { $tags -contains $_ }) -contains $true }
  }
  if ($byTag.Count -eq 0){ ($pool|Sort-Object Date -Descending|Select-Object -First $max) } else { ($byTag|Sort-Object Date -Descending|Select-Object -First $max) }
}

# ---- Feeds ----
function Build-Rss([object[]]$posts,[string]$base,[string]$title,[string]$desc,[string]$outPath,[int]$maxItems=20){
  $base=Normalize-BaseUrlLocal $base
  $chTitle=HtmlEscape $title; $chDesc=HtmlEscape $desc
  $selfHref = if ($base -match '^[a-z]+://'){ (New-Object Uri((New-Object Uri($base)),'feed.xml')).AbsoluteUri } else { ($base.TrimEnd('/') + '/feed.xml') }
  $lines=New-Object System.Collections.Generic.List[string]
  $lines.Add('<?xml version="1.0" encoding="UTF-8"?>')|Out-Null
  $lines.Add('<rss version="2.0" xmlns:atom="http://www.w3.org/2005/Atom">')|Out-Null
  $lines.Add('  <channel>')|Out-Null
  $lines.Add('    <title>'+ $chTitle +'</title>')|Out-Null
  $lines.Add('    <link>'+ (HtmlEscape $base) +'</link>')|Out-Null
  $lines.Add('    <description>'+ $chDesc +'</description>')|Out-Null
  $lines.Add('    <generator>ASD</generator>')|Out-Null
  $lines.Add('    <lastBuildDate>'+ (Rfc1123 (Get-Date)) +'</lastBuildDate>')|Out-Null
  $lines.Add('    <atom:link href="'+(HtmlEscape $selfHref)+'" rel="self" type="application/rss+xml" />')|Out-Null
  $i=0
  foreach($p in ($posts|Sort-Object Date -Descending)){
    if ($i -ge $maxItems){ break }; $i++
    $itemTitle=HtmlEscape $p.Title
    $itemLink = Collapse-DoubleSlashesPreserveSchemeLocal ($base.TrimEnd('/') + '/blog/' + $p.Name)
    $pub = if ($p.Date -is [datetime]){ Rfc1123 $p.Date } else { Rfc1123 (TryParse-Date $p.DateText) }
    $lines.Add('    <item>')|Out-Null
    $lines.Add('      <title>'+ $itemTitle +'</title>')|Out-Null
    $lines.Add('      <link>'+ (HtmlEscape $itemLink) +'</link>')|Out-Null
    $lines.Add('      <guid isPermaLink="true">'+ (HtmlEscape $itemLink) +'</guid>')|Out-Null
    $lines.Add('      <pubDate>'+ $pub +'</pubDate>')|Out-Null
    if ($p.Desc){ $lines.Add('      <description>'+ (HtmlEscape $p.Desc) +'</description>')|Out-Null }
    $lines.Add('    </item>')|Out-Null
  }
  $lines.Add('  </channel>')|Out-Null
  $lines.Add('</rss>')|Out-Null
  Set-Content -Encoding UTF8 $outPath ($lines -join "`r`n")
}
function Build-Atom([object[]]$posts,[string]$base,[string]$title,[string]$outPath,[int]$maxItems=20){
  $base=Normalize-BaseUrlLocal $base
  $selfHref = if ($base -match '^[a-z]+://'){ (New-Object Uri((New-Object Uri($base)),'atom.xml')).AbsoluteUri } else { ($base.TrimEnd('/') + '/atom.xml') }
  $feedId   = if ($base -match '^[a-z]+://'){ $base } else { 'tag:local,' + (Get-Date -Format 'yyyy-MM-dd') + ':' + $base }
  $lines=New-Object System.Collections.Generic.List[string]
  $lines.Add('<?xml version="1.0" encoding="UTF-8"?>')|Out-Null
  $lines.Add('<feed xmlns="http://www.w3.org/2005/Atom">')|Out-Null
  $lines.Add('  <title>'+ (HtmlEscape $title) +'</title>')|Out-Null
  $lines.Add('  <id>'+ (HtmlEscape $feedId) +'</id>')|Out-Null
  $lines.Add('  <updated>'+ (Get-Date).ToUniversalTime().ToString('s') + 'Z</updated>')|Out-Null
  $lines.Add('  <link rel="self" href="'+ (HtmlEscape $selfHref) +'" />')|Out-Null
  $i=0
  foreach($p in ($posts|Sort-Object Date -Descending)){
    if ($i -ge $maxItems){ break }; $i++
    $itemLink = Collapse-DoubleSlashesPreserveSchemeLocal ($base.TrimEnd('/') + '/blog/' + $p.Name)
    $dt = if ($p.Date -is [datetime]) { $p.Date } else { TryParse-Date $p.DateText }
    if (-not $dt) { $dt = Get-Date }
    $lines.Add('  <entry>')|Out-Null
    $lines.Add('    <title>'+ (HtmlEscape $p.Title) +'</title>')|Out-Null
    $lines.Add('    <link href="'+ (HtmlEscape $itemLink) +'" />')|Out-Null
    $lines.Add('    <id>'+ (HtmlEscape $itemLink) +'</id>')|Out-Null
    $lines.Add('    <updated>'+ $dt.ToUniversalTime().ToString('s') + 'Z</updated>')|Out-Null
    if ($p.Excerpt){ $lines.Add('    <summary>'+ (HtmlEscape $p.Excerpt) +'</summary>')|Out-Null }
    $lines.Add('  </entry>')|Out-Null
  }
  $lines.Add('</feed>')|Out-Null
  Set-Content -Encoding UTF8 $outPath ($lines -join "`r`n")
}

# ---- Search index (client-side) ----
function Build-SearchIndex([object[]]$posts,[string]$rootDir){
  $rows = @()
  foreach($p in $posts){
    $rows += [pscustomobject]@{
      title = $p.Title
      url   = ('/blog/'+$p.Name)
      date  = $p.DateText
      desc  = if ($p.Desc){ $p.Desc } else { $p.Excerpt }
      tags  = ($p.Tags -join ', ')
    }
  }
  $json = ConvertTo-Json -Depth 5 -InputObject $rows
  $out  = Join-Path $rootDir 'assets\search-index.json'
  Set-Content -Encoding UTF8 $out $json
}

# ---- OG image auto-builder ----
function Ensure-OgDir([string]$root){ $ogDir=Join-Path $root 'assets\img\og'; New-Item -ItemType Directory -Force -Path $ogDir | Out-Null; $ogDir }
function Generate-OgImage([string]$title,[string]$brand,[string]$outPath){
  Ensure-SystemDrawing
  $w=1200; $h=630
  $bmp = New-Object System.Drawing.Bitmap $w,$h
  $gfx = [System.Drawing.Graphics]::FromImage($bmp)
  $gfx.SmoothingMode = 'HighQuality'
  $gfx.Clear([System.Drawing.Color]::FromArgb(0x11,0x11,0x11))
  $brushBrand = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(0xFF,0xCC,0x00))
  $brushText  = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
  $fontTitle  = New-Object System.Drawing.Font('Segoe UI Semibold', 48, [System.Drawing.FontStyle]::Bold)
  $fontBrand  = New-Object System.Drawing.Font('Segoe UI', 28)
  $margin=60
  $gfx.DrawString($brand, $fontBrand, $brushBrand, $margin, $margin)
  $rect = New-Object System.Drawing.RectangleF($margin, 160, $w-2*$margin, $h-220)
  $sf = New-Object System.Drawing.StringFormat
  $sf.Alignment = 'Near'; $sf.LineAlignment='Near'
  $gfx.DrawString($title, $fontTitle, $brushText, $rect, $sf)
  $bmp.Save($outPath, [System.Drawing.Imaging.ImageFormat]::Png)
  $gfx.Dispose(); $bmp.Dispose(); $brushBrand.Dispose(); $brushText.Dispose(); $fontTitle.Dispose(); $fontBrand.Dispose()
}

# ---- Perf: preload CSS and defer external scripts (idempotent) ----
function Optimize-Head([string]$html){
  if ([string]::IsNullOrWhiteSpace($html)) { return $html }

  # Upgrade stylesheet to preload+noscript (first occurrence of assets/css/style.css)
  $patCss = '(?is)<link\s+rel\s*=\s*(?:"|'')stylesheet(?:"|'')\s+href\s*=\s*(?:"|'')([^"''<>]*assets/css/style\.css[^"''<>]*)(?:"|'')[^>]*>'
  if ($html -notmatch '(?is)\brel\s*=\s*(?:"|'')preload(?:"|'')' -and $html -match $patCss) {
    $href = $matches[1]
    $preload = '<link rel="preload" href="'+$href+'" as="style" onload="this.onload=null;this.rel=''stylesheet''"><noscript><link rel="stylesheet" href="'+$href+'"></noscript>'
    $html = [regex]::Replace($html,$patCss,[System.Text.RegularExpressions.MatchEvaluator]{ param($m) $preload },1)
  }

  # Add defer to external script tags that don't already have it
  $patJs = '(?is)<script\s+([^>]*\bsrc\s*=\s*["''][^"''<>]+["''][^>]*)>'
  $html = [regex]::Replace($html, $patJs, {
    param($m)
    $attrs = $m.Groups[1].Value
    if ($attrs -match '(?i)\bdefer\b') { $m.Value } else { '<script ' + $attrs + ' defer>' }
  })

  return $html
}

# ========== Main ==========
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

# Collect posts once
$AllPosts = Collect-AllPosts $BlogDir

# Refresh /blog/ index
$BlogIndex = Join-Path $BlogDir "index.html"
if (Test-Path $BlogIndex) {
  $posts = New-Object System.Collections.Generic.List[string]
  foreach($e in ($AllPosts | Sort-Object Date -Descending)) {
    $posts.Add('<li><a href="./'+$e.Name+'">'+$e.Title+'</a><small> | '+$e.DateText+'</small></li>') | Out-Null
  }
  $bi = Get-Content $BlogIndex -Raw
  $replacement = @"
<!-- POSTS_START -->
$([string]::Join([Environment]::NewLine,$posts))
<!-- POSTS_END -->
"@
  $bi = [regex]::Replace($bi,'(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->',$replacement)
  Set-Content -Encoding UTF8 $BlogIndex $bi
  Write-Host "[ASD] Blog index updated"
}

# Wrap every HTML (except layout)
Get-ChildItem -Path $RootDir -Recurse -File |
  Where-Object { $_.Extension -eq ".html" -and $_.FullName -ne $LayoutPath } |
  ForEach-Object {
    $it = Get-Item $_.FullName
    $c0 = $it.CreationTimeUtc; $w0 = $it.LastWriteTimeUtc
    $raw = Get-Content $_.FullName -Raw

    if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b') {
      Write-Host ("[ASD] Skipped wrapping redirect stub: {0}" -f $_.FullName.Substring($RootDir.Length+1))
      return
    }

    $content = Extract-Content $raw
    $content = Normalize-ContentForLayout $content

    # Home recent posts
    $isHome = ([IO.Path]::GetFileName($_.FullName)).ToLower() -eq 'index.html' -and ([IO.Path]::GetDirectoryName($_.FullName)).TrimEnd('\') -eq $RootDir.TrimEnd('\')
    if ($isHome) { $content = Inject-RecentPosts-IntoContent -content $content -blogDir $BlogDir -max 5 }

    # Post?
    $isPost = ([IO.Path]::GetDirectoryName($_.FullName)).TrimEnd('\') -eq $BlogDir.TrimEnd('\') -and ([IO.Path]::GetFileName($_.FullName)).ToLower() -notmatch '^index\.html$|^page-\d+\.html$'

    # Title
    $tm = [regex]::Match($content,'(?is)<h1[^>]*>(.*?)</h1>')
    $pageTitle = if ($tm.Success){ $tm.Groups[1].Value } else { $_.BaseName }
    $pageTitle = Normalize-DashesToPipe $pageTitle

    # Post enhancements
    $postMeta=$null; $hasCode=$false
    if ($isPost) {
      $content = Remove-OldPostExtras $content
      $thisName = $_.Name
      $postMeta = ($AllPosts | Where-Object { $_.Name -eq $thisName } | Select-Object -First 1)
      if ($null -eq $postMeta) { $postMeta=[pscustomobject]@{ Name=$thisName; Title=$pageTitle; Author='Maestro'; DateText=$_.CreationTime.ToString('yyyy-MM-dd'); Date=$_.CreationTime; Desc=$null; Tags=@(); Series=$null; OgImage=$null; Excerpt='' } }

      # Anchors + TOC
      $tocItems=$null
      $content = Add-HeadingAnchors $content ([ref]$tocItems)
      $tocHtml = Build-TocHtml $tocItems

      # Reading time + breadcrumbs/byline/series
      $readMin = Compute-ReadingTimeMinutes $content
      $crumbs  = Build-PostBreadcrumbs $pageTitle
      $byline  = '<div class="byline"><span class="byline-item">'+(HtmlEscape $postMeta.Author)+'</span><span class="byline-dot">·</span><time datetime="'+$postMeta.DateText+'">'+$postMeta.DateText+'</time><span class="byline-dot">·</span><span class="byline-read">'+$readMin+' min read</span></div>'
      $seriesHtml = if ($postMeta.Series){ '<div class="series-banner">Part of the <strong>'+ (HtmlEscape $postMeta.Series) +'</strong> series.</div>' } else { '' }
      $topBlock = $crumbs + $byline + $seriesHtml + $tocHtml
      $content  = Upsert-Block -content $content -startMarker '<!-- ASD:POST_TOP_START -->' -endMarker '<!-- ASD:POST_TOP_END -->' -html $topBlock -AfterH1

      # Bottom: prev/next + related + back + share
      $pn = Find-PrevNext $AllPosts $thisName
      $prev=$pn[0]; $next=$pn[1]
      $prevHtml = if ($prev){ '<a class="prev" href="/blog/'+$prev.Name+'">← '+(HtmlEscape $prev.Title)+'</a>' } else { '' }
      $nextHtml = if ($next){ '<a class="next" href="/blog/'+$next.Name+'">'+(HtmlEscape $next.Title)+' →</a>' } else { '' }
      $postNav  = '<nav class="post-nav">'+$prevHtml+'<span></span>'+$nextHtml+'</nav>'

      $related = Find-Related $AllPosts $thisName $postMeta.Tags 3
      $relItems = New-Object System.Collections.Generic.List[string]
      foreach($r in $related){ $relItems.Add('<li><a href="/blog/'+$r.Name+'">'+(HtmlEscape $r.Title)+'</a><small> | '+$r.DateText+'</small></li>') | Out-Null }
      $relList = if ($relItems.Count -gt 0){ '<section class="related"><h2>Related posts</h2><ul class="posts">'+([string]::Join('', $relItems))+'</ul></section>' } else { '' }

      $back = '<p class="back-blog"><a href="/blog/">← Back to all posts</a></p>'
      $absPostUrl = Collapse-DoubleSlashesPreserveSchemeLocal ($Base.TrimEnd('/') + '/blog/' + $thisName)
      $share = '<div class="share-row">Share: <a href="https://twitter.com/intent/tweet?url='+ (UrlEncode $absPostUrl) +'&text='+ (UrlEncode $pageTitle) +'">X/Twitter</a> · <a href="https://www.linkedin.com/sharing/share-offsite/?url='+(UrlEncode $absPostUrl)+'">LinkedIn</a> · <a href="https://www.facebook.com/sharer/sharer.php?u='+(UrlEncode $absPostUrl)+'">Facebook</a></div>'

      $bottomBlock = '<hr>'+ $share + $postNav + $relList + $back
      $content     = Upsert-Block -content $content -startMarker '<!-- ASD:POST_BOTTOM_START -->' -endMarker '<!-- ASD:POST_BOTTOM_END -->' -html $bottomBlock -AppendIfMissing

      # Lazy+embeds+external link hygiene
      $content = Lazyify-Images $content
      $content = Wrap-Embeds $content
      $content = External-Link-Hygiene $content $Base

      # Responsive image metadata
      $content = Enhance-Images $content ([IO.Path]::GetDirectoryName($_.FullName)) $RootDir

      # Copy button JS if code blocks present
      if ($content -match '(?is)<pre[^>]*>\s*<code'){ $hasCode=$true }
    }

    # Compute prefix depth
    $prefix = Get-RelPrefix -RootDir $RootDir -FilePath $_.FullName

    # Build final page
    $final = $Layout.Replace('{{CONTENT}}',$content).Replace('{{TITLE}}',$pageTitle).Replace('{{BRAND}}',$Brand).Replace('{{DESCRIPTION}}',$Desc).Replace('{{MONEY}}',$Money).Replace('{{YEAR}}',"$Year").Replace('{{PREFIX}}',$prefix)

    # Link fixes, dashes, whitespace
    $final = Rewrite-RootLinks $final $prefix
    $final = Normalize-DashesToPipe $final
    $final = Normalize-MainWhitespace $final

    # Perf head tweaks (preload CSS + defer scripts)
    $final = Optimize-Head $final

    # SEO robots + 404 fix
    $is404 = ([IO.Path]::GetFileName($_.FullName)).ToLower() -eq '404.html'
    if ($is404){ $final = Upsert-RobotsMeta $final 'noindex,follow'; $final = Inject-404Fix $final $Base } else { $final = Ensure-RobotsIndexMeta $final }

    # Post head overrides + JSON-LD + copyJS + OG image auto
    if ($isPost -and $postMeta) {
      # OG image auto-generate if missing
      $ogAbs=$null
      if ($postMeta.OgImage) {
        if     ($postMeta.OgImage -match '^[a-z]+://'){ $ogAbs=$postMeta.OgImage }
        elseif ($postMeta.OgImage.StartsWith('/'))    { $ogAbs=Collapse-DoubleSlashesPreserveSchemeLocal ($Base.TrimEnd('/') + $postMeta.OgImage) }
        else                                          { $ogAbs=Collapse-DoubleSlashesPreserveSchemeLocal ($Base.TrimEnd('/') + '/' + $postMeta.OgImage) }
      } else {
        $ogDir = Ensure-OgDir $RootDir
        $ogName = [IO.Path]::GetFileNameWithoutExtension($postMeta.Name)+'.png'
        $ogPath = Join-Path $ogDir $ogName
        if (-not (Test-Path $ogPath)) { Generate-OgImage $pageTitle $Brand $ogPath }
        $ogAbs = Collapse-DoubleSlashesPreserveSchemeLocal ($Base.TrimEnd('/') + '/assets/img/og/' + $ogName)
      }
      $final = Apply-HeadOverrides $final $postMeta.Desc $ogAbs

      # JSON-LD article (idempotent)
      $absPostUrl = Collapse-DoubleSlashesPreserveSchemeLocal ($Base.TrimEnd('/') + '/blog/' + $postMeta.Name)
      $final = Strip-JsonLdMarkers $final
      $jsonld = Build-JsonLd $pageTitle $postMeta.Author $postMeta.DateText ((Get-Item $_.FullName).LastWriteTime.ToString('yyyy-MM-dd')) $absPostUrl $ogAbs
      $final = Inject-IntoHead $final $jsonld

      # Copy buttons
      if ($hasCode){
        $copyJs = @"
<script>(function(){try{
  var blocks=document.querySelectorAll('pre>code'); if(!blocks.length) return;
  for(var i=0;i<blocks.length;i++){
    var pre=blocks[i].parentNode; pre.style.position='relative';
    if(pre.querySelector('button.code-copy')) continue;
    var btn=document.createElement('button'); btn.type='button'; btn.className='code-copy'; btn.textContent='Copy';
    btn.addEventListener('click',(function(c,b){return function(){try{var t=c.innerText||c.textContent; navigator.clipboard.writeText(t).then(function(){b.textContent='Copied!'; setTimeout(function(){b.textContent='Copy';},1200);});}catch(e){}};})(blocks[i],btn));
    pre.appendChild(btn);
  }
}catch(e){}})();</script>
"@
        $final = Inject-BottomScript -html $final -snippet $copyJs -markerName 'COPYJS'
      }
    }

    # Dark-mode toggle injection (floating button, persists)
    $darkJs = @"
<script>(function(){
  function apply(t){document.documentElement.setAttribute('data-theme',t);}
  var key='asd-theme', saved=localStorage.getItem(key);
  if(saved){apply(saved);}else if(window.matchMedia && window.matchMedia('(prefers-color-scheme: dark)').matches){apply('dark');}
  function ensureButton(){
    if(document.querySelector('.theme-toggle')) return;
    var b=document.createElement('button'); b.className='theme-toggle'; b.type='button'; b.setAttribute('aria-label','Toggle theme'); b.textContent='☾';
    b.addEventListener('click',function(){ var cur=document.documentElement.getAttribute('data-theme'); var nxt=cur==='dark'?'light':'dark'; apply(nxt); localStorage.setItem(key,nxt); });
    document.body.appendChild(b);
  }
  if(document.readyState==='loading'){document.addEventListener('DOMContentLoaded',ensureButton);}else{ensureButton();}
})();</script>
"@
    $final = Inject-BottomScript -html $final -snippet $darkJs -markerName 'DARKMODE'

    Set-Content -Encoding UTF8 $_.FullName $final
    Preserve-FileTimes $_.FullName $c0 $w0
    Write-Host ("[ASD] Wrapped {0} (prefix='{1}')" -f $_.FullName.Substring($RootDir.Length+1), $prefix)
  }

# ---- Sitemap ----
Write-Host "[ASD] Using base URL for sitemap: $Base"
$urls = New-Object System.Collections.Generic.List[object]
Get-ChildItem -Path $RootDir -Recurse -File -Include *.html |
  Where-Object { $_.FullName -ne $LayoutPath -and $_.FullName -notmatch '\\assets\\' -and $_.FullName -notmatch '\\partials\\' -and $_.Name -ne '404.html' } |
  ForEach-Object {
    $raw=Get-Content $_.FullName -Raw
    if ($raw -match '(?is)<!--\s*ASD:REDIRECT\b'){ return }
    $rel=$_.FullName.Substring($RootDir.Length + 1) -replace '\\','/'
    if ($rel -ieq 'index.html') { $loc=$Base }
    elseif ($rel -match '^(.+)/index\.html$'){ $loc=($Base.TrimEnd('/') + '/' + $matches[1] + '/') }
    else { $loc=($Base.TrimEnd('/') + '/' + $rel) }
    $loc=Collapse-DoubleSlashesPreserveSchemeLocal $loc
    $last=(Get-Item $_.FullName).LastWriteTime.ToString('yyyy-MM-dd')
    $urls.Add([pscustomobject]@{loc=$loc; lastmod=$last}) | Out-Null
  }
$sitemapPath = Join-Path $RootDir 'sitemap.xml'
$xml = New-Object Text.StringBuilder
[void]$xml.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
[void]$xml.AppendLine('<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">')
foreach($u in $urls|Sort-Object loc){ [void]$xml.AppendLine("  <url><loc>$($u.loc)</loc><lastmod>$($u.lastmod)</lastmod></url>") }
[void]$xml.AppendLine('</urlset>')
Set-Content -Encoding UTF8 $sitemapPath $xml.ToString()
Write-Host "[ASD] sitemap.xml generated ($($urls.Count) urls)"

# ---- Feeds ----
$feedPath = Join-Path $RootDir 'feed.xml'
Build-Rss -posts $AllPosts -base $Base -title $Brand -desc $Desc -outPath $feedPath -maxItems 20
$atomPath = Join-Path $RootDir 'atom.xml'
Build-Atom -posts $AllPosts -base $Base -title $Brand -outPath $atomPath -maxItems 20
Write-Host "[ASD] feed.xml + atom.xml generated"

# ---- Search index ----
Build-SearchIndex -posts $AllPosts -rootDir $RootDir
Write-Host "[ASD] assets/search-index.json generated"

# ---- robots.txt (single Sitemap line) ----
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
$robots = [regex]::Replace($robots,'(?im)^\s*Sitemap:\s*.*\r?\n?','')
$absMap = if ($Base -match '^[a-z]+://'){ (New-Object Uri((New-Object Uri($Base)),'sitemap.xml')).AbsoluteUri } else { 'sitemap.xml' }
if ($robots -notmatch "\r?\n$"){ $robots += "`r`n" }
$robots += "Sitemap: $absMap`r`n"
Set-Content -Encoding UTF8 $robotsPath $robots
Write-Host "[ASD] robots.txt: Sitemap -> $absMap"

Write-Host "[ASD] Done."
