param(
  [Parameter(Mandatory=$true)][string]$Slug,
  [string]$Title,
  [string]$Description,
  [Alias('BodyHtml','Body')][string]$BodyText,
  [string]$BodyPath
)

$ErrorActionPreference = 'Stop'

# ==== paths ====
$here = Split-Path -Parent $PSCommandPath
$root = Split-Path -Parent $here
Set-Location $root

$postRel = "blog\$Slug.html"
$postAbs = Join-Path $root $postRel
if (-not (Test-Path $postAbs)) { Write-Error "Post not found: $postAbs"; exit 1 }

# ==== helpers ====
function Get-InnerContent {
  param([string]$html)
  $m = [regex]::Match($html,'(?is)<!--\s*ASD:CONTENT_START\s*-->(.*?)<!--\s*ASD:CONTENT_END\s*-->')
  if ($m.Success) { return ,@($m.Groups[1].Value,$true) }
  $mm = [regex]::Match($html,'(?is)<main\b[^>]*>(.*?)</main>')
  if ($mm.Success) { return ,@($mm.Groups[1].Value,$false) }
  $mb = [regex]::Match($html,'(?is)<body\b[^>]*>(.*?)</body>')
  if ($mb.Success) {
    $inner = $mb.Groups[1].Value
    $inner = [regex]::Replace($inner,'(?is)<header\b[^>]*>.*?</header>','')
    $inner = [regex]::Replace($inner,'(?is)<nav\b[^>]*>.*?</nav>','')
    $inner = [regex]::Replace($inner,'(?is)<footer\b[^>]*>.*?</footer>','')
    return ,@($inner,$false)
  }
  return ,@($html,$false)
}

function Ensure-Markers {
  param([string]$html,[string]$content)
  if ([regex]::IsMatch($html,'(?is)<!--\s*ASD:CONTENT_START\s*-->')) { return $html }
  $pre  = [regex]::Match($html,'(?is)^(.*?<body[^>]*>)').Groups[1].Value
  $post = [regex]::Match($html,'(?is)(</body>.*)$').Groups[1].Value
  if ($pre -and $post) {
    return ($pre + "`r`n<!-- ASD:CONTENT_START -->`r`n" + $content + "`r`n<!-- ASD:CONTENT_END -->`r`n" + $post)
  }
  return ("<!-- ASD:CONTENT_START -->`r`n" + $content + "`r`n<!-- ASD:CONTENT_END -->")
}

function Replace-BetweenMarkers {
  param([string]$html,[string]$content)
  return [regex]::Replace(
    $html,
    '(?is)(<!--\s*ASD:CONTENT_START\s*-->).*?(<!--\s*ASD:CONTENT_END\s*-->)',
    { param($m) $m.Groups[1].Value + "`r`n" + $content + "`r`n" + $m.Groups[2].Value },
    1
  )
}

function Load-BodyFromPath {
  param([string]$path)
  if ([string]::IsNullOrWhiteSpace($path) -or -not (Test-Path $path)) { return $null }
  $ext = [IO.Path]::GetExtension($path).ToLower()
  if ($ext -eq '.html') { return (Get-Content $path -Raw) }
  if ($ext -eq '.md') {
    $md  = Get-Content $path -Raw
    $md  = ($md -split "`r?`n") -join "`n"
    $md  = $md -replace '^# (.+)$','<h1>$1</h1>'
    $md  = $md -replace '^## (.+)$','<h2>$1</h2>'
    $md  = $md -replace '^\* (.+)$','<li>$1</li>'
    $bl  = $md -split "`n`n"
    $blk = foreach($b in $bl){ if ($b -match '^\s*<h\d|^\s*<li') { $b } else { "<p>$($b -replace "`n","<br>")</p>" } }
    return ($blk -join "`n")
  }
  return $null
}

function Set-HeadTitle {
  param([string]$html,[string]$newTitle)
  if ([string]::IsNullOrWhiteSpace($newTitle)) { return $html }
  $out = $html
  if ($out -match '(?is)<title>.*?</title>') {
    $out = [regex]::Replace($out,'(?is)<title>.*?</title>',"<title>$newTitle</title>",1)
  } elseif ($out -match '(?is)<head\b[^>]*>') {
    $out = [regex]::Replace($out,'(?is)<head\b[^>]*>',{param($m) $m.Value + "`r`n<title>$newTitle</title>"},1)
  }
  if ($out -match '(?is)<meta\s+property=["'']og:title["''][^>]*>') {
    $out = [regex]::Replace($out,'(?is)<meta\s+property=["'']og:title["'']\s+content=["''][^"'']*["'']\s*/?>',"<meta property=`"og:title`" content=`"$newTitle`">",1)
  } elseif ($out -match '(?is)</head>') {
    $out = $out -replace '(?is)</head>',"<meta property=""og:title"" content=""$newTitle"">`r`n</head>",1
  }
  return $out
}

function Set-HeadDescription {
  param([string]$html,[string]$newDesc)
  if ([string]::IsNullOrWhiteSpace($newDesc)) { return $html }
  $out = $html
  if ($out -match '(?is)<meta\s+name=["'']description["''][^>]*>') {
    $out = [regex]::Replace($out,'(?is)<meta\s+name=["'']description["'']\s+content=["''][^"'']*["'']\s*/?>',"<meta name=`"description`" content=`"$newDesc`">",1)
  } elseif ($out -match '(?is)</head>') {
    $out = $out -replace '(?is)</head>',"<meta name=""description"" content=""$newDesc"">`r`n</head>",1
  }
  if ($out -match '(?is)<meta\s+property=["'']og:description["''][^>]*>') {
    $out = [regex]::Replace($out,'(?is)<meta\s+property=["'']og:description["'']\s+content=["''][^"'']*["'']\s*/?>',"<meta property=`"og:description`" content=`"$newDesc`">",1)
  } elseif ($out -match '(?is)</head>') {
    $out = $out -replace '(?is)</head>',"<meta property=""og:description"" content=""$newDesc"">`r`n</head>",1
  }
  return $out
}

# ==== load file & current content ====
$html = Get-Content $postAbs -Raw
$pair = Get-InnerContent $html
$currentContent = $pair[0]
$hadMarkers     = [bool]$pair[1]

# ==== decide new content ====
$newContent = $currentContent
if ($BodyText -and $BodyText.Trim().Length -gt 0) {
  $newContent = $BodyText
} elseif ($BodyPath) {
  $tmp = Load-BodyFromPath $BodyPath
  if ($tmp) { $newContent = $tmp }
}

# Update first <h1> if Title provided, else prepend a new one
if ($Title) {
  if ($newContent -match '(?is)<h1[^>]*>.*?</h1>') {
    $newContent = [regex]::Replace($newContent,'(?is)<h1[^>]*>.*?</h1>',"<h1>$Title</h1>",1)
  } else {
    $newContent = "<h1>$Title</h1>`r`n$newContent"
  }
}

# ==== ensure markers and replace between ====
if (-not $hadMarkers) {
  $html = Ensure-Markers -html $html -content $currentContent
}
$html = Replace-BetweenMarkers -html $html -content $newContent

# ==== head updates ====
if ($Title)       { $html = Set-HeadTitle       -html $html -newTitle $Title }
if ($Description) { $html = Set-HeadDescription -html $html -newDesc  $Description }

# ==== save ====
Set-Content -Encoding UTF8 $postAbs $html
Write-Host "[ASD] Updated $postRel (markers ensured)"
