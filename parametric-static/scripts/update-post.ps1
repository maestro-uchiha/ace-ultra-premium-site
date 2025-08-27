<#
  update-post.ps1
  Update an existing blog post:
    -Slug (required)
    -Title (optional)
    -Description (optional)
    -BodyHtml (optional)   -> replaces the content between ASD markers
    -Author  (optional)    -> upserts <meta name="author">
  Hardened to tolerate buggy positional calls ("-Slug" "value" …).
  Also syncs ASD:DESCRIPTION comment with meta description (<=160 chars).
  PS 5.1-safe.
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

# --- helpers ---
$defaultAuthor = 'Maestro'

function HtmlEscape([string]$s) {
  if ($null -eq $s) { return "" }
  $s = $s -replace '&','&amp;'
  $s = $s -replace '<','&lt;'
  $s = $s -replace '>','&gt;'
  $s = $s -replace '"','&quot;'
  return $s
}
function Normalize-Slug([string]$s) {
  if ([string]::IsNullOrWhiteSpace($s)) { return $s }
  $s = $s.Trim()
  # accept incoming "-Slug" bug and correct via shifting handled below
  # strip any directories and extension
  $name = [IO.Path]::GetFileName($s)
  if ($name -like '*.html') { $name = [IO.Path]::GetFileNameWithoutExtension($name) }
  return $name
}
function OneLine160([string]$s) {
  if ($null -eq $s) { return "" }
  $t = ($s -replace '\s+',' ').Trim()
  if ($t.Length -gt 160) { $t = $t.Substring(0,160) }
  return $t
}

# --- tolerate buggy positional usage: "-Slug" "value" "-Title" "value" ---
# If first arg arrived as the literal "-Slug", shift values left so $Slug becomes the next value.
# This happens when a caller uses: & update-post.ps1 "-Slug" $slug "-Title" $title ...
if ($Slug -eq '-Slug' -and -not [string]::IsNullOrWhiteSpace($Title)) {
  # Shift: Slug <- Title; Title <- Description; Description <- BodyHtml; BodyHtml <- Author; Author <- $null
  $Slug        = $Title
  $Title       = $Description
  $Description = $BodyHtml
  $BodyHtml    = $Author
  $Author      = $null
}

# Final slug normalization (handles .html, paths, etc.)
$Slug = Normalize-Slug $Slug

# Resolve path and friendly error if missing
$postPath = Join-Path $S.Blog ($Slug + ".html")
if (-not (Test-Path $postPath)) {
  Write-Error "Post not found: $postPath"
  # Suggest nearby matches to help the user
  $candidates = Get-ChildItem -Path $S.Blog -Filter '*.html' -File | Select-Object -ExpandProperty Name
  $hint = ($candidates | Where-Object { $_ -like "*$Slug*" } | Select-Object -First 5) -join ', '
  if (-not [string]::IsNullOrWhiteSpace($hint)) {
    Write-Host "[ASD] Did you mean one of: $hint"
  }
  exit 1
}

# Load the file
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
  if ([regex]::IsMatch($html, '(?is)<title>.*?</title>')) {
    $html = [regex]::Replace(
      $html,
      '(?is)(<title>)(.*?)(</title>)',
      { param($m) $m.Groups[1].Value + $Title + $m.Groups[3].Value },
      1
    )
  } elseif ($html -match '(?is)</head>') {
    $html = [regex]::Replace($html, '(?is)</head>', ("  <title>$Title</title>`r`n</head>"), 1)
  }
}

# Upsert meta description (head) and ASD:DESCRIPTION (inside content) when -Description provided
if ($PSBoundParameters.ContainsKey('Description')) {
  $descTidy = OneLine160 $Description
  $descEsc  = HtmlEscape $descTidy

  # 1) <meta name="description" ...> in <head>
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

  # 2) ASD:DESCRIPTION comment inside marker block (just before end)
  $html = [regex]::Replace(
    $html,
    '(?is)(<!--\s*ASD:CONTENT_START\s*-->)(.*?)(<!--\s*ASD:CONTENT_END\s*-->)',
    {
      param($m)
      $seg = $m.Groups[2].Value
      if ([regex]::IsMatch($seg, '(?is)<!--\s*ASD:DESCRIPTION:')) {
        $seg = [regex]::Replace($seg, '(?is)<!--\s*ASD:DESCRIPTION:\s*.*?-->', '<!-- ASD:DESCRIPTION: ' + $descTidy + ' -->', 1)
      } else {
        # insert right before end marker, keeping things tidy
        if ($seg -notmatch '\r?\n$') { $seg += "`r`n" }
        $seg += '<!-- ASD:DESCRIPTION: ' + $descTidy + ' -->' + "`r`n"
      }
      return $m.Groups[1].Value + $seg + $m.Groups[3].Value
    },
    1
  )
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
Write-Host "[ASD] Updated blog\$Slug.html (markers ensured; description synced)"
