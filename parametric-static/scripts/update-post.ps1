param(
  [Parameter(Mandatory=$true)][string]$Slug,
  [string]$Title,
  [string]$Description,
  [string]$BodyPath,
  [string]$Date,
  [switch]$TouchFileTime
)

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root

function Get-Domain {
  if (Test-Path ".\config.json") {
    try {
      $cfg = Get-Content .\config.json -Raw | ConvertFrom-Json
      if ($cfg.site.url) { return ($cfg.site.url.TrimEnd('/') + '/') }
    } catch {}
  }
  return "https://YOUR-DOMAIN.example/"
}

function Read-BodyHtml([string]$path) {
  if (-not $path -or -not (Test-Path $path)) { return $null }
  $ext = [IO.Path]::GetExtension($path).ToLower()
  if ($ext -eq ".html") { return (Get-Content $path -Raw) }
  if ($ext -eq ".md") {
    $md = Get-Content $path -Raw
    $md = ($md -split "`r?`n") -join "`n"
    $md = $md -replace '^# (.+)$', '<h1>$1</h1>'
    $md = $md -replace '^## (.+)$', '<h2>$1</h2>'
    $md = $md -replace '^\* (.+)$', '<li>$1</li>'
    $blocks = $md -split "`n`n"
    $htmlBlocks = foreach($b in $blocks){
      if ($b -match '^\s*<h\d|^\s*<li') { $b } else { "<p>$($b -replace "`n","<br>")</p>" }
    }
    return (($htmlBlocks -join "`n").Trim())
  }
  return $null
}

function Build-JsonLd([string]$dom, [string]$slug, [string]$ttl, [string]$dt, [string]$desc) {
  $postUrl = ($dom.TrimEnd('/') + "/blog/$slug.html")
@"
<script type="application/ld+json">
{
  "@context":"https://schema.org",
  "@type":"BlogPosting",
  "headline":"$ttl",
  "datePublished":"$dt",
  "dateModified":"$dt",
  "author":{"@type":"Organization","name":"{{BRAND}}"},
  "publisher":{"@type":"Organization","name":"{{BRAND}}"},
  "mainEntityOfPage":{"@type":"WebPage","@id":"$postUrl"},
  "image":"$($dom.TrimEnd('/'))/assets/img/og.jpg",
  "description":"$desc"
}
</script>
<script type="application/ld+json">
{
  "@context":"https://schema.org",
  "@type":"BreadcrumbList",
  "itemListElement":[
    {"@type":"ListItem","position":1,"name":"Home","item":"$($dom)"},
    {"@type":"ListItem","position":2,"name":"Blog","item":"$($dom)blog/"},
    {"@type":"ListItem","position":3,"name":"$ttl","item":"$postUrl"}
  ]
}
</script>
"@
}

$postPath = Join-Path $Root ("blog\" + $Slug + ".html")
if (-not (Test-Path $postPath)) { Write-Error "Post not found: $postPath"; exit 1 }

$raw = Get-Content $postPath -Raw
$dom = Get-Domain

# Extract editable content block
$mx = [regex]::Match($raw, '(?is)<!--\s*ASD:CONTENT_START\s*-->(.*?)<!--\s*ASD:CONTENT_END\s*-->')
if (-not $mx.Success) { Write-Error "ASD content markers not found in $postPath"; exit 1 }
$content = $mx.Groups[1].Value

# Current values
if (-not $Title) {
  $mH1 = [regex]::Match($content, '(?is)<h1[^>]*>(.*?)</h1>')
  $Title = if ($mH1.Success) { $mH1.Groups[1].Value } else { $Slug }
}
if (-not $Date) {
  $mMeta = [regex]::Match($content, '(?is)<p\s+class="meta">\s*([^<&]+)\s*&')
  $Date = if ($mMeta.Success) { $mMeta.Groups[1].Value.Trim() } else { (Get-Date -Format 'yyyy-MM-dd') }
}
if (-not $Description) { $Description = "Updated: $Title" }

# Optional new body
$bodyHtml = Read-BodyHtml $BodyPath

# 1) Update <h1>
$h1rx = New-Object System.Text.RegularExpressions.Regex('<h1[^>]*>.*?</h1>', 'Singleline,IgnoreCase')
if ($h1rx.IsMatch($content)) { $content = $h1rx.Replace($content, "<h1>$Title</h1>", 1) }
else { $content = "<h1>$Title</h1>`n" + $content }

# 2) Update meta date
$content = [regex]::Replace($content, '(?is)<p\s+class="meta">.*?</p>', "<p class=""meta"">$Date &middot; <a href=""{{MONEY}}"">{{MONEY}}</a></p>", 1)

# 3) Update article body (if provided)
if ($bodyHtml) {
  $articleRx = New-Object System.Text.RegularExpressions.Regex('<article[^>]*class="prose"[^>]*>.*?</article>', 'Singleline,IgnoreCase')
  if ($articleRx.IsMatch($content)) {
    $content = $articleRx.Replace($content, "<article class=""prose"">$bodyHtml</article>", 1)
  } else {
    $content += "`n<article class=""prose"">$bodyHtml</article>"
  }
}

# 4) Replace all ld+json blocks with fresh ones
$content = [regex]::Replace($content, '(?is)<script[^>]*type="application/ld\+json"[^>]*>.*?</script>', '')
$content = $content.Trim() + "`n" + (Build-JsonLd -dom $dom -slug $Slug -ttl $Title -dt $Date -desc $Description)

# Write back within markers
$new = $raw.Substring(0, $mx.Groups[1].Index) + $content + $raw.Substring($mx.Groups[1].Index + $mx.Groups[1].Length)
Set-Content -Encoding UTF8 $postPath $new
Write-Host "[ASD] Updated blog/$Slug.html"

# Touch file timestamp (optional, affects blog index order)
if ($TouchFileTime -and $Date) {
  try { $(Get-Item $postPath).LastWriteTime = [datetime]::Parse($Date) } catch {}
}

# Update feed.xml item
$feedPath = Join-Path $Root "feed.xml"
if (Test-Path $feedPath) {
  try {
    [xml]$rss = Get-Content $feedPath
    $chan = $rss.rss.channel
    $postUrl = ($dom.TrimEnd('/') + "/blog/$Slug.html")
    $found = $false
    foreach($it in $chan.item) {
      if ($it.link -and $it.link -eq $postUrl) {
        if ($Title) { $it.title = $Title }
        if ($Description) { $it.description = $Description }
        if ($Date) { $it.pubDate = ([DateTime]::Parse($Date)).ToUniversalTime().ToString("R") }
        $found = $true
      }
    }
    if (-not $found) {
      $item = $rss.CreateElement("item")
      $t = $rss.CreateElement("title"); $t.InnerText = $Title; $null = $item.AppendChild($t)
      $l = $rss.CreateElement("link");  $l.InnerText = $postUrl; $null = $item.AppendChild($l)
      $g = $rss.CreateElement("guid");  $g.InnerText = $postUrl; $null = $item.AppendChild($g)
      $d = $rss.CreateElement("pubDate"); $d.InnerText = [DateTime]::UtcNow.ToString("R"); $null = $item.AppendChild($d)
      $desc = $rss.CreateElement("description"); $desc.InnerText = $Description; $null = $item.AppendChild($desc)
      $null = $chan.AppendChild($item)
    }
    $rss.Save($feedPath)
    Write-Host "[ASD] feed.xml updated"
  } catch { Write-Warning "[ASD] Could not update feed.xml: $_" }
}

# --- Friendly manual-next-step hint (does not execute bake)
$brandHint = "Your Brand"
$moneyHint = "https://your-domain.com"
try {
  if ($cfg) {
    if ($cfg.site -and $cfg.site.name) { $brandHint = $cfg.site.name }
    elseif ($cfg.brand) { $brandHint = $cfg.brand }
    if ($cfg.moneySite) { $moneyHint = $cfg.moneySite }
  }
} catch {}

Write-Host "`n[ASD] Next (manual):"
Write-Host ("  .\parametric-static\scripts\bake.ps1 -Brand ""{0}"" -Money ""{1}""" -f $brandHint, $moneyHint)