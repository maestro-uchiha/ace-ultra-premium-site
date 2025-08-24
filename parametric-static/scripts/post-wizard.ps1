<# 
  post-wizard.ps1
  Interactive helper to run common ASD tasks.
  - PowerShell 5.1 compatible
  - Uses config.json via _lib.ps1 helpers
#>

[CmdletBinding()]
param()

# Load config
$__here = Split-Path -Parent $PSCommandPath
. (Join-Path $__here "_lib.ps1")
$__cfg   = Get-ASDConfig
$Brand   = $__cfg.SiteName
$Money   = $__cfg.StoreUrl
$Desc    = $__cfg.Description
$Base    = $__cfg.BaseUrl
$__paths = Get-ASDPaths

Set-StrictMode -Version Latest
. "$PSScriptRoot\_lib.ps1"

$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

function Ask($prompt, $default="") {
  if ([string]::IsNullOrWhiteSpace($default)) {
    return Read-Host $prompt
  } else {
    $v = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $default } else { return $v }
  }
}

function Show-Menu {
  Write-Host ""
  Write-Host "ASD Wizard - pick an option:"
  Write-Host "  1) New post           2) Edit post            3) Rename post"
  Write-Host "  4) Delete post        5) Extract to drafts     6) Apply draft to post"
  Write-Host "  7) Redirects          8) Build pagination      9) Bake"
  Write-Host " 10) Build + Bake      11) Check links          12) List posts"
  Write-Host " 13) Open post         14) Edit config.json     q) Quit"
}

function Do-NewPost {
  $title = Ask "Title"
  $slug  = Ask "Slug (kebab-case)"
  $desc  = Ask "Description" ""
  $when  = Ask "ISO date (yyyy-MM-dd) or blank for today" ""

  $dateParam = @()
  if (-not [string]::IsNullOrWhiteSpace($when)) {
    try { $d = [datetime]::Parse($when) } catch { $d = Get-Date }
    $dateParam = @('-Date', $d)
  }

  & "$($S.PS)\new-post.ps1" -Title $title -Slug $slug -Description $desc @dateParam
}

function Do-EditPost {
  $slug = Ask "Slug to edit"
  $t = Ask "New Title (leave blank to keep)" ""
  $d = Ask "New Description (leave blank to keep)" ""
  $b = Ask "New BodyHtml (leave blank to keep)" ""

  $args = @('-Slug', $slug)
  if (-not [string]::IsNullOrWhiteSpace($t)) { $args += @('-Title', $t) }
  if (-not [string]::IsNullOrWhiteSpace($d)) { $args += @('-Description', $d) }
  if (-not [string]::IsNullOrWhiteSpace($b)) { $args += @('-BodyHtml', $b) }

  & "$($S.PS)\update-post.ps1" @args
}

function Do-RenamePost {
  $old = Ask "Old slug"
  $new = Ask "New slug"
  $keep = Ask "Leave redirect file in place? (y/N)" "N"
  $switch = @()
  if ($keep -match '^[Yy]') { $switch = @('-LeaveRedirect') }
  & "$($S.PS)\rename-post.ps1" -OldSlug $old -NewSlug $new @switch
}

function Do-DeletePost {
  $slug = Ask "Slug to delete"
  & "$($S.PS)\delete-post.ps1" -Slug $slug
}

function Do-Extract {
  $slug = Ask "Slug to extract to drafts"
  & "$($S.PS)\extract-post.ps1" -Slug $slug
}

function Do-ApplyDraft {
  $slug = Ask "Slug to apply draft to"
  & "$($S.PS)\apply-draft.ps1" -Slug $slug
}

function Do-Redirects {
  Write-Host ""
  Write-Host "Redirects:"
  Write-Host "  1) Add"
  Write-Host "  2) Remove by index"
  Write-Host "  3) Disable by index"
  Write-Host "  4) Enable by index"
  Write-Host "  5) List"
  $c = Read-Host "Choose 1-5"
  switch ($c) {
    '1' {
      $from = Ask "From path (e.g. /legacy or /old/*)"
      $to   = Ask "To URL or path (e.g. /blog/new.html)"
      $code = Ask "HTTP code (301 or 302)" "301"
      & "$($S.PS)\redirects.ps1" -Add -From $from -To $to -Code ([int]$code)
    }
    '2' {
      $i = Ask "Index to remove"
      & "$($S.PS)\redirects.ps1" -Remove -Index ([int]$i)
    }
    '3' {
      $i = Ask "Index to disable"
      & "$($S.PS)\redirects.ps1" -Disable -Index ([int]$i)
    }
    '4' {
      $i = Ask "Index to enable"
      & "$($S.PS)\redirects.ps1" -Enable -Index ([int]$i)
    }
    '5' {
      & "$($S.PS)\redirects.ps1" -List
    }
    default { Write-Host "Invalid choice." }
  }
}

function Do-BuildPagination {
  $size = Ask "Page size" "10"
  & "$($S.PS)\build-blog-index.ps1" -PageSize ([int]$size)
}

function Do-Bake { & "$($S.PS)\bake.ps1" }
function Do-BuildBake { & "$($S.PS)\build-and-bake.ps1" }
function Do-CheckLinks { & "$($S.PS)\check-links.ps1" }

function Do-ListPosts {
  if (-not (Test-Path $S.Blog)) { Write-Host "(no blog/ folder yet)"; return }
  Get-ChildItem -Path $S.Blog -Filter *.html -File | ForEach-Object {
    Write-Host $_.Name
  }
}

function Do-OpenPost {
  $slug = Ask "Slug to open in VS Code"
  $p = Join-Path $S.Blog ($slug + ".html")
  if (Test-Path $p) {
    Write-Host "[ASD] Opening $p in VS Code..."
    Start-Process code -ArgumentList @("--reuse-window","`"$p`"") -ErrorAction SilentlyContinue
  } else {
    Write-Warning "Post not found: $p"
  }
}

function Do-EditConfig {
  $cfgPath = Join-Path $S.Root "config.json"
  if (-not (Test-Path $cfgPath)) { $null = Get-ASDConfig -Root $S.Root } # will create default
  Write-Host "[ASD] Opening $cfgPath..."
  try { Start-Process code -ArgumentList @("--reuse-window","`"$cfgPath`"") } catch { notepad.exe $cfgPath }
}

while ($true) {
  Show-Menu
  $choice = Read-Host "Enter choice"
  switch ($choice) {
    '1'  { Do-NewPost }
    '2'  { Do-EditPost }
    '3'  { Do-RenamePost }
    '4'  { Do-DeletePost }
    '5'  { Do-Extract }
    '6'  { Do-ApplyDraft }
    '7'  { Do-Redirects }
    '8'  { Do-BuildPagination }
    '9'  { Do-Bake }
    '10' { Do-BuildBake }
    '11' { Do-CheckLinks }
    '12' { Do-ListPosts }
    '13' { Do-OpenPost }
    '14' { Do-EditConfig }
    'q'  { break }
    'Q'  { break }
    default { Write-Host "Unknown choice." }
  }
}
