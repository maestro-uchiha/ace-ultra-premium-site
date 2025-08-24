<# 
  update-post.ps1
  Update an existing blog post:
    -Slug (required)
    -Title (optional)
    -Description (optional)
    -BodyHtml (optional)   -> replaces the content between ASD markers
    -Author  (optional)    -> upserts <meta name="author">
  Ensures ASD markers exist. PS 5.1 safe. Uses config.json for defaults when needed.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Slug,
  [string]$Title,
  [string]$Description,
  [string]$BodyHtml,
  [string]$Author
)

. (Join-Path $PSScriptRoot "_lib.ps1")
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

# default author if we need to create the meta tag and no Author was passed
$defaultAuthor = 'Maestro'
function HtmlEscape([string]$s) {
  if ($null -eq $s) { return "" }
  $s = $s -replace '&','&amp;'
  $s = $s -replace '<','&lt;'
  $s = $s -replace '>','&gt;'
  $s = $s -replace '"','&quot;'
  return $s
}

$postPath = Join-Path $S.Blog ($Slug + ".html")
if (-not (Test-Path $postPath)) { Write-Error "Post not found: $postPath"; exit 1 }

$html = Get-Content $postPath -Raw

# Ensure ASD markers exist around the main body
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

# Update <title>
if ($PSBoundParameters.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($Title)) {
  $html = [regex]::Replace(
    $html,
    '(?is)(<title>)(.*?)(</title>)',
    { param($m) $m.Groups[1].Value + $Title + $m.Groups[3].Value },
    1
  )
}

# Upsert meta description
if ($PSBoundParameters.ContainsKey('Description')) {
  $descEsc = HtmlEscape($Description)
  if ([regex]::IsMatch($html, '(?is)<meta\s+name\s*=\s*"description"[^>]*>')) {
    $html = [regex]::Replace(
      $html,
      '(?is)(<meta\s+name\s*=\s*"description"\s+content\s*=\s*")(.*?)(")',
      { param($m) $m.Groups[1].Value + $descEsc + $m.Groups[3].Value },
      1
    )
  } elseif ($html -match '(?is)</head>') {
    $html = [regex]::Replace($html, '(?is)</head>', ("  <meta name=""description"" content=""$descEsc"">`r`n</head>"), 1)
  }
}

# Replace the content between markers if BodyHtml provided
if ($PSBoundParameters.ContainsKey('BodyHtml')) {
  $newSeg = @"
<!-- ASD:CONTENT_START -->
$BodyHtml
<!-- ASD:CONTENT_END -->
"@
  $html = [regex]::Replace(
    $html,
    '(?is)<!--\s*ASD:CONTENT_START\s*-->.*?<!--\s*ASD:CONTENT_END\s*-->',
    { param($m) $newSeg },
    1
  )
}

# Update first <h1> in the marker block if Title provided
if ($PSBoundParameters.ContainsKey('Title') -and -not [string]::IsNullOrWhiteSpace($Title)) {
  $html = [regex]::Replace(
    $html,
    '(?is)(<!--\s*ASD:CONTENT_START\s*-->)(.*?)(<!--\s*ASD:CONTENT_END\s*-->)',
    {
      param($m)
      $seg = $m.Groups[2].Value
      if ([regex]::IsMatch($seg, '(?is)<h1[^>]*>.*?</h1>')) {
        $seg = [regex]::Replace(
          $seg,
          '(?is)(<h1[^>]*>)(.*?)(</h1>)',
          { param($mm) $mm.Groups[1].Value + $Title + $mm.Groups[3].Value },
          1
        )
      } else {
        $seg = ("<h1>" + $Title + "</h1>`r`n" + $seg)
      }
      return $m.Groups[1].Value + $seg + $m.Groups[3].Value
    },
    1
  )
}

# Upsert meta author only if -Author was provided; otherwise leave as-is
if ($PSBoundParameters.ContainsKey('Author')) {
  $authorToUse = if (-not [string]::IsNullOrWhiteSpace($Author)) { $Author } else {
    # if Author was provided but blank, still fall back
    if ($cfg -ne $null) {
      if ($cfg.PSObject.Properties.Name -contains 'AuthorName' -and -not [string]::IsNullOrWhiteSpace($cfg.AuthorName)) {
        $cfg.AuthorName
      } elseif ($cfg.PSObject.Properties.Name -contains 'author' -and $cfg.author -ne $null) {
        if ($cfg.author.PSObject.Properties.Name -contains 'name' -and -not [string]::IsNullOrWhiteSpace($cfg.author.name)) {
          $cfg.author.name
        } elseif ($cfg.author.PSObject.Properties.Name -contains 'Name' -and -not [string]::IsNullOrWhiteSpace($cfg.author.Name)) {
          $cfg.author.Name
        } else { $defaultAuthor }
      } else { $defaultAuthor }
    } else { $defaultAuthor }
  }
  $authorEsc = HtmlEscape($authorToUse)

  if ([regex]::IsMatch($html, '(?is)<meta\s+name\s*=\s*"author"[^>]*>')) {
    $html = [regex]::Replace(
      $html,
      '(?is)(<meta\s+name\s*=\s*"author"\s+content\s*=\s*")(.*?)(")',
      { param($m) $m.Groups[1].Value + $authorEsc + $m.Groups[3].Value },
      1
    )
  } elseif ($html -match '(?is)</head>') {
    $html = [regex]::Replace($html, '(?is)</head>', ("  <meta name=""author"" content=""$authorEsc"">`r`n</head>"), 1)
  }
}

Set-Content -Encoding UTF8 $postPath $html
Write-Host "[ASD] Updated blog\$Slug.html (markers ensured)"
