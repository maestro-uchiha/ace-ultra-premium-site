param([int]$PageSize = 10)

# Load config
$__here = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")
$__cfg   = Get-ASDConfig
$Brand   = $__cfg.SiteName
$Money   = $__cfg.StoreUrl
$Desc    = $__cfg.Description
$Base    = $__cfg.BaseUrl
$__paths = Get-ASDPaths

$Root   = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root
$BlogDir = Join-Path $Root "blog"

if (-not (Test-Path $BlogDir)) { Write-Error "blog/ folder not found."; exit 1 }

function Get-PostTitle([string]$path) {
  $raw = Get-Content $path -Raw
  $mc = [regex]::Match($raw, '(?is)<!--\s*ASD:CONTENT_START\s*-->(.*?)<!--\s*ASD:CONTENT_END\s*-->')
  $segment = if ($mc.Success) { $mc.Groups[1].Value } else {
    $mm = [regex]::Match($raw, '(?is)<main\b[^>]*>(.*?)</main>')
    if ($mm.Success) { $mm.Groups[1].Value } else { $raw }
  }
  $mH1 = [regex]::Match($segment, '(?is)<h1[^>]*>(.*?)</h1>')
  if ($mH1.Success) { return $mH1.Groups[1].Value }
  $mTitle = [regex]::Match($raw, '(?is)<title>(.*?)</title>')
  if ($mTitle.Success) { return $mTitle.Groups[1].Value }
  return [IO.Path]::GetFileNameWithoutExtension($path)
}

$posts = Get-ChildItem $BlogDir -Filter *.html -File `
  | Where-Object { $_.Name -ne 'index.html' -and $_.Name -notmatch '^page-\d+\.html$' } `
  | Sort-Object LastWriteTime -Descending

$items = @()
foreach ($f in $posts) {
  $title = Get-PostTitle $f.FullName
  $date  = $f.LastWriteTime.ToString('yyyy-MM-dd')
  $rel   = "./$($f.Name)"
  $items += ('<li><a href="{0}">{1}</a><small> &middot; {2}</small></li>' -f $rel, $title, $date)
}

Get-ChildItem $BlogDir -Filter 'page-*.html' -File | Remove-Item -Force -ErrorAction SilentlyContinue

if ($items.Count -eq 0) {
  $content = @"
<!-- ASD:CONTENT_START -->
<h1>Blog</h1>
<p>No posts yet.</p>
<!-- ASD:CONTENT_END -->
"@
  Set-Content -Encoding UTF8 (Join-Path $BlogDir 'index.html') $content
  Write-Host "[paginate] Wrote blog/index.html (empty)"
  exit 0
}

$total = $items.Count
$pages = [Math]::Ceiling($total / [double]$PageSize)

for ($i = 1; $i -le $pages; $i++) {
  $start = ($i - 1) * $PageSize
  $count = [Math]::Min($PageSize, $total - $start)
  $slice = $items[$start..($start + $count - 1)]
  $listHtml = [string]::Join([Environment]::NewLine, $slice)

  $prevHref = if ($i -gt 1) { if ($i -eq 2) { "./" } else { "./page-$($i-1).html" } } else { $null }
  $nextHref = if ($i -lt $pages) { "./page-$($i+1).html" } else { $null }

  $prev = if ($prevHref) { ('<a class="pager-prev" href="{0}">&larr; Newer</a>' -f $prevHref) } else { '' }
  $next = if ($nextHref) { ('<a class="pager-next" href="{0}">Older &rarr;</a>' -f $nextHref) } else { '' }

  $nums = @()
  for ($n = 1; $n -le $pages; $n++) {
    $href = if ($n -eq 1) { './' } else { "./page-$n.html" }
    if ($n -eq $i) { $nums += "<strong>$n</strong>" } else { $nums += "<a href=""$href"">$n</a>" }
  }
  $numNav = ($nums -join ' ')
  $pagerHtml = @"
<nav class="pager">
  $prev
  <span class="pager-pages">$numNav</span>
  $next
</nav>
"@

  $h1 = if ($pages -gt 1) { "Blog &mdash; Page $i" } else { "Blog" }

  $content = @"
<!-- ASD:CONTENT_START -->
<h1>$h1</h1>
<ul class="posts">
$listHtml
</ul>
$pagerHtml
<!-- ASD:CONTENT_END -->
"@

  $outName = if ($i -eq 1) { 'index.html' } else { "page-$i.html" }
  Set-Content -Encoding UTF8 (Join-Path $BlogDir $outName) $content
  Write-Host ("[paginate] Wrote blog/{0} ({1} items)" -f $outName, $count)
}

Write-Host ("[paginate] Done. Pages: {0}, Items: {1}" -f $pages, $total)
