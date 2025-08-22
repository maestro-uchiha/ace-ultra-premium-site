param(
  [int]$PageSize = 10,
  [string]$Brand = "Brand Name",
  [string]$Money = "YOUR-DOMAIN.com"
)

$here = Split-Path -Parent $PSCommandPath
$root = Split-Path -Parent $here
Set-Location $root

Write-Host "[ASD] Build blog index (PageSize=$PageSize)…"
& "$here\build-blog-index.ps1" -PageSize $PageSize
if ($LASTEXITCODE -ne 0) { throw "build-blog-index failed" }

Write-Host "[ASD] Bake…"
& "$here\bake.ps1" -Brand $Brand -Money $Money
if ($LASTEXITCODE -ne 0) { throw "bake failed" }

Write-Host "[ASD] Done (paginate + bake)."
