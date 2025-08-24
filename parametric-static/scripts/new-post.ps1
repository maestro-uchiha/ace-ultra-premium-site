<# 
  new-post.ps1
  Create a new blog post with ASD markers and update feed.xml.
  - PowerShell 5.1 compatible
  - Reads config.json via _lib.ps1 (single source of truth)
  - Outputs pretty, structured markup that looks good with your styles.css
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$Title,
  [Parameter(Mandatory=$true)] [string]$Slug,
  [string]$Description = "",
  [datetime]$Date = (Get-Date),
  [string]$Author
)

# Load helpers / config
. "$PSScriptRoot\_lib.ps1"
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

# -------- Resolve author name (config first, then param, then default) --------
function Get-AuthorFromConfig([object]$c){
  if ($null -eq $c) { return $null }
  # flat
  if ($c.PSObject.Properties.Name -contains 'AuthorName' -and -not [string]::IsNullOrWhiteSpace($c.AuthorName)) {
    return $c.AuthorName
  }
  # nested
  if ($c.PSObject.Properties.Name -contains 'author' -and $c.author -ne $null) {
    foreach($k in 'name','Name'){
      if ($c.author.PSObject.Properties.Name -contains $k) {
        $v = $c.author.$k
        if (-not [string]::IsNullOrWhiteSpace($v)) { return $v }
      }
    }
  }
  return $null
}
$authorDefault = (Get-AuthorFromConfig $cfg)
if ([string]::IsNullOrWhiteSpace($authorDefault)) { $authorDefault = 'Maestro' }
$authorName = if (-not [string]::IsNullOrWhiteSpace($Author)) { $Author } else { $authorDefault }

# -------- Sanitize slug --------
$slug = $Slug
if ($slug) { $slug = $slug.Trim().ToLower() }
$slug = $slug -replace '\s+','-'
$slug = $slug -replace '[^a-z0-9\-]',''
if ([string]::IsNullOrWhiteSpace($slug)) { throw "Slug became empty after sanitization." }

# -------- Paths / ensure blog dir --------
$blogDir = $S.Blog
New-Item -ItemType Directory -Force -Path $blogDir | Out-Null
$outPath = Join-Path $blogDir ($slug + ".html")
if (Test-Path $outPath) { Write-Error "Post already exists: $outPath"; exit 1 }

# -------- Compose HTML (no ASD markers in <title>/<meta>, markers only around content) --------
$titleText = $Title.Trim()
$descText  = $Description
$dateIso   = $Date.ToString('yyyy-MM-dd')

# NOTE: layout.html + bake.ps1 take the first <h1> inside content as the page title.
# We keep a simple <title> for raw files; it will be replaced during bake.
$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <title>$titleText</title>
  <meta name="description" content="$descText">
  <meta name="author" content="$authorName">
  <meta name="date" content="$dateIso">
</head>
<body>
<main>
  <!-- ASD:CONTENT_START -->
  <article class="post">
    <header class="post-head">
      <h1>$titleText</h1>
      <p class="muted">By $authorName &bull; <time datetime="$dateIso">$dateIso</time></p>
    </header>

    <div class="post-body">
      <p>Write your post here...</p>
    </div>

    <footer class="post-foot muted">
      <hr>
      <p>Tags: <em>none</em></p>
    </footer>
  </article>
  <!-- ASD:CONTENT_END -->
</main>
</body>
</html>
"@

Set-Content -Encoding UTF8 -Path $outPath -Value $html
Write-Host "[ASD] Created blog\$slug.html"

# -------- Update (or create) a simple feed.xml --------
$feedPath = Join-Path $S.Root "feed.xml"
if (-not (Test-Path $feedPath)) {
  $feedInit = @"
<?xml version="1.0" encoding="utf-8"?>
<feed>
  <updated>$(Get-Date -Format o)</updated>
</feed>
"@
  Set-Content -Encoding UTF8 -Path $feedPath -Value $feedInit
} else {
  try {
    $feed = Get-Content -Raw -ErrorAction Stop $feedPath
  } catch {
    $feed = ""
  }
  if ($feed -match '<updated>.*?</updated>') {
    $feed = [regex]::Replace($feed, '<updated>.*?</updated>', ('<updated>' + (Get-Date -Format o) + '</updated>'))
  } else {
    $feed += "`n<updated>$(Get-Date -Format o)</updated>`n"
  }
  Set-Content -Encoding UTF8 -Path $feedPath -Value $feed
}
Write-Host "[ASD] feed.xml updated"

Write-Host ""
Write-Host "[ASD] Next:"
Write-Host "  .\parametric-static\scripts\bake.ps1"
