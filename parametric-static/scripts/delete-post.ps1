param([Parameter(Mandatory=$true)][string]$Slug)

$Root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
Set-Location $Root

function Get-Domain {
  if (Test-Path ".\config.json") {
    try { $cfg = Get-Content .\config.json -Raw | ConvertFrom-Json; if ($cfg.site.url) { return ($cfg.site.url.TrimEnd('/') + '/') } } catch {}
  }
  return "https://YOUR-DOMAIN.example/"
}

$postPath = Join-Path $Root ("blog\" + $Slug + ".html")
if (-not (Test-Path $postPath)) { Write-Error "Post not found: $postPath"; exit 1 }

Remove-Item $postPath -Force
Write-Host "[ASD] Deleted blog/$Slug.html"

# Remove from feed.xml
$dom = Get-Domain
$feedPath = Join-Path $Root "feed.xml"
if (Test-Path $feedPath) {
  try {
    [xml]$rss = Get-Content $feedPath
    $chan = $rss.rss.channel
    $postUrl = ($dom.TrimEnd('/') + "/blog/$Slug.html")
    $toRemove = @()
    foreach($it in $chan.item) { if ($it.link -and $it.link -eq $postUrl) { $toRemove += $it } }
    foreach($n in $toRemove) { $null = $chan.RemoveChild($n) }
    $rss.Save($feedPath)
    Write-Host "[ASD] feed.xml cleaned"
  } catch { Write-Warning "[ASD] Could not update feed.xml: $_" }
}

# --- Friendly manual-next-step hint (does not execute bake)
$brandHint = "Your Brand"
$moneyHint = "https://your-domain.com"
try {
  if ($cfg) {
    if ($cfg.site -and $cfg.site.name) { $brandHint = $cfg.site.name }
    elseif ($cfg.brand) { $brandHint = $cfg.brand }
    if ($cfg.moneySite) { $moneyHint = $cfg.moneySite }
  }
} catch {}
Write-Host "`n[ASD] Next (manual):"
Write-Host ("  .\parametric-static\scripts\bake.ps1 -Brand ""{0}"" -Money ""{1}""" -f $brandHint, $moneyHint)