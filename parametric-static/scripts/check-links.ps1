# Amaterasu Static Deploy — check-links.ps1 (safe for tokens + external links)
# - Skips layout.html and partials/*
# - Ignores http(s), //, mailto:, tel:, data:, sms:, javascript:, #
# - Ignores template tokens like {{PREFIX}} and {{BRAND}}
# - Treats paths ending with "/" as ".../index.html"
# - Resolves /root/relative from repo root, and ./../ relative to the current file

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root

# files to scan
$files = Get-ChildItem $Root -Recurse -Include *.html,*.xml -File |
  Where-Object {
    $_.FullName -notmatch '\\partials\\' -and
    $_.Name -ne 'layout.html'
  }

$broken = New-Object System.Collections.Generic.List[string]

# helper: should skip this href/src?
function Skip-Link([string]$h) {
  if (-not $h) { return $true }
  $h = $h.Trim()

  # protocols / externals / fragments
  if ($h -match '^(https?:)?//') { return $true }
  if ($h -match '^(mailto:|tel:|data:|javascript:|sms:)') { return $true }
  if ($h -match '^\s*#') { return $true }

  # template tokens (pre-bake)
  if ($h -match '\{\{[^}]+\}\}') { return $true }         # {{PREFIX}}, {{BRAND}}, etc.

  return $false
}

foreach ($f in $files) {
  $html = Get-Content $f.FullName -Raw

  # collect href/src values (very light regex, good enough for our static HTML)
  $matches = Select-String -InputObject $html -Pattern '(?i)\b(?:href|src)=["'']([^"''\s]+)' -AllMatches |
    ForEach-Object { $_.Matches } | ForEach-Object { $_.Groups[1].Value }

  foreach ($h in $matches) {
    if (Skip-Link $h) { continue }

    # strip query/hash
    $p = ($h -replace '[?#].*$','')

    # resolve candidate on disk
    $candidate = $null
    if ($p.StartsWith('/')) {
      # root-relative (treat repo root as site root)
      $candidate = Join-Path $Root ($p.TrimStart('/') -replace '/','\')
    } else {
      # file-relative
      $candidate = Join-Path $f.DirectoryName ($p -replace '/','\')
    }

    # if ends with "/", assume index.html
    if ($p -match '/$') {
      $candidate = Join-Path $candidate 'index.html'
    }

    # if target is a directory, also try index.html
    if (-not (Test-Path $candidate)) {
      if (Test-Path $candidate -PathType Container) {
        $candidate2 = Join-Path $candidate 'index.html'
        if (Test-Path $candidate2) { continue }
      }
      # record broken (relative to repo root for clarity)
      $relFile = $f.FullName.Substring($Root.Length + 1)
      $broken.Add("{0} -> {1}" -f $relFile, $h)
    }
  }
}

if ($broken.Count -gt 0) {
  Write-Host "Broken links:"
  $broken | ForEach-Object { Write-Host "  $_" }
  exit 1
} else {
  Write-Host "No broken local links found."
}
