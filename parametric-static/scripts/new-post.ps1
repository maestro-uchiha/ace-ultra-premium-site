param(
  [Parameter(Mandatory=$true)][string]$Title,
  [string]$Slug,
  [string]$Description = "Short description for this article.",
  [string]$BodyPath,
  [string]$Date = (Get-Date -Format "yyyy-MM-dd")
)

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root

$Version = "(unknown)"
if (Test-Path "$Root\VERSION") { try { $Version = (Get-Content "$Root\VERSION" -Raw).Trim() } catch {} }
Write-Host "[Amaterasu Static Deploy] Version $Version"
Write-Host "[ASD] New post workflow starting…`n"

$Domain = "https://YOUR-DOMAIN.example"
if (Test-Path ".\config.json") {
  try { $cfg = Get-Content .\config.json -Raw | ConvertFrom-Json; if ($cfg.site.url) { $Domain = $cfg.site.url } } catch {}
}

if (-not $Slug -or $Slug.Trim() -eq "") { $Slug = ($Title.ToLower() -replace '[^a-z0-9]+','-').Trim('-') }

$postRel = "blog\$Slug.html"
$postAbs = Join-Path $Root $postRel

$bodyHtml = "<p>Write your content here. Replace this paragraph with your article body.</p>"
if ($BodyPath -and (Test-Path $BodyPath)) {
  $ext = [IO.Path]::GetExtension($BodyPath).ToLower()
  if ($ext -eq ".html") { $bodyHtml = Get-Content $BodyPath -Raw }
  elseif ($ext -eq ".md") {
    $md = Get-Content $BodyPath -Raw
    $md = ($md -split "`r?`n") -join "`n"
    $md = $md -replace '^# (.+)$', '<h1>$1</h1>'
    $md = $md -replace '^## (.+)$', '<h2>$1</h2>'
    $md = $md -replace '^\* (.+)$', '<li>$1</li>'
    $blocks = $md -split "`n`n"
    $htmlBlocks = foreach($b in $blocks){ if ($b -match '^\s*<h\d|^\s*<li') { $b } else { "<p>$($b -replace "`n","<br>")</p>" } }
    $bodyHtml = ($htmlBlocks -join "`n").Trim()
  }
}

$postHtml = @"
<!doctype html>
<html lang="en">
<head>
  <!--#include virtual="partials/head-seo.html" -->
  <title>$Title</title>
  <link rel="canonical" href="$Domain/blog/$Slug.html" />
  <meta name="description" content="$Description" />

  <!-- Auto BlogPosting JSON-LD + breadcrumbs -->
  <script type="application/ld+json">
  {
    "@context":"https://schema.org",
    "@type":"BlogPosting",
    "headline": "$Title",
    "datePublished": "$Date",
    "dateModified": "$Date",
    "author": { "@type":"Organization", "name":"{{BRAND}}" },
    "publisher": { "@type":"Organization", "name":"{{BRAND}}" },
    "mainEntityOfPage": { "@type":"WebPage", "@id":"$Domain/blog/$Slug.html" },
    "image": "https://YOUR-DOMAIN.example/assets/og.jpg"
  }
  </script>
  <script type="application/ld+json">
  {
    "@context":"https://schema.org",
    "@type":"BreadcrumbList",
    "itemListElement":[
      {"@type":"ListItem","position":1,"name":"Home","item":"https://YOUR-DOMAIN.example/"},
      {"@type":"ListItem","position":2,"name":"Blog","item":"$Domain/blog/"},
      {"@type":"ListItem","position":3,"name":"$Title","item":"$Domain/blog/$Slug.html"}
    ]
  }
  </script>
</head>
<body>
  <!--#include virtual="partials/nav.html" -->
  <main class="wrap">
    <h1>$Title</h1>
    <article>
$bodyHtml
    </article>
  </main>
  <!--#include virtual="partials/footer.html" -->
</body>
</html>
"@
$postHtml | Set-Content -Encoding UTF8 $postAbs
Write-Host "[ASD] Created $postRel"

# sitemap.xml
$smapPath = Join-Path $Root "sitemap.xml"
if (Test-Path $smapPath) {
  try {
    [xml]$smap = Get-Content $smapPath
    $url  = $smap.CreateElement("url")
    $loc  = $smap.CreateElement("loc");     $loc.InnerText  = "$Domain/blog/$Slug.html"; $null = $url.AppendChild($loc)
    $last = $smap.CreateElement("lastmod"); $last.InnerText = $Date; $null = $url.AppendChild($last)
    $null = $smap.urlset.AppendChild($url)
    $smap.Save($smapPath)
    Write-Host "[ASD] sitemap.xml updated"
  } catch { Write-Warning "[ASD] Could not update sitemap.xml: $_" }
} else { Write-Warning "[ASD] sitemap.xml not found; skipping" }

# feed.xml
$feedPath = Join-Path $Root "feed.xml"
if (Test-Path $feedPath) {
  try {
    [xml]$rss = Get-Content $feedPath
    $chan = $rss.rss.channel
    if (-not $chan) {
      $rss.LoadXml('<?xml version="1.0" encoding="UTF-8"?><rss version="2.0"><channel><title>Blog</title><link>'+$Domain+'/blog/</link><description>Feed</description></channel></rss>')
      $chan = $rss.rss.channel
    }
    $item = $rss.CreateElement("item")
    $t = $rss.CreateElement("title"); $t.InnerText = $Title; $null = $item.AppendChild($t)
    $l = $rss.CreateElement("link");  $l.InnerText = "$Domain/blog/$Slug.html"; $null = $item.AppendChild($l)
    $g = $rss.CreateElement("guid");  $g.InnerText = "$Domain/blog/$Slug.html"; $null = $item.AppendChild($g)
    $d = $rss.CreateElement("pubDate"); $d.InnerText = [DateTime]::UtcNow.ToString("R"); $null = $item.AppendChild($d)
    $desc = $rss.CreateElement("description"); $desc.InnerText = $Description; $null = $item.AppendChild($desc)
    $null = $chan.AppendChild($item)
    $rss.Save($feedPath)
    Write-Host "[ASD] feed.xml updated"
  } catch { Write-Warning "[ASD] Could not update feed.xml: $_" }
} else { Write-Warning "[ASD] feed.xml not found; skipping" }

Write-Host "`n[ASD] Next: run scripts\bake.bat \"Ace Ultra Premium\" \"https://acecartstore.com\""
