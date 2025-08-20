# ================================
# Amaterasu Static Deploy (ASD)
# bake.ps1 — main baking script
# ================================

Write-Host "[ASD] Baking site..."

# --- Load version
$ASD_VER = ""
if (Test-Path "VERSION") {
  $ASD_VER = Get-Content "VERSION" -Raw
} elseif (Test-Path "$PSScriptRoot\..\VERSION") {
  $ASD_VER = Get-Content "$PSScriptRoot\..\VERSION" -Raw
}
if ($ASD_VER) {
  Write-Host "[ASD] Version $ASD_VER"
} else {
  Write-Host "[ASD] Version (unknown)"
}

# --- Inputs (CLI args override bake-config.json)
param(
  [string]$Brand,
  [string]$Money
)
if (-not $Brand -and (Test-Path "bake-config.json")) {
  $cfg = Get-Content "bake-config.json" -Raw | ConvertFrom-Json
  $Brand = $cfg.brand
  $Money = $cfg.url
}
if (-not $Brand) { $Brand = "{{BRAND}}" }
if (-not $Money) { $Money = "https://YOUR-DOMAIN.com" }
$Year = (Get-Date).Year
Write-Host "[ASD] BRAND=$Brand MONEY=$Money YEAR=$Year"

# --- Load partials
$head = Get-Content "partials/head-seo.html" -Raw
$nav  = Get-Content "partials/nav.html" -Raw
$foot = Get-Content "partials/footer.html" -Raw

function Bake-File($path) {
  if (Test-Path $path) {
    $html = Get-Content $path -Raw
    $html = $html -replace '<!--#include virtual="partials/head-seo.html" -->', $head
    $html = $html -replace '<!--#include virtual="partials/nav.html" -->', $nav
    $html = $html -replace '<!--#include virtual="partials/footer.html" -->', $foot
    $html = $html -replace '{{BRAND}}', $Brand
    $html = $html -replace '{{MONEY}}', $Money
    $html = $html -replace '{{YEAR}}', $Year
    Set-Content $path $html
    Write-Host "[ASD] Baked $path"
  }
}

# --- Root pages
"index.html","about.html","contact.html","sitemap.html","404.html" | ForEach-Object { Bake-File $_ }

# --- Legal pages
"legal/privacy.html","legal/terms.html","legal/disclaimer.html" | ForEach-Object { Bake-File $_ }

# --- Blog posts
Get-ChildItem "blog" -Filter *.html | ForEach-Object { Bake-File $_.FullName }

# --- Update config.json
if (Test-Path "config.json") {
  $cfg = Get-Content "config.json" -Raw | ConvertFrom-Json
  $cfg.brand = $Brand
  $cfg.moneySite = $Money
  $cfg | ConvertTo-Json -Depth 6 | Set-Content "config.json"
  Write-Host "[ASD] Updated config.json"
}

# --- Blog index build
$posts = @()
Get-ChildItem "blog" -Filter *.html | Where-Object { $_.Name -ne "index.html" } | ForEach-Object {
  $title = Select-String -Path $_.FullName -Pattern "<title>(.*?)</title>" | ForEach-Object {
    $_.Matches[0].Groups[1].Value
  }
  if (-not $title) { $title = "(no title)" }
  $date = $_.LastWriteTime.ToString("yyyy-MM-dd")
  $rel = "blog/$($_.Name)"
  $posts += "<li><a href='/$rel'>$title</a><small> — $date</small></li>"
}
if (Test-Path "blog/index.html") {
  $bi = Get-Content "blog/index.html" -Raw
  $joined = $posts -join [Environment]::NewLine
  $bi = [regex]::Replace($bi, "(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->", "<!-- POSTS_START -->`n$joined`n<!-- POSTS_END -->")
  Set-Content "blog/index.html" $bi
  Write-Host "[ASD] Blog index updated"
}

Write-Host "[ASD] Done."
