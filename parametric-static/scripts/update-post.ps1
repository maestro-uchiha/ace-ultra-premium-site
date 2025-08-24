<# 
  update-post.ps1
  Update an existing blog post:
    -Slug (required)
    -Title (optional)
    -Description (optional)
    -BodyHtml (optional)   -> replaces the content between ASD BODY markers

  Ensures SAFE ASD markers exist (block-wrapped):
    <!-- ASD:TITLE:START --><title>…</title><!-- ASD:TITLE:END -->
    <!-- ASD:DESC:START --><meta name="description" content="…"><!-- ASD:DESC:END -->
    <!-- ASD:BODY:START --> … <!-- ASD:BODY:END -->

  Also migrates older inline marker styles and ASD:CONTENT_* to ASD:BODY_*.
  PowerShell 5.1 compatible.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Slug,
  [string]$Title,
  [string]$Description,
  [string]$BodyHtml
)

Set-StrictMode -Version Latest

# Load config helpers
$ScriptsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptsDir "_lib.ps1")
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

$postPath = Join-Path $S.Blog ($Slug + ".html")
if (-not (Test-Path $postPath)) { Write-Error "Post not found: $postPath"; exit 1 }

$html = Get-Content $postPath -Raw

# ----------------- Helpers -----------------
function Ensure-TitleMarkers([string]$text) {
  if ($text -match '<!--\s*ASD:TITLE:START\s*-->') { return $text }

  # migrate old inline style: <title><!-- ASD:TITLE:START -->X<!-- ASD:TITLE:END --></title>
  $patOldInline = '<title>\s*<!--\s*ASD:TITLE:START\s*-->.*?<!--\s*ASD:TITLE:END\s*-->\s*</title>'
  if ($text -match $patOldInline) {
    return [regex]::Replace(
      $text, $patOldInline,
      { param($m)
        $inner = [regex]::Match($m.Value, '<!--\s*ASD:TITLE:START\s*-->(.*?)<!--\s*ASD:TITLE:END\s*-->', 'Singleline').Groups[1].Value
        "<!-- ASD:TITLE:START -->`r`n<title>$inner</title>`r`n<!-- ASD:TITLE:END -->"
      },
      [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
  }

  # plain <title>…</title> → wrap it
  $patPlain = '<title>(.*?)</title>'
  if ($text -match $patPlain) {
    return [regex]::Replace(
      $text, $patPlain,
      { param($m) "<!-- ASD:TITLE:START -->`r`n<title>$($m.Groups[1].Value)</title>`r`n<!-- ASD:TITLE:END -->" },
      [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
  }

  # no title at all → insert a block before </head>
  return [regex]::Replace(
    $text, '</head>',
    { param($m) "<!-- ASD:TITLE:START -->`r`n<title>Untitled</title>`r`n<!-- ASD:TITLE:END -->`r`n</head>" },
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

function Ensure-DescMarkers([string]$text) {
  if ($text -match '<!--\s*ASD:DESC:START\s*-->') { return $text }

  # If there's a meta description already, wrap it; also strip any old inline markers from its content
  $patMeta = '<meta[^>]*name\s*=\s*["'']description["''][^>]*>'
  $m = [regex]::Match($text, $patMeta, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if ($m.Success) {
    $tag = $m.Value
    $c   = [regex]::Match($tag, 'content\s*=\s*["''](.*?)["'']', [System.Text.RegularExpressions.RegexOptions]::Singleline).Groups[1].Value
    if ($c) {
      $c = [regex]::Replace($c, '<!--\s*ASD:DESC:START\s*-->|<!--\s*ASD:DESC:END\s*-->', '')
    }
    $cAttr = ($c -replace '"','&quot;')
    $wrapped = "<!-- ASD:DESC:START -->`r`n<meta name=""description"" content=""$cAttr"">`r`n<!-- ASD:DESC:END -->"
    return ($text.Substring(0, $m.Index) + $wrapped + $text.Substring($m.Index + $m.Length))
  }

  # No meta description → insert a block before </head>
  return [regex]::Replace(
    $text, '</head>',
    { param($m) "<!-- ASD:DESC:START -->`r`n<meta name=""description"" content=""..."">`r`n<!-- ASD:DESC:END -->`r`n</head>" },
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

function Ensure-BodyMarkers([string]$text) {
  # Migrate old ASD:CONTENT_* to ASD:BODY_* if present
  if ($text -match '<!--\s*ASD:CONTENT_START\s*-->') {
    $text = [regex]::Replace(
      $text, '<!--\s*ASD:CONTENT_START\s*-->',
      { param($m) '<!-- ASD:BODY:START -->' },
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    $text = [regex]::Replace(
      $text, '<!--\s*ASD:CONTENT_END\s*-->',
      { param($m) '<!-- ASD:BODY:END -->' },
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
    return $text
  }

  if ($text -match '<!--\s*ASD:BODY:START\s*-->') { return $text }

  # Try to wrap <main>…</main>
  $patMain = '(<main[^>]*>)(.*?)(</main>)'
  $mm = [regex]::Match($text, $patMain, [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($mm.Success) {
    $before = $text.Substring(0, $mm.Index)
    $inside = $mm.Groups[2].Value
    $after  = $text.Substring($mm.Index + $mm.Length)
    $wrapped = $mm.Groups[1].Value + "`r`n  <!-- ASD:BODY:START -->`r`n" + $inside + "`r`n  <!-- ASD:BODY:END -->`r`n" + $mm.Groups[3].Value
    return ($before + $wrapped + $after)
  }

  # Else just add a minimal main with markers before </body>
  return [regex]::Replace(
    $text, '</body>',
    { param($m) "<main>`r`n  <!-- ASD:BODY:START -->`r`n  <!-- ASD:BODY:END -->`r`n</main>`r`n</body>" },
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

# ----------------- Ensure markers exist (and migrate older styles) -----------------
$html = Ensure-TitleMarkers $html
$html = Ensure-DescMarkers  $html
$html = Ensure-BodyMarkers  $html

# ----------------- Apply updates -----------------

if ($PSBoundParameters.ContainsKey('Title')) {
  $titleBlock = "<!-- ASD:TITLE:START -->`r`n<title>" + $Title + "</title>`r`n<!-- ASD:TITLE:END -->"
  $html = [regex]::Replace(
    $html,
    '<!--\s*ASD:TITLE:START\s*-->.*?<!--\s*ASD:TITLE:END\s*-->',
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $titleBlock },
    [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  # Also update first <h1> inside BODY block if present
  $html = [regex]::Replace(
    $html,
    '(?is)(<!--\s*ASD:BODY:START\s*-->)(.*?)(<!--\s*ASD:BODY:END\s*-->)',
    {
      param($m)
      $seg = $m.Groups[2].Value
      if ([regex]::IsMatch($seg, '(?is)<h1[^>]*>.*?</h1>')) {
        $seg = [regex]::Replace($seg, '(?is)(<h1[^>]*>).*?(</h1>)', { param($n) $n.Groups[1].Value + $Title + $n.Groups[2].Value }, 1)
      } else {
        $seg = "<h1>$Title</h1>`r`n" + $seg
      }
      $m.Groups[1].Value + $seg + $m.Groups[3].Value
    },
    1
  )
}

if ($PSBoundParameters.ContainsKey('Description')) {
  $descAttr = ($Description -replace '"','&quot;')

  # Remove any stray meta description outside the ASD block (avoid duplicates)
  $html = [regex]::Replace(
    $html,
    '(?is)(?:(?!<!--\s*ASD:DESC:START\s*-->).)*?<meta\s+[^>]*name\s*=\s*["'']description["''][^>]*>.*?(?=<!--\s*ASD:DESC:START\s*-->|</head>)',
    '',
    [System.Text.RegularExpressions.RegexOptions]::Singleline
  )

  $descBlock = "<!-- ASD:DESC:START -->`r`n<meta name=""description"" content=""$descAttr"">`r`n<!-- ASD:DESC:END -->"
  $html = [regex]::Replace(
    $html,
    '<!--\s*ASD:DESC:START\s*-->.*?<!--\s*ASD:DESC:END\s*-->',
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $descBlock },
    [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

if ($PSBoundParameters.ContainsKey('BodyHtml')) {
  $bodyBlock = "<!-- ASD:BODY:START -->`r`n" + $BodyHtml + "`r`n<!-- ASD:BODY:END -->"
  $html = [regex]::Replace(
    $html,
    '<!--\s*ASD:BODY:START\s*-->.*?<!--\s*ASD:BODY:END\s*-->',
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $bodyBlock },
    [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

Set-Content -Encoding UTF8 -Path $postPath -Value $html
Write-Host "[ASD] Updated blog\$Slug.html (markers ensured)"
