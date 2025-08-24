param(
  [string]$Root = $(Split-Path -Parent (Split-Path -Parent $PSCommandPath))
)

$ErrorActionPreference = 'Stop'

# Paths
$site = $Root
$assets = Join-Path $site 'assets'
$partials = Join-Path $site 'partials'
$layout = Join-Path $site 'layout.html'

# Collect .html files to scan (skip layout/partials/assets)
$files = Get-ChildItem -Path $site -Recurse -File -Include *.html |
  Where-Object {
    $_.FullName -ne $layout -and
    $_.FullName -notmatch '\\assets\\' -and
    $_.FullName -notmatch '\\partials\\'
  }

# Helpers
function Resolve-LinkPath {
  param(
    [string]$FromFile,
    [string]$Href
  )
  # ignore external / special schemes
  if ($Href -match '^(?i)(https?:|mailto:|tel:|javascript:|data:)') { return $null }

  # strip query/hash
  $clean = $Href -replace '\#.*$','' -replace '\?.*$',''

  if ([string]::IsNullOrWhiteSpace($clean)) { return $null }

  # Root-absolute -> project root
  if ($clean.StartsWith('/')) {
    $p = $clean.TrimStart('/')
    $full = Join-Path $site $p
  } else {
    # relative to the file's directory
    $dir = Split-Path $FromFile -Parent
    $full = Join-Path $dir $clean
  }

  # If it’s a “directory style” link, assume index.html
  if ($full.EndsWith('\') -or $clean.EndsWith('/')) {
    $full = Join-Path $full 'index.html'
  } elseif (-not [IO.Path]::GetExtension($full)) {
    # If no extension and target is a directory, also assume index.html
    if (Test-Path $full -PathType Container) {
      $full = Join-Path $full 'index.html'
    }
  }

  return $full
}

$broken = New-Object System.Collections.Generic.List[string]

# Regexes
$rxHref = [regex]'(?is)href\s*=\s*["'']([^"'']+)["'']'
$rxSrc  = [regex]'(?is)src\s*=\s*["'']([^"'']+)["'']'

foreach ($f in $files) {
  $html = Get-Content $f.FullName -Raw

  # Collect candidate links
  $hrefs = @()
  foreach ($m in $rxHref.Matches($html)) { $hrefs += $m.Groups[1].Value }
  foreach ($m in $rxSrc.Matches($html))  { $hrefs += $m.Groups[1].Value }

  # unique
  $hrefs = $hrefs | Sort-Object -Unique

  foreach ($h in $hrefs) {
    $target = Resolve-LinkPath -FromFile $f.FullName -Href $h
    if ($null -eq $target) { continue }

    # Only check local file existence
    if (-not (Test-Path $target -PathType Leaf)) {
      $relFile = ($f.FullName.Substring($site.Length+1)).Replace('\','/')
      # PARENTHESIZE the -f to avoid precedence issues, OR just interpolate:
      $broken.Add(("{0} -> {1}" -f $relFile, $h))
      # alternative (also safe):
      # $broken.Add("$relFile -> $h")
    }
  }
}

if ($broken.Count -gt 0) {
  Write-Host "Broken links:" -ForegroundColor Yellow
  $broken | ForEach-Object { Write-Host "  $_" }
  exit 1
} else {
  Write-Host "No broken local links found." -ForegroundColor Green
}
