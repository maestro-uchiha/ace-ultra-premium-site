<#
  update-post.ps1
  Update an existing blog post:
    -Slug (required)
    -Title (optional)
    -Description (optional)
    -BodyHtml (optional) -> replaces content between ASD BODY markers
    -Author (optional)   -> updates <meta name="author" ...>

  Ensures SAFE ASD markers exist (block-wrapped):
    <!-- ASD:TITLE:START --><title>…</title><!-- ASD:TITLE:END -->
    <!-- ASD:DESC:START --><meta name="description" content="…"><!-- ASD:DESC:END -->
    <!-- ASD:BODY:START --> … <!-- ASD:BODY:END -->

  Migrates older inline marker styles and ASD:CONTENT_* to ASD:BODY_*.
  PowerShell 5.1 compatible.
#>

[CmdletBinding()]
param(
  [Parameter(Mandatory = $true)][string]$Slug,
  [string]$Title,
  [string]$Description,
  [string]$BodyHtml,
  [string]$Author
)

Set-StrictMode -Version Latest

# --- load lib/config ---
$ScriptsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptsDir "_lib.ps1")
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

$postPath = Join-Path $S.Blog ($Slug + ".html")
if (-not (Test-Path $postPath)) { Write-Error "Post not found: $postPath"; exit 1 }

$html = Get-Content $postPath -Raw

# ----------------- helpers -----------------
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

function Get-ExistingAuthor([string]$text) {
  $m = [regex]::Match(
    $text,
    '<meta[^>]*name\s*=\s*["'']author["''][^>]*content\s*=\s*["''](.*?)["'']',
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
  )
  if ($m.Success) { return $m.Groups[1].Value } else { return "" }
}

function Upsert-MetaAuthor([string]$text, [string]$author) {
  $authorAttr = $author -replace '"','&quot;'
  $pat = '<meta[^>]*name\s*=\s*["'']author["''][^>]*>'
  $opt = [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline
  $m = [regex]::Match($text, $pat, $opt)
  if ($m.Success) {
    # Normalize the whole tag to a clean one with just name+content
    return [regex]::Replace($text, $pat, { param($x) '<meta name="author" content="' + $authorAttr + '">' }, $opt)
  } else {
    # Insert before </head>
    return [regex]::Replace(
      $text,
      '</head>',
      { param($x) '  <meta name="author" content="' + $authorAttr + '">' + "`r`n</head>" },
      [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
  }
}

function Ensure-TitleMarkers([string]$text) {
  if ($text -match '<!--\s*ASD:TITLE:START\s*-->') { return $text }
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
  $patPlain = '<title>(.*?)</title>'
  if ($text -match $patPlain) {
    return [regex]::Replace(
      $text, $patPlain,
      { param($m) "<!-- ASD:TITLE:START -->`r`n<title>$($m.Groups[1].Value)</title>`r`n<!-- ASD:TITLE:END -->" },
      [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
    )
  }
  return [regex]::Replace(
    $text, '</head>',
    { param($m) "<!-- ASD:TITLE:START -->`r`n<title>Untitled</title>`r`n<!-- ASD:TITLE:END -->`r`n</head>" },
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

function Ensure-DescMarkers([string]$text) {
  if ($text -match '<!--\s*ASD:DESC:START\s*-->') { return $text }
  $patMeta = '<meta[^>]*name\s*=\s*["'']description["''][^>]*>'
  $m = [regex]::Match($text, $patMeta, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase -bor [System.Text.RegularExpressions.RegexOptions]::Singleline)
  if ($m.Success) {
    $tag = $m.Value
    $c   = [regex]::Match($tag, 'content\s*=\s*["''](.*?)["'']', 'Singleline').Groups[1].Value
    if ($c) { $c = [regex]::Replace($c, '<!--\s*ASD:DESC:START\s*-->|<!--\s*ASD:DESC:END\s*-->', '') }
    $cAttr = ($c -replace '"','&quot;')
    $wrapped = "<!-- ASD:DESC:START -->`r`n<meta name=""description"" content=""$cAttr"">`r`n<!-- ASD:DESC:END -->"
    return ($text.Substring(0, $m.Index) + $wrapped + $text.Substring($m.Index + $m.Length))
  }
  return [regex]::Replace(
    $text, '</head>',
    { param($m) "<!-- ASD:DESC:START -->`r`n<meta name=""description"" content=""..."">`r`n<!-- ASD:DESC:END -->`r`n</head>" },
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

function Ensure-BodyMarkers([string]$text) {
  if ($text -match '<!--\s*ASD:CONTENT_START\s*-->') {
    $text = [regex]::Replace($text, '<!--\s*ASD:CONTENT_START\s*-->', { param($m) '<!-- ASD:BODY:START -->' }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    $text = [regex]::Replace($text, '<!--\s*ASD:CONTENT_END\s*-->',   { param($m) '<!-- ASD:BODY:END -->'   }, [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
    return $text
  }
  if ($text -match '<!--\s*ASD:BODY:START\s*-->') { return $text }

  $patMain = '(<main[^>]*>)(.*?)(</main>)'
  $mm = [regex]::Match($text, $patMain, [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase)
  if ($mm.Success) {
    $before = $text.Substring(0, $mm.Index)
    $inside = $mm.Groups[2].Value
    $after  = $text.Substring($mm.Index + $mm.Length)
    $wrapped = $mm.Groups[1].Value + "`r`n  <!-- ASD:BODY:START -->`r`n" + $inside + "`r`n  <!-- ASD:BODY:END -->`r`n" + $mm.Groups[3].Value
    return ($before + $wrapped + $after)
  }

  return [regex]::Replace(
    $text, '</body>',
    { param($m) "<main>`r`n  <!-- ASD:BODY:START -->`r`n  <!-- ASD:BODY:END -->`r`n</main>`r`n</body>" },
    [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

# ----------------- ensure markers exist -----------------
$html = Ensure-TitleMarkers $html
$html = Ensure-DescMarkers  $html
$html = Ensure-BodyMarkers  $html

# ----------------- Title update -----------------
if ($PSBoundParameters.ContainsKey('Title')) {
  $titleBlock = "<!-- ASD:TITLE:START -->`r`n<title>" + $Title + "</title>`r`n<!-- ASD:TITLE:END -->"
  $html = [regex]::Replace(
    $html,
    '<!--\s*ASD:TITLE:START\s*-->.*?<!--\s*ASD:TITLE:END\s*-->',
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $titleBlock },
    [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )

  # Also update first <h1> inside BODY
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

# ----------------- Description update -----------------
if ($PSBoundParameters.ContainsKey('Description')) {
  $descAttr = ($Description -replace '"','&quot;')

  # Remove stray description tags outside ASD block
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

# ----------------- BodyHtml update -----------------
if ($PSBoundParameters.ContainsKey('BodyHtml')) {
  $bodyBlock = "<!-- ASD:BODY:START -->`r`n" + $BodyHtml + "`r`n<!-- ASD:BODY:END -->"
  $html = [regex]::Replace(
    $html,
    '<!--\s*ASD:BODY:START\s*-->.*?<!--\s*ASD:BODY:END\s*-->',
    [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $bodyBlock },
    [System.Text.RegularExpressions.RegexOptions]::Singleline -bor [System.Text.RegularExpressions.RegexOptions]::IgnoreCase
  )
}

# ----------------- Author update (prompt if not provided) -----------------
$needAuthor = $PSBoundParameters.ContainsKey('Author')
if (-not $needAuthor) {
  $existingAuthor = Get-ExistingAuthor $html
  $defaultAuthor  = if (-not [string]::IsNullOrWhiteSpace($existingAuthor)) { $existingAuthor } else { Get-DefaultAuthor $cfg }
  try {
    $ans = Read-Host ("Author name [{0}]" -f $defaultAuthor)
    if ([string]::IsNullOrWhiteSpace($ans)) { $Author = $defaultAuthor } else { $Author = $ans }
    $needAuthor = $true
  } catch {
    # non-interactive fallback
    $Author = $defaultAuthor
    $needAuthor = $true
  }
}
if ($needAuthor) {
  $html = Upsert-MetaAuthor $html $Author
}

# ----------------- write back -----------------
Set-Content -Encoding UTF8 -Path $postPath -Value $html
Write-Host "[ASD] Updated blog\$Slug.html (markers ensured)"
