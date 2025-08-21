param(
  [string]$Brand = "Amaterasu Static Deploy",
  [string]$Money = "https://example.com"
)

Write-Host "[ASD] Baking site for brand: $Brand, money site: $Money"

# Load from bake-config.json if args not passed
if ((-not $PSBoundParameters.ContainsKey('Brand') -or -not $PSBoundParameters.ContainsKey('Money')) -and (Test-Path "bake-config.json")) {
  $cfg = Get-Content "bake-config.json" -Raw | ConvertFrom-Json
  if (-not $PSBoundParameters.ContainsKey('Brand') -and $cfg.brand) { $Brand = $cfg.brand }
  if (-not $PSBoundParameters.ContainsKey('Money') -and $cfg.url)   { $Money = $cfg.url }
}
$Year = (Get-Date).Year

# Load partials
$headPartial = Get-Content "partials/head-seo.html" -Raw
$navPartial  = Get-Content "partials/nav.html" -Raw
$footPartial = Get-Content "partials/footer.html" -Raw

function Apply-Template {
  param([string]$Path)
  if (-not (Test-Path $Path)) { return }
  $html = Get-Content $Path -Raw
  # includes
  $html = $html -replace '<!--#include virtual="partials/head-seo.html" -->', $headPartial
  $html = $html -replace '<!--#include virtual="partials/nav.html" -->',  $navPartial
  $html = $html -replace '<!--#include virtual="partials/footer.html" -->', $footPartial
  # tokens
  $html = $html -replace '\{\{BRAND\}\}', $Brand
  $html = $html -replace '\{\{MONEY\}\}', $Money
  $html = $html -replace '\{\{YEAR\}\}',  $Year
  Set-Content -Encoding UTF8 $Path $html
  Write-Host "[ASD] Baked $Path"
}

# Root pages
@("index.html","about.html","contact.html","sitemap.html","404.html") | ForEach-Object { Apply-Template $_ }
# Legal pages
@("legal/privacy.html","legal/terms.html","legal/disclaimer.html")    | ForEach-Object { Apply-Template $_ }
# Blog posts
if (Test-Path "blog") { Get-ChildItem -Path "blog" -Filter *.html -File | ForEach-Object { Apply-Template $_.FullName } }

# ---- Update config.json (supports nested site.*, author.*; keeps legacy keys) ----
$cfgPath = "config.json"
if (Test-Path $cfgPath) {
  try { $c = Get-Content $cfgPath -Raw | ConvertFrom-Json -ErrorAction Stop }
  catch { Write-Host "[ASD] config.json invalid JSON; rebuilding."; $c = [pscustomobject]@{} }
} else { $c = [pscustomobject]@{} }

if (-not ($c | Get-Member -Name site   -MemberType NoteProperty)) { $c | Add-Member -NotePropertyName site   -NotePropertyValue ([pscustomobject]@{}) }
if (-not ($c | Get-Member -Name author -MemberType NoteProperty)) { $c | Add-Member -NotePropertyName author -NotePropertyValue ([pscustomobject]@{}) }

# site.name/url/description (do not force url; clear placeholder if present)
$desc = $null
if ($c.site.PSObject.Properties.Name -contains 'description' -and $c.site.description) {
  $desc = ($c.site.description -replace '\{\{BRAND\}\}', $Brand)
} else {
  $desc = ("Premium {0} - quality, reliability, trust." -f $Brand)
}
$c.site.name        = $Brand
if (-not ($c.site.PSObject.Properties.Name -contains 'url')) {
  $c.site | Add-Member -NotePropertyName url -NotePropertyValue ""
} elseif ($c.site.url -match 'YOUR-DOMAIN\.example') {
  $c.site.url = ""
}
$c.site.description = $desc

# author.name: replace {{BRAND}} if present; keep email if present
if ($c.author.PSObject.Properties.Name -contains 'name' -and $c.author.name) {
  $c.author.name = ($c.author.name -replace '\{\{BRAND\}\}', $Brand)
} else {
  if (-not ($c.author.PSObject.Properties.Name -contains 'name')) {
    $c.author | Add-Member -NotePropertyName name -NotePropertyValue ("{0} Team" -f $Brand)
  } else { $c.author.name = ("{0} Team" -f $Brand) }
}

# legacy keys (harmless for compat)
if (-not ($c | Get-Member -Name brand     -MemberType NoteProperty)) { Add-Member -InputObject $c -NotePropertyName brand     -NotePropertyValue $Brand } else { $c.brand     = $Brand }
if (-not ($c | Get-Member -Name moneySite -MemberType NoteProperty)) { Add-Member -InputObject $c -NotePropertyName moneySite -NotePropertyValue $Money } else { $c.moneySite = $Money }

$c | ConvertTo-Json -Depth 10 | Set-Content -Encoding UTF8 $cfgPath
Write-Host "[ASD] config.json updated (site.*, author.*, legacy)."

# ---- Build blog index safely (ASCII only; uses &mdash;) ----
$posts = New-Object System.Collections.Generic.List[string]
if (Test-Path "blog") {
  Get-ChildItem -Path "blog" -Filter *.html -File | Where-Object { $_.Name -ne "index.html" } | ForEach-Object {
    $html = Get-Content $_.FullName -Raw
    $m = [regex]::Match($html, '<title>(.*?)</title>', 'IgnoreCase')
    $title = if ($m.Success) { $m.Groups[1].Value } else { $_.BaseName }
    $date  = $_.LastWriteTime.ToString('yyyy-MM-dd')
    $rel   = "blog/$($_.Name)"
    $li    = ('<li><a href="/{0}">{1}</a><small> &mdash; {2}</small></li>' -f $rel, $title, $date)
    $posts.Add($li)
  }
}
if (Test-Path "blog/index.html") {
  $bi = Get-Content "blog/index.html" -Raw
  $joined = [string]::Join([Environment]::NewLine, $posts)
  $pattern = '(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->'
  $replacement = @"
<!-- POSTS_START -->
$joined
<!-- POSTS_END -->
"@
  $bi = [regex]::Replace($bi, $pattern, $replacement)
  Set-Content -Encoding UTF8 "blog/index.html" $bi
  Write-Host "[ASD] Blog index updated"
}

Write-Host "[ASD] Done."
