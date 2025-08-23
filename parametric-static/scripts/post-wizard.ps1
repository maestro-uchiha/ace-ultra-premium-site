param(
  [ValidateSet("New","Edit","Rename","Delete")]
  [string]$Mode,
  [switch]$DryRun
)

$root = (Resolve-Path "$PSScriptRoot/..").Path
Set-Location $root

function Ask($label, $def="") {
  if ($def -ne "") { $label = "$label [$def]" }
  $v = Read-Host $label
  if ([string]::IsNullOrWhiteSpace($v)) { return $def } else { return $v }
}
function Confirm($q, $defNo=$true) {
  $ans = Read-Host "$q (y/N)"
  return ($ans -match '^(y|yes)$')
}

if (-not $Mode) {
  Write-Host "Select mode: 1) New  2) Edit  3) Rename  4) Delete"
  $ch = Read-Host "Enter 1-4"
  $Mode = @("New","Edit","Rename","Delete")[[int]$ch-1]
}

switch ($Mode) {
  "New" {
    $title = Ask "Title" "New Post"
    $slug  = Ask "Slug (kebab-case)" (($title.ToLower() -replace '[^a-z0-9]+','-').Trim('-'))
    $desc  = Ask "Short description" "Short description for this article."
    $body  = Ask "BodyPath (.md/.html) (optional)" ""
    $cmd = @("& `"$PSScriptRoot/new-post.ps1`" -Title `"$title`" -Slug `"$slug`" -Description `"$desc`"")
    if ($body) { $cmd += @(" -BodyPath `"$body`"") }
    $cmdLine = ($cmd -join "")
    Write-Host "`n[ASD] To run:"; Write-Host "  $cmdLine"
    if (-not $DryRun -and (Confirm "Run it now?")) { Invoke-Expression $cmdLine }
  }
  "Edit" {
    $slug  = Ask "Slug"
    $title = Ask "New Title (optional)" ""
    $desc  = Ask "New Description (optional)" ""
    $body  = Ask "BodyPath (.md/.html) (optional)" ""
    $cmd = @("& `"$PSScriptRoot/update-post.ps1`" -Slug `"$slug`" -TouchFileTime")
    if ($title) { $cmd += @(" -Title `"$title`"") }
    if ($desc)  { $cmd += @(" -Description `"$desc`"") }
    if ($body)  { $cmd += @(" -BodyPath `"$body`"") }
    $cmdLine = ($cmd -join "")
    Write-Host "`n[ASD] To run:"; Write-Host "  $cmdLine"
    if (-not $DryRun -and (Confirm "Run it now?")) { Invoke-Expression $cmdLine }
  }
  "Rename" {
    $old = Ask "Old slug"
    $new = Ask "New slug"
    $title = Ask "New Title (optional)" ""
    $keep  = Confirm "Leave redirect from old → new?"
    $cmd = @("& `"$PSScriptRoot/rename-post.ps1`" -OldSlug `"$old`" -NewSlug `"$new`"")
    if ($title) { $cmd += @(" -Title `"$title`"") }
    if ($keep)  { $cmd += @(" -LeaveRedirect") }
    $cmdLine = ($cmd -join "")
    Write-Host "`n[ASD] To run:"; Write-Host "  $cmdLine"
    if (-not $DryRun -and (Confirm "Run it now?")) { Invoke-Expression $cmdLine }
  }
  "Delete" {
    $slug = Ask "Slug to delete"
    $cmdLine = "& `"$PSScriptRoot/delete-post.ps1`" -Slug `"$slug`""
    Write-Host "`n[ASD] To run:"; Write-Host "  $cmdLine"
    if (-not $DryRun -and (Confirm "Run it now?")) { Invoke-Expression $cmdLine }
  }
}

# Optional follow-up
if (Confirm "Build pagination and bake now?") {
  $page = Ask "Posts per page" "10"
  $brand = Ask "Brand for bake" "Ace Ultra Premium"
  $money = Ask "Money site URL" "https://acecartstore.com"
  $chain = "& `"$PSScriptRoot/build-blog-index.ps1`" -PageSize $page; & `"$PSScriptRoot/bake.ps1`" -Brand `"$brand`" -Money `"$money`""
  Write-Host "`n[ASD] To run:"; Write-Host "  $chain"
  if (-not $DryRun -and (Confirm "Run it now?")) { Invoke-Expression $chain }
}

Write-Host "`n[ASD] Done."
