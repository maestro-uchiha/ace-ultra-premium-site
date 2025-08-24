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

$here = $PSScriptRoot
& "$here\build-blog-index.ps1" -PageSize $PageSize
& "$here\bake.ps1"
