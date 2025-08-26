param(
  [string]$Root = $(Split-Path -Parent (Split-Path -Parent $PSCommandPath)),
  [switch]$External,              # also check http(s) links with HEAD
  [int]$TimeoutSec = 8            # external check timeout
)

# Load config/helpers (kept for parity with the rest of ASD; not strictly required here)
$__here  = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")  # PS 5.1-safe dot-source
$__cfg   = Get-ASDConfig
$__paths = Get-ASDPaths | Out-Null

$ErrorActionPreference = 'Stop'

# Paths
$site     = $Root
$layout   = Join-Path $site 'layout.html'

# Collect .html files to scan (skip layout/partials/assets)
$files = Get-ChildItem -Path $site -Recurse -File -Include *.html |
  Where-Object {
    $_.FullName -ne $layout -and
    $_.FullName -notmatch '\\assets\\'   -and
    $_.FullName -notmatch '\\partials\\'
  }

# ========== Helpers ==========

function Normalize-PathSafe {
  param([string]$Path, [string]$BaseDir)
  # Turn forward slashes into backslashes for Windows filesystem joins
  $p = $Path -replace '/', '\'
  if ([IO.Path]::IsPathRooted($p)) {
    return [IO.Path]::GetFullPath($p)
  } else {
    return [IO.Path]::GetFullPath((Join-Path $BaseDir $p))
  }
}

function Resolve-LinkPath {
  param(
    [string]$FromFile,
    [string]$Href
  )

  if ([string]::IsNullOrWhiteSpace($Href)) { return $null }

  # Ignore anchors & special schemes
  if ($Href -match '^(?i)(#|mailto:|tel:|javascript:|data:)') { return $null }

  # Protocol-relative //cdn.example.com -> treat as external
  if ($Href -match '^(?i)//') { return $Href }

  # External absolute
  if ($Href -match '^(?i)https?:') { return $Href }

  # Strip query/hash for local existence checks
  $clean = $Href -replace '\#.*$','' -replace '\?.*$',''
  if ([string]::IsNullOrWhiteSpace($clean)) { return $null }

  # Root-absolute vs relative
  if ($clean.StartsWith('/')) {
    $rel  = $clean.TrimStart('/')
    $full = Normalize-PathSafe -Path $rel -BaseDir $site
  } else {
    $dir  = Split-Path $FromFile -Parent
    $full = Normalize-PathSafe -Path $clean -BaseDir $dir
  }

  # If it’s a “directory style” link, assume index.html
  if ($clean.EndsWith('/')) {
    return Join-Path $full 'index.html'
  }

  # If no extension and the target is a directory, also assume index.html
  if (-not [IO.Path]::GetExtension($full)) {
    if (Test-Path $full -PathType Container) {
      return Join-Path $full 'index.html'
    }
  }

  return $full
}

# Regexes (PS 5.1-safe)
$rxHref = [regex]'(?is)\bhref\s*=\s*["'']([^"''<>]+)["'']'
$rxSrc  = [regex]'(?is)\bsrc\s*=\s*["'']([^"''<>]+)["'']'

# Buckets
$broken         = New-Object System.Collections.Generic.List[string]
$externalFails  = New-Object System.Collections.Generic.List[string]

Write-Host "[links] Scanning HTML under: $site"

foreach ($f in $files) {
  $html = Get-Content $f.FullName -Raw

  # Collect candidate links
  $hrefs = @()
  foreach ($m in $rxHref.Matches($html)) { $hrefs += $m.Groups[1].Value }
  foreach ($m in $rxSrc.Matches($html))  { $hrefs += $m.Groups[1].Value }

  # Unique
  $hrefs = $hrefs | Sort-Object -Unique

  foreach ($h in $hrefs) {
    $target = Resolve-LinkPath -FromFile $f.FullName -Href $h
    if ($null -eq $target) { continue }

    if ($target -match '^(?i)https?://') {
      if ($External) {
        try {
          # HEAD first; some servers may block it — fall back to GET if needed
          $resp = Invoke-WebRequest -Uri $target -Method Head -TimeoutSec $TimeoutSec -MaximumRedirection 5 -ErrorAction Stop
          if (-not $resp.StatusCode -or $resp.StatusCode -ge 400) {
            $externalFails.Add(("{0} -> {1} (code {2})" -f ($f.FullName.Substring($site.Length+1).Replace('\','/')),$target,$resp.StatusCode)) | Out-Null
          }
        } catch {
          try {
            $resp2 = Invoke-WebRequest -Uri $target -Method Get -UseBasicParsing -TimeoutSec $TimeoutSec -MaximumRedirection 5 -ErrorAction Stop
            if (-not $resp2.StatusCode -or $resp2.StatusCode -ge 400) {
              $externalFails.Add(("{0} -> {1} (code {2})" -f ($f.FullName.Substring($site.Length+1).Replace('\','/')),$target,$resp2.StatusCode)) | Out-Null
            }
          } catch {
            $externalFails.Add(("{0} -> {1} (unreachable)" -f ($f.FullName.Substring($site.Length+1).Replace('\','/')),$target)) | Out-Null
          }
        }
      }
      continue
    }

    # Local file existence: accept file leaf; if missing, also try directory index fallback
    if (-not (Test-Path $target -PathType Leaf)) {
      $ok = $false
      if (-not [IO.Path]::GetExtension($target)) {
        # If there's a directory, its index.html counts as valid
        if (Test-Path $target -PathType Container) {
          $tryIdx = Join-Path $target 'index.html'
          if (Test-Path $tryIdx -PathType Leaf) { $ok = $true }
        }
      }
      if (-not $ok) {
        $relFile = ($f.FullName.Substring($site.Length+1)).Replace('\','/')
        $broken.Add(("{0} -> {1}" -f $relFile, $h)) | Out-Null
      }
    }
  }
}

# ===== Results =====
if ($broken.Count -gt 0) {
  Write-Host "`nBroken LOCAL links:" -ForegroundColor Yellow
  ($broken | Sort-Object -Unique) | ForEach-Object { Write-Host "  $_" }
} else {
  Write-Host "No broken local links found." -ForegroundColor Green
}

if ($External) {
  if ($externalFails.Count -gt 0) {
    Write-Host "`nExternal URL issues:" -ForegroundColor Yellow
    ($externalFails | Sort-Object -Unique) | ForEach-Object { Write-Host "  $_" }
  } else {
    Write-Host "External URLs look OK." -ForegroundColor Green
  }
}

# Exit code: fail if local broken, or if external requested and any failed
if ($broken.Count -gt 0 -or ($External -and $externalFails.Count -gt 0)) { exit 1 } else { exit 0 }
