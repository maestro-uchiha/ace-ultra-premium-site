<#
Amaterasu Static Deploy (ASD) — Bake Script
#>

Write-Host "[Amaterasu Static Deploy] Baking…"

# ===== Inputs / defaults (CLI args override bake-config.json) =====
param(
    [string]$Brand,
    [string]$Money
)

if (-not $Brand -and (Test-Path "bake-config.json")) {
    $conf = Get-Content "bake-config.json" -Raw | ConvertFrom-Json
    $Brand = $conf.brand
    $Money = $conf.url
}

if (-not $Brand) { $Brand = "{{BRAND}}" }
if (-not $Money) { $Money = "https://YOUR-DOMAIN.com" }
$Year = (Get-Date).Year

Write-Host "[ASD] BRAND='$Brand' MONEY='$Money' YEAR=$Year"

# ===== Load partials =====
$HeadPartial = Get-Content "partials/head-seo.html" -Raw
$NavPartial  = Get-Content "partials/nav.html" -Raw
$FootPartial = Get-Content "partials/footer.html" -Raw

# ===== Replacement function =====
function Bake-File($file) {
    if (-not (Test-Path $file)) { return }

    $content = Get-Content $file -Raw
    $content = $content -replace '<!--#include virtual="partials/head-seo.html" -->', $HeadPartial
    $content = $content -replace '<!--#include virtual="partials/nav.html" -->', $NavPartial
    $content = $content -replace '<!--#include virtual="partials/footer.html" -->', $FootPartial
    $content = $content -replace '\{\{BRAND\}\}', $Brand
    $content = $content -replace '\{\{MONEY\}\}', $Money
    $content = $content -replace '\{\{YEAR\}\}', $Year

    Set-Content $file $content
    Write-Host "[ASD] Baked $file"
}

# ===== Process root HTML files =====
foreach ($f in @("index.html","about.html","contact.html","sitemap.html","404.html")) {
    Bake-File $f
}

# ===== Process legal pages =====
foreach ($f in @("legal/privacy.html","legal/terms.html","legal/disclaimer.html")) {
    Bake-File $f
}

# ===== Process blog posts =====
Get-ChildItem "blog\*.html" | ForEach-Object {
    if ($_.Name -ne "index.html") {
        Bake-File $_.FullName
    }
}

# ===== Update config.json (optional) =====
if (Test-Path "config.json") {
    $c = Get-Content "config.json" -Raw | ConvertFrom-Json
    $c.brand     = $Brand
    $c.moneySite = $Money
    $c | ConvertTo-Json -Depth 6 | Set-Content "config.json"
    Write-Host "[ASD] Updated config.json"
}

# ===== Build blog index (extract <title>, use file modified date) =====
$posts = @()
Get-ChildItem "blog\*.html" | Where-Object { $_.Name -ne "index.html" } | ForEach-Object {
    $content = Get-Content $_.FullName -Raw
    $titleMatch = [regex]::Match($content, '<title>(.*?)</title>', 'IgnoreCase')
    $title = if ($titleMatch.Success) { $titleMatch.Groups[1].Value } else { '(no title)' }

    $lastWrite = $_.LastWriteTime.ToString("yyyy-MM-dd")
    $rel = "blog/$($_.Name)"

    $posts += "<li><a href='/$rel'>$title</a><small> — $lastWrite</small></li>"
}

if (Test-Path "blog/index.html") {
    $bi = Get-Content "blog/index.html" -Raw
    $joined = $posts -join [Environment]::NewLine
    $bi = [regex]::Replace($bi, '(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->',
        "<!-- POSTS_START -->`n$joined`n<!-- POSTS_END -->")
    Set-Content "blog/index.html" $bi
    Write-Host "[ASD] Blog index updated."
}

Write-Host "[Amaterasu Static Deploy] Done."
