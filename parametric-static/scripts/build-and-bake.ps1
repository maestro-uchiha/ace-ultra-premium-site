# Amaterasu Static Deploy — build-and-bake.ps1
# Runs: blog pagination -> bake (tokens/layout) -> optional link check
param(
  [int]$PageSize = 10,
  [string]$Brand,
  [string]$Money,
  [switch]$CheckLinks
)

$ErrorActionPreference = 'Stop'

# Paths
$ScriptsDir = Split-Path -Parent $PSCommandPath
$Root       = Split-Path -Parent $ScriptsDir
$BuildIdx   = Join-Path $ScriptsDir 'build-blog-index.ps1'
$Bake       = Join-Path $ScriptsDir 'bake.ps1'
$Check      = Join-Path $ScriptsDir 'check-links.ps1'
$BakeCfg    = Join-Path $Root 'bake-config.json'

Write-Host "[ASD] build-and-bake starting…"
Write-Host ("[ASD] root: {0}" -f $Root)

if (-not (Test-Path $BuildIdx)) { throw "Missing script: $BuildIdx" }
if (-not (Test-Path $Bake))     { throw "Missing script: $Bake" }

# If Brand/Money not supplied, try bake-config.json
if ((-not $PSBoundParameters.ContainsKey('Brand') -or -not $PSBoundParameters.ContainsKey('Money')) -and (Test-Path $BakeCfg)) {
  try {
    $cfg = Get-Content $BakeCfg -Raw | ConvertFrom-Json
    if (-not $PSBoundParameters.ContainsKey('Brand') -and $cfg.brand) { $Brand = $cfg.brand }
    if (-not $PSBoundParameters.ContainsKey('Money') -and $cfg.url)   { $Money = $cfg.url }
  } catch {
    Write-Host "[ASD] Warning: bake-config.json could not be parsed; continuing with supplied/default args."
  }
}

# Normalize Money to absolute URL
if ($Money) {
  $Money = $Money.Trim()
  if ($Money -notmatch '^(https?:)?//') { $Money = "https://$Money" }
}

# 1) Build paginated blog index
Write-Host ("[ASD] running: build-blog-index.ps1 -PageSize {0}" -f $PageSize)
& $BuildIdx -PageSize $PageSize

# 2) Bake (assemble args only if values present)
$bakeArgs = @()
if ($Brand) { $bakeArgs += @('-Brand', $Brand) }
if ($Money) { $bakeArgs += @('-Money', $Money) }

Write-Host ("[ASD] running: bake.ps1 {0}" -f ($bakeArgs -join ' '))
& $Bake @bakeArgs

# 3) Optional link check
if ($CheckLinks) {
  if (Test-Path $Check) {
    Write-Host "[ASD] running: check-links.ps1"
    & $Check
  } else {
    Write-Host "[ASD] Skipping link check (script not found)."
  }
}

Write-Host "[ASD] build-and-bake complete."
