<# 
  update-post.ps1
  Update an existing blog post:
    -Slug (required)
    -Title (optional)
    -Description (optional)
    -BodyHtml (optional)   -> replaces the content between ASD markers
  Ensures ASD markers exist. PS 5.1 safe. Uses config.json only for defaults.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Slug,
  [string]$Title,
  [string]$Description,
  [string]$BodyHtml
)

# Load config
$__here = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")
$__cfg   = Get-ASDConfig
$Brand   = $__cfg.SiteName
$Money   = $__cfg.StoreUrl
$Desc    = $__cfg.Description
$Base    = $__cfg.BaseUrl
$__paths = Get-ASDPaths

Set-StrictMode -Version Latest

. "$PSScriptRoot\_lib.ps1"
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

$postPath = Join-Path $S.Blog ($Slug + ".html")
if (-not (Test-Path $postPath)) { Write-Error "Post not found: $postPath"; exit 1 }

$html = Get-Content $postPath -Raw

# Ensure ASD markers
$hasMarkers = [regex]::IsMatch($html, '(?is)<!--\s*ASD:CONTENT_START\s*-->.*<!--\s*ASD:CONTENT_END\s*-->')
if (-not $hasMarkers) {
  $bodyMatch = [regex]::Match($html, '(?is)<body[^>]*>(.*?)</body>')
  $inside = if ($bodyMatch.Success) { $bodyMatch.Groups[1].Value } else { $html }
  $seg = @"
<!-- ASD:CONTENT_START -->
$inside
<!-- ASD:CONTENT_END -->
"@
  if ($bodyMatch.Success) {
    $html = $html.Substring(0, $bodyMatch.Index) + "<body>`r`n$seg`r`n</body>" + $html.Substring($bodyMatch.Index + $bodyMatch.Length)
  } else {
    $html = $seg
  }
}

# Update <title> if provided
if ($Title) {
  if ([regex]::IsMatch($html, '(?is)<title>.*?</title>')) {
    $html = [regex]::Replace($html, '(?is)(<title>).*?(</title>)', ('$1' + [regex]::Escape($Title) + '$2'))
    $html = [regex]::Unescape($html) # only for the inserted title
  } else {
    # insert before </head> if possible
    if ($html -match '(?is)</head>') {
      $html = [regex]::Replace($html, '(?is)</head>', ("  <title>" + $Title + "</title>`r`n</head>"), 1)
    }
  }
}

# Update meta description if provided (upsert)
if ($Description) {
  if ([regex]::IsMatch($html, '(?is)<meta\s+name\s*=\s*"description"[^>]*>')) {
    $html = [regex]::Replace($html,
      '(?is)(<meta\s+name\s*=\s*"description"\s+content\s*=\s*")[^"]*(")',
      ('$1' + [regex]::Escape($Description) + '$2'))
    $html = [regex]::Unescape($html)
  } else {
    if ($html -match '(?is)</head>') {
      $html = [regex]::Replace($html, '(?is)</head>', ("  <meta name=""description"" content=""" + $Description + """>`r`n</head>"), 1)
    }
  }
}

# Replace the content between markers if BodyHtml provided
if ($BodyHtml) {
  $newSeg = @"
<!-- ASD:CONTENT_START -->
$BodyHtml
<!-- ASD:CONTENT_END -->
"@
  $html = [regex]::Replace($html, '(?is)<!--\s*ASD:CONTENT_START\s*-->.*?<!--\s*ASD:CONTENT_END\s*-->', [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $newSeg })
}

# Also update first <h1> inside the marker block if Title provided
if ($Title) {
  $html = [regex]::Replace(
    $html,
    '(?is)(<!--\s*ASD:CONTENT_START\s*-->)(.*?)(<!--\s*ASD:CONTENT_END\s*-->)',
    {
      param($m)
      $seg = $m.Groups[2].Value
      if ([regex]::IsMatch($seg, '(?is)<h1[^>]*>.*?</h1>')) {
        $seg = [regex]::Replace($seg, '(?is)(<h1[^>]*>).*?(</h1>)', ('$1' + [regex]::Escape($Title) + '$2'), 1)
        $seg = [regex]::Unescape($seg)
      } else {
        $seg = ("<h1>" + $Title + "</h1>`r`n" + $seg)
      }
      return $m.Groups[1].Value + $seg + $m.Groups[3].Value
    },
    1
  )
}

Set-Content -Encoding UTF8 $postPath $html
Write-Host "[ASD] Updated blog\$Slug.html (markers ensured)"
