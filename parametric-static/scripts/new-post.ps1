# ============================================
#  ASD new-post.ps1
#  Creates blog/<slug>.html and regenerates feed.xml
#  Uses _lib.ps1 (config.json as the single source of truth)
#  PS 5.1 compatible; ASCII only
# ============================================

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)][string]$Title,
  [Parameter(Mandatory=$true)][string]$Slug,
  [string]$Description = "",
  [datetime]$Date = (Get-Date)   # <-- for test-wizard compatibility
)

# Load library
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here "_lib.ps1")

Write-Host "[Amaterasu Static Deploy] Version ASD 1.0.0"
Write-Host "[ASD] New post workflow starting..."

$paths = Get-ASDPaths
$cfg   = Get-ASDConfig

if (-not (Test-Path $paths.Blog))   { New-Item -ItemType Directory -Force -Path $paths.Blog   | Out-Null }
if (-not (Test-Path $paths.Drafts)) { New-Item -ItemType Directory -Force -Path $paths.Drafts | Out-Null }

# Target file
$postPath = Join-Path $paths.Blog ($Slug + ".html")
if (Test-Path $postPath) {
  Write-Error "Post already exists: $postPath"
  exit 1
}

if ([string]::IsNullOrWhiteSpace($Description)) { $Description = $cfg.Description }

# Timestamps
$iso = $Date.ToString("yyyy-MM-ddTHH:mm:sszzz")
$day = $Date.ToString("yyyy-MM-dd")

# Basic HTML stub with ASD markers
$html = @"
<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$Title</title>
  <meta name="description" content="$Description">
  <meta name="author" content="$($cfg.AuthorName)">
</head>
<body>
<!-- ASD:CONTENT_START -->
<main>
  <h1>$Title</h1>
  <p class="meta">$day</p>
  <div class="body">
    <p>Write your post content here...</p>
  </div>
</main>
<!-- ASD:CONTENT_END -->
</body>
</html>
"@

Set-Content -Encoding UTF8 $postPath $html

# Set file times so feeds/pagination sort by the provided -Date
try {
  (Get-Item $postPath).LastWriteTime = $Date
  (Get-Item $postPath).CreationTime  = $Date
} catch { }

Write-Host "[ASD] Created blog\$($Slug).html"

# Rebuild feed.xml from files in /blog
function Write-ASDFeed {
  param(
    [Parameter(Mandatory=$true)][object]$Cfg,
    [Parameter(Mandatory=$true)][object]$Paths
  )

  $base = Ensure-AbsoluteBaseUrl $Cfg.BaseUrl
  $items = @()

  Get-ChildItem -Path $Paths.Blog -Filter *.html -File |
    Where-Object { $_.Name -ne "index.html" -and $_.Name -notmatch '^page-\d+\.html$' } |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object {
      $raw = Get-Content $_.FullName -Raw
      $mt  = [regex]::Match($raw, '(?is)<title>(.*?)</title>')
      $mh1 = [regex]::Match($raw, '(?is)<h1[^>]*>(.*?)</h1>')
      $title = if ($mt.Success) { $mt.Groups[1].Value } elseif ($mh1.Success) { $mh1.Groups[1].Value } else { $_.BaseName }
      $rel   = "blog/" + $_.Name
      if ($_.Name -ieq "index.html") { $rel = "" }
      $loc   = if ($base -eq "/") { "/" + $rel } else { ($base.TrimEnd('/') + "/" + $rel) }
      $pub   = $_.LastWriteTime.ToString("r")
      $items += [pscustomobject]@{ title=$title; link=$loc; pub=$pub }
    }

  $feedPath = Join-Path $Paths.Root "feed.xml"
  $sb = New-Object System.Text.StringBuilder
  [void]$sb.AppendLine('<?xml version="1.0" encoding="UTF-8"?>')
  [void]$sb.AppendLine('<rss version="2.0">')
  [void]$sb.AppendLine('  <channel>')
  [void]$sb.AppendLine("    <title>$($Cfg.SiteName)</title>")
  [void]$sb.AppendLine("    <link>$base</link>")
  [void]$sb.AppendLine("    <description>$($Cfg.Description)</description>")
  foreach($i in $items){
    [void]$sb.AppendLine("    <item>")
    [void]$sb.AppendLine("      <title>$($i.title)</title>")
    [void]$sb.AppendLine("      <link>$($i.link)</link>")
    [void]$sb.AppendLine("      <pubDate>$($i.pub)</pubDate>")
    [void]$sb.AppendLine("    </item>")
  }
  [void]$sb.AppendLine('  </channel>')
  [void]$sb.AppendLine('</rss>')

  Set-Content -Encoding UTF8 $feedPath $sb.ToString()
  Write-Host "[ASD] feed.xml updated"
}

Write-ASDFeed -Cfg $cfg -Paths $paths

Write-Host ""
Write-Host "[ASD] Next (manual):"
Write-Host "  .\parametric-static\scripts\bake.ps1"
