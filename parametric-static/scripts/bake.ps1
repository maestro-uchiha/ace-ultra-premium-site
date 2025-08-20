# ============================================
#  Amaterasu Static Deploy (ASD) - bake.ps1
# ============================================

Write-Host "[Amaterasu Static Deploy] Starting bake..."

# ===== Version banner =====
$asdVer = ""
if (Test-Path "VERSION") {
    $asdVer = Get-Content "VERSION" -Raw
} elseif (Test-Path "$PSScriptRoot\..\VERSION") {
    $asdVer = Get-Content "$PSScriptRoot\..\VERSION" -Raw
}
if ($asdVer) {
    Write-Host "[Amaterasu Static Deploy] Version $asdVer"
} else {
    Write-Host "[Amaterasu Static Deploy] Version (unknown)"
}

# ===== Inputs / defaults =====
param(
    [string]$BRAND,
    [string]$MONEY
)

if (-not $BRAND -and (Test-Path "bake-config.json")) {
    $BRAND = (Get-Content "bake-config.json" -Raw | ConvertFrom-Json).brand
}
if (-not $MONEY -and (Test-Path "bake-config.json")) {
    $MONEY = (Get-Content "bake-config.json" -Raw | ConvertFrom-Json).url
}
if (-not $BRAND) { $BRAND = "{{BRAND}}" }
if (-not $MONEY) { $MONEY = "https://YOUR-DOMAIN.com" }
$YEAR = (Get-Date).Year

Write-Host "[ASD] BRAND='$BRAND' MONEY='$MONEY' YEAR=$YEAR"

# ===== Load partials =====
$headPartial = (Get-Content "partials/head-seo.html" -Raw)
$navPartial  = (Get-Content "partials/nav.html" -Raw)
$footPartial = (Get-Content "partials/footer.html" -Raw)

# ===== Replacement function =====
function Apply-Template {
    param($file)

    $content = Get-Content $file -Raw
    $content = $content -replace '<!--#include virtual="partials/head-seo.html" -->', $headPartial
    $content = $content -replace '<!--#include virtual="partials/nav.html" -->', $navPartial
    $content = $content -replace '<!--#include virtual="partials/footer.html" -->', $footPartial
    $content = $content -replace '{{BRAND}}', $BRAND
    $content = $content -replace '{{MONEY}}', $MONEY
    $content = $content -replace '{{YEAR}}', $YEAR

    Set-Content $file $content
}

# ===== Process root HTML files =====
Get-ChildItem -Path . -Include index.html,about.html,contact.html,sitemap.html,404.html | ForEach-Object {
    Apply-Template $_.FullName
}

# ===== Process legal pages =====
Get-ChildItem -Path legal -Include privacy.html,terms.html,disclaimer.html -ErrorAction SilentlyContinue | ForEach-Object {
    Apply-Template $_.FullName
}

# ===== Process blog posts =====
Get-ChildItem -Path blog -Include *.html -ErrorAction SilentlyContinue | ForEach-Object {
    Apply-Template $_.FullName
}

# ===== Update config.json =====
if (Test-Path "config.json") {
    $c = Get-Content "config.json" -Raw | ConvertFrom-Json
    $c.brand = $BRAND
    $c.moneySite = $MONEY
    $c | ConvertTo-Json -Depth 6 | Set-Content "config.json"
}

# ===== Build blog index =====
$posts = @()
Get-ChildItem "blog\*.html" -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne "index.html" } | ForEach-Object {
    $filePath = $_.FullName
    $rel = "blog/$($_.Name)"
    $html = Get-Content $filePath -Raw
    $m = [regex]::Match($html, '<title>(.*?)</title>', 'IgnoreCase')
    $title = if ($m.Success) { $m.Groups[1].Value } else { "(no title)" }
    $lastWrite = $_.LastWriteTime.ToString("yyyy-MM-dd")

    $posts += "<li><a href='/$rel'>$title</a><small> — $lastWrite</small></li>"
}

if (Test-Path "blog/index.html") {
    $bi = Get-Content "blog/index.html" -Raw
    $joined = $posts -join [Environment]::NewLine
    $bi = [regex]::Replace($bi, '(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->',
        "<!-- POSTS_START -->`n$joined`n<!-- POSTS_END -->")
    Set-Content "blog/index.html" $bi
}

Write-Host "[Amaterasu Static Deploy] Done."
