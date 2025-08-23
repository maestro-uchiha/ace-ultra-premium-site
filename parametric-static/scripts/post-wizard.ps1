param(
  [ValidateSet(
    "Menu","New","Edit","Rename","Delete","Extract","Apply",
    "Redirects","Build","Bake","BuildBake","CheckLinks",
    "ListPosts","OpenPost","Config","Git"
  )]
  [string]$Mode = "Menu",
  [switch]$DryRun
)

# ---------------------------------------
# Paths
# ---------------------------------------
$Root = (Resolve-Path "$PSScriptRoot/..").Path
$Blog = Join-Path $Root "blog"
$Cfg  = Join-Path $Root "config.json"
Set-Location $Root

# ---------------------------------------
# Helpers
# ---------------------------------------
function Ask($label, $def="") {
  if ($def -ne "") { $label = "$label [$def]" }
  $v = Read-Host $label
  if ([string]::IsNullOrWhiteSpace($v)) { return $def } else { return $v }
}

function Confirm($q) {
  $ans = Read-Host "$q (y/N)"
  return ($ans -match '^(y|yes)$')
}

function Normalize-Slug($s) {
  if ($s -match '[\\/]|\.html$') { $s = [IO.Path]::GetFileNameWithoutExtension($s) }
  $s = $s -replace '[\u2013\u2014]','-'   # en/em dash -> hyphen
  $s = $s -replace '\s+','-'
  $s.Trim('-').ToLower()
}

function Run($cmd) {
  Write-Host "`n[ASD] To run:"
  Write-Host "  $cmd"
  if (-not $DryRun -and (Confirm "Run it now?")) {
    Invoke-Expression $cmd
  }
}

function Get-Config() {
  $obj = $null
  if (Test-Path $Cfg) {
    try { $obj = Get-Content $Cfg -Raw | ConvertFrom-Json } catch {}
  }
  return $obj
}

function Default-Brand() {
  $c = Get-Config
  if ($c -and $c.site -and $c.site.name) { return $c.site.name }
  if ($c -and $c.brand) { return $c.brand }
  return "Ace Ultra Premium"
}

function Default-Money() {
  $c = Get-Config
  if ($c -and $c.moneySite) { return $c.moneySite }
  if ($c -and $c.site -and $c.site.url) { return $c.site.url }
  return "https://acecartstore.com"
}

function List-Posts() {
  if (!(Test-Path $Blog)) { return @() }
  return Get-ChildItem -Path $Blog -Filter *.html -File |
    Where-Object { $_.Name -notin @("index.html") -and $_.Name -notmatch '^page-\d+\.html$' } |
    Sort-Object LastWriteTime -Descending
}

# ---------------------------------------
# Actions
# ---------------------------------------
function Do-New() {
  $title = Ask "Title" "New Post"
  $slug  = Normalize-Slug (Ask "Slug (kebab-case)" (($title.ToLower() -replace '[^a-z0-9]+','-').Trim('-')))
  $desc  = Ask "Short description" "Short description for this article."
  $body  = Ask "BodyPath (.md/.html) (optional)" ""
  $cmd = "& `"$PSScriptRoot/new-post.ps1`" -Title `"$title`" -Slug `"$slug`" -Description `"$desc`""
  if ($body) { $cmd += " -BodyPath `"$body`"" }
  Run $cmd
}

function Do-Edit() {
  $slug = Normalize-Slug (Ask "Slug")
  $title = Ask "New Title (optional)" ""
  $desc  = Ask "New Description (optional)" ""
  $body  = Ask "BodyPath (.md/.html) (optional)" ""
  $cmd = "& `"$PSScriptRoot/update-post.ps1`" -Slug `"$slug`" -TouchFileTime"
  if ($title) { $cmd += " -Title `"$title`"" }
  if ($desc)  { $cmd += " -Description `"$desc`"" }
  if ($body)  { $cmd += " -BodyPath `"$body`"" }
  Run $cmd
}

function Do-Rename() {
  $old = Normalize-Slug (Ask "Old slug")
  $new = Normalize-Slug (Ask "New slug")
  $title = Ask "New Title (optional)" ""
  $keep  = Confirm "Leave redirect from old -> new?"
  $cmd = "& `"$PSScriptRoot/rename-post.ps1`" -OldSlug `"$old`" -NewSlug `"$new`""
  if ($title) { $cmd += " -Title `"$title`"" }
  if ($keep)  { $cmd += " -LeaveRedirect" }
  Run $cmd
}

function Do-Delete() {
  $slug = Normalize-Slug (Ask "Slug to delete")
  $cmd = "& `"$PSScriptRoot/delete-post.ps1`" -Slug `"$slug`""
  Run $cmd
}

function Do-Extract() {
  $slug = Normalize-Slug (Ask "Slug to extract to drafts")
  $open = Confirm "Open in VS Code after extract?"
  $cmd = "& `"$PSScriptRoot/extract-post.ps1`" -Slug `"$slug`""
  if ($open) { $cmd += " -Open" }
  Run $cmd
}

function Do-ApplyDraft() {
  $slug = Normalize-Slug (Ask "Slug to apply draft for")
  $path = Ask "DraftPath (leave blank for drafts/<slug>.html)" ""
  $cmd = "& `"$PSScriptRoot/apply-draft.ps1`" -Slug `"$slug`""
  if ($path) { $cmd += " -DraftPath `"$path`"" }
  Run $cmd
}

function Do-Redirects() {
  Write-Host "`nRedirects:"
  Write-Host "  1) Add"
  Write-Host "  2) Remove by index"
  Write-Host "  3) List"
  $ch = Read-Host "Choose 1-3"
  switch ($ch) {
    '1' {
      $from = Ask "From (e.g. /old or /blog/old.html)"
      $to   = Ask "To (URL or path)"
      $code = Ask "HTTP code (301/302)" "301"
      $cmd  = "& `"$PSScriptRoot/redirects.ps1`" -Add -From `"$from`" -To `"$to`" -Code $code"
      Run $cmd
    }
    '2' {
      $idx = Ask "Index to remove (see list)" ""
      $cmd = "& `"$PSScriptRoot/redirects.ps1`" -Remove -Index $idx"
      Run $cmd
    }
    default {
      $cmd = "& `"$PSScriptRoot/redirects.ps1`" -List"
      Run $cmd
    }
  }
}

function Do-Build() {
  $size = Ask "Posts per page" "10"
  $cmd = "& `"$PSScriptRoot/build-blog-index.ps1`" -PageSize $size"
  Run $cmd
}

function Do-Bake() {
  $brand = Ask "Brand for bake" (Default-Brand)
  $money = Ask "Money site URL" (Default-Money)
  $cmd   = "& `"$PSScriptRoot/bake.ps1`" -Brand `"$brand`" -Money `"$money`""
  Run $cmd
}

function Do-BuildBake() {
  $size  = Ask "Posts per page" "10"
  $brand = Ask "Brand for bake" (Default-Brand)
  $money = Ask "Money site URL" (Default-Money)
  $cmd = "& `"$PSScriptRoot/build-blog-index.ps1`" -PageSize $size; & `"$PSScriptRoot/bake.ps1`" -Brand `"$brand`" -Money `"$money`""
  Run $cmd
}

function Do-CheckLinks() {
  $cmd = "& `"$PSScriptRoot/check-links.ps1`""
  Run $cmd
}

function Do-ListPosts() {
  $items = List-Posts
  if ($items.Count -eq 0) { Write-Host "[ASD] No posts found."; return }
  Write-Host "`nPosts (most recent first):"
  $i=1
  foreach ($f in $items) {
    Write-Host ("  {0}. {1}  (modified {2:yyyy-MM-dd})" -f $i, $f.Name, $f.LastWriteTime)
    $i++
  }
}

function Do-OpenPost() {
  $slug = Normalize-Slug (Ask "Slug to open in VS Code")
  $path = Join-Path $Blog ($slug + ".html")
  if (!(Test-Path $path)) {
    $cand = Get-ChildItem -Path $Blog -Filter *.html -File |
      Where-Object { $_.BaseName -ieq $slug } |
      Select-Object -First 1
    if ($cand) { $path = $cand.FullName }
  }
  if (Test-Path $path) {
    Write-Host "[ASD] Opening $path in VS Code..."
    & code -r $path
  } else {
    Write-Error "Post not found."
  }
}

function Do-Config() {
  $c = Get-Config

  # Compute defaults without inline if-expressions in parentheses
  $brandDef = "Ace Ultra Premium"
  if ($c) {
    if ($c.site -and $c.site.name) { $brandDef = $c.site.name }
    elseif ($c.brand) { $brandDef = $c.brand }
  }

  $urlDef = ""
  if ($c -and $c.site -and $c.site.url) { $urlDef = $c.site.url }

  $moneyDef = $urlDef
  if ($c -and $c.moneySite) { $moneyDef = $c.moneySite }

  # Ask user
  $brand = Ask "Brand (config.site.name)" $brandDef
  $url   = Ask "Site URL (config.site.url)" $urlDef
  $money = Ask "Money site (legacy config.moneySite)" $moneyDef

  # Write config
  if (-not $c) { $c = [pscustomobject]@{} }
  if (-not ($c | Get-Member -Name site -MemberType NoteProperty)) {
    $c | Add-Member -NotePropertyName site -NotePropertyValue ([pscustomobject]@{})
  }
  $c.site.name = $brand
  $c.site.url  = $url
  $c.moneySite = $money

  $json = $c | ConvertTo-Json -Depth 12
  Set-Content -Encoding UTF8 $Cfg $json
  Write-Host "[ASD] config.json updated."
}

function Do-Git() {
  Write-Host "`nGit:"
  Write-Host "  1) Status"
  Write-Host "  2) Add all + Commit + Push"
  $ch = Read-Host "Choose 1-2"
  switch ($ch) {
    '1' { git status }
    default {
      $msg = Ask "Commit message" "content: update"
      $chain = "git add .; git commit -m `"$msg`"; git push"
      Run $chain
    }
  }
}

# ---------------------------------------
# Menu
# ---------------------------------------
function Show-Menu() {
  Write-Host ""
  Write-Host "ASD Wizard - pick an option:"
  Write-Host "  1) New post           2) Edit post            3) Rename post"
  Write-Host "  4) Delete post        5) Extract to drafts     6) Apply draft to post"
  Write-Host "  7) Redirects          8) Build pagination      9) Bake"
  Write-Host " 10) Build + Bake      11) Check links          12) List posts"
  Write-Host " 13) Open post         14) Config (brand/url)   15) Git"
  Write-Host "  q) Quit"
  $ch = Read-Host "Enter choice"
  switch ($ch) {
    '1'  { Do-New }
    '2'  { Do-Edit }
    '3'  { Do-Rename }
    '4'  { Do-Delete }
    '5'  { Do-Extract }
    '6'  { Do-ApplyDraft }
    '7'  { Do-Redirects }
    '8'  { Do-Build }
    '9'  { Do-Bake }
    '10' { Do-BuildBake }
    '11' { Do-CheckLinks }
    '12' { Do-ListPosts }
    '13' { Do-OpenPost }
    '14' { Do-Config }
    '15' { Do-Git }
    'q'  { return $false }
    default { Write-Host "Invalid choice." }
  }
  return $true
}

# ---------------------------------------
# Direct mode or interactive
# ---------------------------------------
switch ($Mode) {
  "New"       { Do-New }
  "Edit"      { Do-Edit }
  "Rename"    { Do-Rename }
  "Delete"    { Do-Delete }
  "Extract"   { Do-Extract }
  "Apply"     { Do-ApplyDraft }
  "Redirects" { Do-Redirects }
  "Build"     { Do-Build }
  "Bake"      { Do-Bake }
  "BuildBake" { Do-BuildBake }
  "CheckLinks"{ Do-CheckLinks }
  "ListPosts" { Do-ListPosts }
  "OpenPost"  { Do-OpenPost }
  "Config"    { Do-Config }
  "Git"       { Do-Git }
  default {
    while (Show-Menu) { Start-Sleep -Milliseconds 150 }
  }
}

Write-Host "`n[ASD] Done."
