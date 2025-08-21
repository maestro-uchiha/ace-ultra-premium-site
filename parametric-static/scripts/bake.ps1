# ============================================
#  Amaterasu Static Deploy (ASD) - bake.ps1
#  Layout-based (no partials), idempotent.
#  - Extracts original content via markers if present
#  - Else falls back to <body> and strips old header/nav/footer/SSI
#  - Computes {{PREFIX}} per page for nested paths
#  - Rebuilds blog index (relative links in /blog/)
#  - Updates config.json (nested schema) and writes UTF-8
#  - Normalizes dash-like characters/entities/mojibake to "|"
# ============================================

param(
  [string]$Brand = "Amaterasu Static Deploy",
  [string]$Money = "https://example.com"
)

Write-Host "[ASD] Baking site for brand: $Brand, money site: $Money"

$RootDir    = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$LayoutPath = Join-Path $RootDir "layout.html"
$BlogDir    = Join-Path $RootDir "blog"
$CfgPath    = Join-Path $RootDir "config.json"
$Year       = (Get-Date).Year

if (-not (Test-Path $LayoutPath)) {
  Write-Error "[ASD] layout.html not found at $LayoutPath"
  exit 1
}
$Layout = Get-Content $LayoutPath -Raw

# --- Normalize dashes (Unicode, entities, and common mojibake) to a pipe "|"
function Normalize-DashesToPipe {
  param([string]$s)
  if ($null -eq $s) { return $s }
  $pipe = '|'

  # Proper Unicode dashes
  $s = $s.Replace([string][char]0x2013, $pipe)  # en dash
  $s = $s.Replace([string][char]0x2014, $pipe)  # em dash

  # HTML entities that might appear in content
  $s = $s.Replace('&ndash;', $pipe)
  $s = $s.Replace('&mdash;', $pipe)

  # Mojibake sequences (UTF-8 bytes read as Latin-1/CP1252), built from codepoints:
  # en dash (E2 80 93) -> three chars: 0x00E2, 0x0080, 0x0093
  $seq_en  = [string]([char]0x00E2) + [char]0x0080 + [char]0x0093
  # em dash (E2 80 94) -> three chars: 0x00E2, 0x0080, 0x0094
  $seq_em  = [string]([char]0x00E2) + [char]0x0080 + [char]0x0094
  $s = $s.Replace($seq_en, $pipe).Replace($seq_em, $pipe)

  # Double-mojibake variants sometimes appear after copy/paste chains:
  # "Ã¢â‚¬â€œ" and "Ã¢â‚¬â€�"
  $seq2_en = [string]([char]0x00C3)+[char]0x0082+[char]0x00C2+[char]0x00A2+[char]0x00E2+[char]0x0080+[char]0x0093
  $seq2_em = [string]([char]0x00C3)+[char]0x0082+[char]0x00C2+[char]0x00A2+[char]0x00E2+[char]0x0080+[char]0x0094
  $s = $s.Replace($seq2_en, $pipe).Replace($seq2_em, $pipe)

  return $s
}

# Optional: load bake-config.json if args not provided
$BakeCfg = Join-Path $RootDir "bake-config.json"
if ((-not $PSBoundParameters.ContainsKey('Brand') -or -not $PSBoundParameters.ContainsKey('Money')) -and (Test-Path $BakeCfg)) {
  try {
    $cfg = Get-Content $BakeCfg -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('Brand') -and $cfg.brand) { $Brand = $cfg.brand }
    if (-not $PSBoundParameters.ContainsKey('Money') -and $cfg.url)   { $Money = $cfg.url }
  } catch { Write-Host "[ASD] Warning: bake-config.json invalid; ignoring." }
}

# ---- Build blog index (inject into content file BEFORE wrapping)
$BlogIndex = Join-Path $BlogDir "index.html"
if (Test-Path $BlogIndex) {
  $posts = New-Object System.Collections.Generic.List[string]
  Get-ChildItem -Path $BlogDir -Filter *.html -File |
    Where-Object { $_.Name -ne "index.html" } |
    Sort-Object LastWriteTime -Descending |
    ForEach-Object {
      $html  = Get-Content $_.FullName -Raw
      $m     = [regex]::Match($html, '<title>(.*?)</title>', 'IgnoreCase')
      $title = if ($m.Success) { $m.Groups[1].Value } else { $_.BaseName }
      $title = Normalize-DashesToPipe $title
      $date  = $_.LastWriteTime.ToString('yyyy-MM-dd')
      $rel   = $_.Name  # relative to /blog/
      $li    = ('<li><a href="./{0}">{1}</a><small> | {2}</small></li>' -f $rel, $title, $date)
      $posts.Add($li)
    }

  $bi = Get-Content $BlogIndex -Raw
  $joined = [string]::Join([Environment]::NewLine, $posts)
  $pattern = '(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->'
  $replacement = @"
<!-- POSTS_START -->
$joined
<!-- POSTS_END -->
"@
  $bi = [regex]::Replace($bi, $pattern, $replacement)
  Set-Content -Encoding UTF8 $BlogIndex $bi
  Write-Host "[ASD] Blog index updated"
}

# ---- Compute {{PREFIX}} ('' at root, '../' in subdirs)
function Get-RelPrefix {
  param([string]$FilePath)
  $fileDir = Split-Path $FilePath -Parent
  $rootSeg = ($RootDir.TrimEnd('\')).Split('\')
  $dirSeg  = ($fileDir.TrimEnd('\')).Split('\')
  $depth = $dirSeg.Length - $rootSeg.Length
  if ($depth -lt 1) { return '' }
  $p = ''
  for ($i=0; $i -lt $depth; $i++) { $p += '../' }
  return $p
}

# ---- Load/prepare config.json (nested schema; keep legacy keys)
$c = $null
if (Test-Path $CfgPath) {
  try { $c = Get-Content $CfgPath -Raw | ConvertFrom-Json -ErrorAction Stop }
  catch { $c = [pscustomobject]@{} }
} else { $c = [pscustomobject]@{} }

if (-not ($c | Get-Member -Name site   -MemberType NoteProperty)) { $c | Add-Member -NotePropertyName site   -NotePropertyValue ([pscustomobject]@{}) }
if (-not ($c | Get-Member -Name author -MemberType NoteProperty)) { $c | Add-Member -NotePropertyName author -NotePropertyValue ([pscustomobject]@{}) }

$desc = if ($c.site.PSObject.Properties.Name -contains 'description' -and $c.site.description) {
  ($c.site.description -replace '\{\{BRAND\}\}', $Brand)
} else { "Premium $Brand - quality, reliability, trust." }

$c.site.name = $Brand
if (-not ($c.site.PSObject.Properties.Name -contains 'url')) {
  $c.site | Add-Member -NotePropertyName url -NotePropertyValue ''
} elseif ($c.site.url -match 'YOUR-DOMAIN\.example') {
  $c.site.url = ''
}
$c.site.description = $desc

if ($c.author.PSObject.Properties.Name -contains 'name' -and $c.author.name) {
  $c.author.name = ($c.author.name -replace '\{\{BRAND\}\}', $Brand)
} else {
  if (-not ($c.author.PSObject.Properties.Name -contains 'name')) {
    $c.author | Add-Member -NotePropertyName name -NotePropertyValue ("{0} Team" -f $Brand)
  } else { $c.author.name = ("{0} Team" -f $Brand) }
}

# Legacy keys
if (-not ($c | Get-Member -Name brand     -MemberType NoteProperty)) { Add-Member -InputObject $c -NotePropertyName brand     -NotePropertyValue $Brand } else { $c.brand     = $Brand }
if (-not ($c | Get-Member -Name moneySite -MemberType NoteProperty)) { Add-Member -InputObject $c -NotePropertyName moneySite -NotePropertyValue $Money } else { $c.moneySite = $Money }

$c | ConvertTo-Json -Depth 12 | Set-Content -Encoding UTF8 $CfgPath
Write-Host "[ASD] config.json updated"

# ---- Extract original content safely (markers first, otherwise strip site chrome)
function Extract-Content {
  param([string]$raw)
  # Prefer markers if present (idempotent re-bake)
  $mark = [regex]::Match($raw, '(?is)<!--\s*ASD:CONTENT_START\s*-->(.*?)<!--\s*ASD:CONTENT_END\s*-->')
  if ($mark.Success) { return $mark.Groups[1].Value }

  # Else fallback to body inner HTML if it's a full HTML doc
  $body = [regex]::Match($raw, '(?is)<body[^>]*>(.*?)</body>')
  if ($body.Success) { $raw = $body.Groups[1].Value }

  # Strip any old SSI includes and site chrome
  $raw = [regex]::Replace($raw, '(?is)<!--#include\s+virtual="partials/.*?-->', '')
  $raw = [regex]::Replace($raw, '(?is)<header\b[^>]*>.*?</header>', '')
  $raw = [regex]::Replace($raw, '(?is)<nav\b[^>]*>.*?</nav>', '')
  $raw = [regex]::Replace($raw, '(?is)<footer\b[^>]*>.*?</footer>', '')
  return $raw
}

# ---- Wrap every HTML (except layout.html) using layout and per-page PREFIX
Get-ChildItem -Path $RootDir -Recurse -File |
  Where-Object { $_.Extension -eq ".html" -and $_.FullName -ne $LayoutPath } |
  ForEach-Object {
    $raw = Get-Content $_.FullName -Raw
    $content = Extract-Content $raw

    # Title from first <h1>, fallback to filename
    $tm = [regex]::Match($content, '(?is)<h1[^>]*>(.*?)</h1>')
    $pageTitle = if ($tm.Success) { $tm.Groups[1].Value } else { $_.BaseName }

    # Compute prefix depth
    $prefix = Get-RelPrefix -FilePath $_.FullName

    # Build final page with markers embedded
    $final = $Layout
    $final = $final.Replace('{{CONTENT}}', $content)
    $final = $final.Replace('{{TITLE}}', $pageTitle)
    $final = $final.Replace('{{BRAND}}', $Brand)
    $final = $final.Replace('{{DESCRIPTION}}', $desc)
    $final = $final.Replace('{{MONEY}}', $Money)
    $final = $final.Replace('{{YEAR}}', "$Year")
    $final = $final.Replace('{{PREFIX}}', $prefix)

    # Normalize any dash-like text to a plain pipe
    $final = Normalize-DashesToPipe $final

    Set-Content -Encoding UTF8 $_.FullName $final
    Write-Host ("[ASD] Wrapped {0} (prefix='{1}')" -f $_.FullName.Substring($RootDir.Length+1), $prefix)
  }

Write-Host "[ASD] Done."
