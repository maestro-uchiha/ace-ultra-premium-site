<#
  new-post.ps1
  Create a new blog post with ASD markers and update feed.xml.
  - PowerShell 5.1 compatible
  - Reads config.json via _lib.ps1 (single source of truth)
  - Prompts for Author with default from config.json
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory=$true)] [string]$Title,
  [Parameter(Mandatory=$true)] [string]$Slug,
  [string]$Description = "",
  [datetime]$Date = (Get-Date),
  [string]$Author # optional; if omitted, we'll prompt with default
)

# --- load lib/config ---
$ScriptsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptsDir "_lib.ps1")

$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

function Get-DefaultAuthor([object]$cfgObj) {
  $fallback = "ASD"
  if ($cfgObj -eq $null) { return $fallback }
  if ($cfgObj.PSObject.Properties.Name -contains 'AuthorName' -and -not [string]::IsNullOrWhiteSpace($cfgObj.AuthorName)) {
    return $cfgObj.AuthorName
  }
  if ($cfgObj.PSObject.Properties.Name -contains 'author' -and $cfgObj.author -ne $null) {
    if ($cfgObj.author.PSObject.Properties.Name -contains 'name' -and -not [string]::IsNullOrWhiteSpace($cfgObj.author.name)) {
      return $cfgObj.author.name
    }
    if ($cfgObj.author.PSObject.Properties.Name -contains 'Name' -and -not [string]::IsNullOrWhiteSpace($cfgObj.author.Name)) {
      return $cfgObj.author.Name
    }
  }
  return $fallback
}

# -------- sanitize slug --------
$slug = $Slug
if ($slug) { $slug = $slug.Trim().ToLower() }
$slug = $slug -replace '\s+','-'
$slug = $slug -replace '[^a-z0-9\-]',''
if ([string]::IsNullOrWhiteSpace($slug)) { throw "Slug became empty after sanitization." }

# -------- author name (prompt with default) --------
$defaultAuthor = Get-DefaultAuthor $cfg
if ([string]::IsNullOrWhiteSpace($Author)) {
  # interactive prompt with default (Enter to accept)
  try {
    $ans = Read-Host ("Author name [{0}]" -f $defaultAuthor)
    if ([string]::IsNullOrWhiteSpace($ans)) { $Author = $defaultAuthor } else { $Author = $ans }
  } catch {
    # non-interactive fallback
    $Author = $defaultAuthor
  }
}
$authorName = $Author

# -------- Paths / ensure blog dir --------
$blogDir = $S.Blog
New-Item -ItemType Directory -Force -Path $blogDir | Out-Null
$outPath = Join-Path $blogDir ($slug + ".html")
if (Test-Path $outPath) { Write-Error "Post already exists: $outPath"; exit 1 }

# -------- Compose HTML with SAFE ASD block markers --------
$titleText = $Title.Trim()
$descText  = if ([string]::IsNullOrWhiteSpace($Description)) { "A new post on $($cfg.SiteName)." } else { $Description }
$dateIso   = $Date.ToString('yyyy-MM-dd')

# Escape quotes for the description attribute
$descAttr = $descText -replace '"','&quot;'
$authorAttr = $authorName -replace '"','&quot;'

$html = @"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="utf-8">

  <!-- ASD:TITLE:START -->
  <title>$titleText</title>
  <!-- ASD:TITLE:END -->

  <!-- ASD:DESC:START -->
  <meta name="description" content="$descAttr">
  <!-- ASD:DESC:END -->

  <meta name="author" content="$authorAttr">
  <meta name="date" content="$dateIso">
</head>
<body>
<main>
  <!-- ASD:BODY:START -->
  <article>
    <h1>$titleText</h1>
    <p><em>$dateIso</em></p>
    <p>Write your post here…</p>
  </article>
  <!-- ASD:BODY:END -->
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
