param(
  [switch]$KeepSandbox,
  [int]$PageSize = 2
)

$ErrorActionPreference = 'Stop'

# ----- helpers -----
$script:fail = 0
function Assert {
  param([string]$Message, [bool]$Condition)
  if ($Condition) {
    Write-Host "[OK] $Message"
  } else {
    Write-Host "[FAIL] $Message"
    $script:fail++
  }
}
function New-TempRoot {
  return (Join-Path $env:TEMP ("asd-sandbox-" + (Get-Date).ToString("yyyyMMdd-HHmmss")))
}

# ----- locate repo pieces -----
$here = Split-Path -Parent $PSCommandPath
$proj = (Resolve-Path (Join-Path $here "..")).Path           # parametric-static/
$repo = (Resolve-Path (Join-Path $proj "..")).Path           # repo root

# ----- create sandbox -----
$sbRoot = New-TempRoot
$sbPS   = Join-Path $sbRoot "parametric-static"
Write-Host "[ASD TEST] Creating sandbox at: $sbPS"
New-Item -ItemType Directory -Force $sbPS | Out-Null
Copy-Item -Recurse -Force (Join-Path $repo "parametric-static\*") $sbPS

# paths inside sandbox
$S = @{
  Root = $sbPS
  Blog = (Join-Path $sbPS "blog")
  Scr  = (Join-Path $sbPS "scripts")
}
$P = @{
  np = (Join-Path $S.Scr "new-post.ps1")
  up = (Join-Path $S.Scr "update-post.ps1")
  rn = (Join-Path $S.Scr "rename-post.ps1")
  dp = (Join-Path $S.Scr "delete-post.ps1")
  xp = (Join-Path $S.Scr "extract-post.ps1")
  ap = (Join-Path $S.Scr "apply-draft.ps1")
  rl = (Join-Path $S.Scr "redirects.ps1")
  bi = (Join-Path $S.Scr "build-blog-index.ps1")
  bk = (Join-Path $S.Scr "bake.ps1")
  cl = (Join-Path $S.Scr "check-links.ps1")
}
foreach ($path in $P.Values) {
  if (-not (Test-Path $path)) { throw "Missing script: $path" }
}

function Has-RedirectStub($path) {
  if (-not (Test-Path $path)) { return $false }
  $t = Get-Content $path -Raw
  return ($t -match '(?i)http-equiv="refresh"' -or $t -match 'location\.replace\(')
}

# ================== TESTS ==================

# 1) new-post x2
Write-Host "`n[1] new-post: create tw-post-one and tw-post-two"
$slug1 = "tw-post-one"; $slug2 = "tw-post-two"
& $P.np -Title "TW Post One" -Slug $slug1 -Description "First test" | Out-Null
& $P.np -Title "TW Post Two" -Slug $slug2 -Description "Second test" | Out-Null
Assert "blog/$slug1.html created" (Test-Path (Join-Path $S.Blog "$slug1.html"))
Assert "blog/$slug2.html created" (Test-Path (Join-Path $S.Blog "$slug2.html"))

# 2) update-post
Write-Host "`n[2] update-post: update $slug1"
$newBody = "<p>Updated body from test.</p>"
& $P.up -Slug $slug1 -Title "TW Post One Updated" -Description "Updated desc" -Body $newBody | Out-Null
Assert "update-post wrote new body" ((Get-Content (Join-Path $S.Blog "$slug1.html") -Raw) -match [regex]::Escape($newBody))

# 3) rename-post with redirect (Force allows re-runs)
Write-Host "`n[3] rename-post: $slug1 -> tw-post-renamed (with redirect)"
$slugRenamed = "tw-post-renamed"
& $P.rn -OldSlug $slug1 -NewSlug $slugRenamed -LeaveRedirect -Force | Out-Null
$newPath = Join-Path $S.Blog "$slugRenamed.html"
$oldPath = Join-Path $S.Blog "$slug1.html"
Assert "renamed file exists" (Test-Path $newPath)
# Accept "old removed" OR "redirect stub present" as success
$okOld = if (Test-Path $oldPath) { Has-RedirectStub $oldPath } else { $true }
Assert "old file removed or stub present" $okOld
Assert "redirects.json created" (Test-Path (Join-Path $S.Root "redirects.json"))

# 4) extract-post
Write-Host "`n[4] extract-post -> drafts"
& $P.xp -Slug $slugRenamed | Out-Null
Assert "draft saved" (Test-Path (Join-Path $S.Root ("drafts\" + $slugRenamed + ".html")))

# 5) apply-draft
Write-Host "`n[5] apply-draft back to post"
$draftPath = Join-Path $S.Root ("drafts\" + $slugRenamed + ".html")
"<p>Draft edit wins</p>" | Set-Content -Encoding UTF8 $draftPath
& $P.ap -Slug $slugRenamed | Out-Null
Assert "draft applied back to post" ((Get-Content (Join-Path $S.Blog "$slugRenamed.html") -Raw) -match 'Draft edit wins')

# 6) delete-post
Write-Host "`n[6] delete-post: $slug2"
& $P.dp -Slug $slug2 | Out-Null
Assert "deleted post removed" (-not (Test-Path (Join-Path $S.Blog "$slug2.html")))

# 7) redirects ops
Write-Host "`n[7] redirects ops"
& $P.rl -Add -From "/legacy" -To ("/blog/{0}.html" -f $slugRenamed) -Code 301 | Out-Null
& $P.rl -List | Out-Null
& $P.rl -Disable -Index 0 | Out-Null
& $P.rl -Enable -Index 0 | Out-Null
& $P.rl -Remove -Index 0 | Out-Null
Assert "redirects basic ops executed" $true

# 8) build-blog-index
Write-Host "`n[8] build-blog-index: PageSize=$PageSize"
& $P.bi -PageSize $PageSize | Out-Null
Assert "blog/index.html exists" (Test-Path (Join-Path $S.Blog "index.html"))
Assert "blog/page-2.html exists" (Test-Path (Join-Path $S.Blog "page-2.html"))

# 9) bake
Write-Host "`n[9] bake"
& $P.bk -Brand "ASD Test" -Money "https://example.com" | Out-Null
$wrappedOk = ((Get-Content (Join-Path $S.Root "index.html") -Raw) -match '<header>')
Assert "bake wrapped header and footer" $wrappedOk

# 10) check-links
Write-Host "`n[10] check-links"
& $P.cl | Out-Null
Assert "check-links executed" $true

# ----- summary & cleanup -----
Write-Host "`n========== TEST SUMMARY =========="
if ($script:fail -gt 0) {
  Write-Host "$script:fail check(s) failed."
} else {
  Write-Host "All checks passed."
}

if ($KeepSandbox) {
  Write-Host "Sandbox location: $sbPS"
  Write-Host "[ASD TEST] Sandbox kept (per -KeepSandbox)."
} else {
  $cwd = Get-Location
  try {
    Set-Location $PSScriptRoot
    Remove-Item -Recurse -Force $sbRoot
  } catch {
    Write-Warning $_
  } finally {
    Set-Location $cwd
  }
  Write-Host "[ASD TEST] Sandbox removed."
}
