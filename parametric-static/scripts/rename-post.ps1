param(
  [Parameter(Mandatory=$true)][string]$OldSlug,
  [Parameter(Mandatory=$true)][string]$NewSlug,
  [string]$Title
)

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root

function Get-Domain {
  if (Test-Path ".\config.json") {
    try { $cfg = Get-Content .\config.json -Raw | ConvertFrom-Json; if ($cfg.site.url) { return ($cfg.site.url.TrimEnd('/') + '/') } } catch {}
  }
  return "https://YOUR-DOMAIN.example/"
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

$dom = Get-Domain
$src = Join-Path $Root ("blog\" + $OldSlug + ".html")
$dst = Join-Path $Root ("blog\" + $NewSlug + ".html")
if (-not (Test-Path $src)) { Write-Error "Post not found: $src"; exit 1 }
if (Test-Path $dst) { Write-Error "Target already exists: $dst"; exit 1 }

# Load old content
$raw = Get-Content $src -Raw
$mx = [regex]::Match($raw, '(?is)<!--\s*ASD:CONTENT_START\s*-->(.*?)<!--\s*ASD:CONTENT_END\s*-->')
if (-not $mx.Success) { Write-Error "ASD content markers not found in $src"; exit 1 }
$content = $mx.Groups[1].Value

# Existing title/date/desc
$mH1 = [regex]::Match($content, '(?is)<h1[^>]*>(.*?)</h1>')
$curTitle = if ($mH1.Success) { $mH1.Groups[1].Value } else { $OldSlug }
if ($Title) { $curTitle = $Title }

$mMeta = [regex]::Match($content, '(?is)<p\s+class="meta">\s*([^<&]+)\s*&')
$curDate = if ($mMeta.Success) { $mMeta.Groups[1].Value.Trim() } else { (Get-Date -Format 'yyyy-MM-dd') }

$curDesc = "Updated: $curTitle"

# Update H1 if provided
if ($Title) {
  $h1rx = New-Object System.Text.RegularExpressions.Regex('<h1[^>]*>.*?</h1>', 'Singleline,IgnoreCase')
  if ($h1rx.IsMatch($content)) { $content = $h1rx.Replace($content, "<h1>$Title</h1>", 1) }
  else { $content = "<h1>$Title</h1>`n" + $content }
}

# Replace JSON-LD with fresh blocks reflecting new slug
$content = [regex]::Replace($content, '(?is)<script[^>]*type="application/ld\+json"[^>]*>.*?</script>', '')
$content = $content.Trim() + "`n" + (Build-JsonLd -dom $dom -slug $NewSlug -ttl $curTitle -dt $curDate -desc $curDesc)

# Write to new file
$newRaw = $raw.Substring(0, $mx.Groups[1].Index) + $content + $raw.Substring($mx.Groups[1].Index + $mx.Groups[1].Length)
Set-Content -Encoding UTF8 $dst $newRaw
Remove-Item $src -Force
Write-Host "[ASD] Renamed blog/$OldSlug.html -> blog/$NewSlug.html"

# Update feed.xml link/guid (and title if changed)
$feedPath = Join-Path $Root "feed.xml"
if (Test-Path $feedPath) {
  try {
    [xml]$rss = Get-Content $feedPath
    $chan = $rss.rss.channel
    $oldUrl = ($dom.TrimEnd('/') + "/blog/$OldSlug.html")
    $newUrl = ($dom.TrimEnd('/') + "/blog/$NewSlug.html")
    foreach($it in $chan.item) {
      if ($it.link -and $it.link -eq $oldUrl) {
        $it.link = $newUrl
        if ($it.guid) { $it.guid = $newUrl }
        if ($Title) { $it.title = $curTitle }
      }
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