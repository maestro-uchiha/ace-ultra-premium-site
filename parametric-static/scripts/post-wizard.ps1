<#
  post-wizard.ps1
  Interactive helper to run common ASD tasks.
  - PowerShell 5.1 compatible
  - Reads config.json via _lib.ps1 (single source of truth)
#>

[CmdletBinding()]
param()

# Load helpers (single source of truth)
$here = Split-Path -Parent $PSCommandPath
. (Join-Path $here "_lib.ps1")

Set-StrictMode -Version Latest

# Paths + config (ensures defaults and creates config.json if missing)
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

function Ask($prompt, $default = "") {
  if ([string]::IsNullOrWhiteSpace($default)) {
    return Read-Host $prompt
  } else {
    $v = Read-Host "$prompt [$default]"
    if ([string]::IsNullOrWhiteSpace($v)) { return $default } else { return $v }
  }
}

function Ask-YesNo($prompt, [bool]$defaultNo = $true) {
  $suffix = if ($defaultNo) { "(y/N)" } else { "(Y/n)" }
  $ans = Read-Host "$prompt $suffix"
  if ([string]::IsNullOrWhiteSpace($ans)) { return -not $defaultNo }
  return ($ans -match '^[Yy]')
}

function Show-Menu {
  Write-Host ""
  Write-Host "ASD Wizard - pick an option:"
  Write-Host "  1) New post           2) Edit post            3) Rename post"
  Write-Host "  4) Delete post        5) Extract to drafts     6) Apply draft to post"
  Write-Host "  7) Redirects          8) Build pagination      9) Bake"
  Write-Host " 10) Build + Bake      11) Check links          12) List posts"
  Write-Host " 13) Open post         14) Edit config.json     15) Commit all (git)"
  Write-Host "  q) Quit"
}

function Do-NewPost {
  $title = Ask "Title"
  $slug  = Ask "Slug (kebab-case)"
  $desc  = Ask "Description" ""
  $when  = Ask "ISO date (yyyy-MM-dd) or blank for today" ""

  $params = @{ Title = $title; Slug = $slug; Description = $desc }

  if (-not [string]::IsNullOrWhiteSpace($when)) {
    try { $d = [datetime]::Parse($when) } catch { $d = Get-Date }
    try {
      & "$($S.PS)\new-post.ps1" @params -Date $d
    } catch {
      # Fallback if your new-post.ps1 doesn't support -Date
      & "$($S.PS)\new-post.ps1" @params
    }
  } else {
    & "$($S.PS)\new-post.ps1" @params
  }
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
  $keep = Ask-YesNo "Leave redirect file in place?" $true
  $switch = @()
  if ($keep) { $switch = @('-LeaveRedirect') }
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

function Do-Bake       { & "$($S.PS)\bake.ps1" }
function Do-BuildBake  { & "$($S.PS)\build-and-bake.ps1" }
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
    try {
      Start-Process code -ArgumentList @("--reuse-window","`"$p`"") -ErrorAction Stop
    } catch {
      Write-Warning "VS Code not found on PATH. Opening in Notepad."
      notepad.exe $p
    }
  } else {
    Write-Warning "Post not found: $p"
  }
}

function Do-EditConfig {
  $cfgPath = Join-Path $S.Root "config.json"
  if (-not (Test-Path $cfgPath)) { $null = Get-ASDConfig -Root $S.Root } # ensure exists
  Write-Host "[ASD] Opening $cfgPath..."
  try {
    Start-Process code -ArgumentList @("--reuse-window","`"$cfgPath`"") -ErrorAction Stop
  } catch {
    notepad.exe $cfgPath
  }
}

# ------- Git helpers (robust; avoid $args name collision) -------
function Test-GitAvailable {
  try {
    $null = (& git --version) 2>$null
    return ($LASTEXITCODE -eq 0)
  } catch { return $false }
}

function Test-InGitRepo {
  try {
    $null = (& git rev-parse --is-inside-work-tree) 2>$null
    return ($LASTEXITCODE -eq 0)
  } catch { return $false }
}

function Git-Run([string[]]$GitArgs, [switch]$Capture) {
  if ($Capture) {
    $out = & git @GitArgs 2>&1
    $code = $LASTEXITCODE
    return @{ code = $code; out = $out }
  } else {
    & git @GitArgs
    return @{ code = $LASTEXITCODE; out = $null }
  }
}

function Get-GitRoot {
  try {
    $root = (& git rev-parse --show-toplevel) 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($root)) { return $root }
  } catch {}
  return $null
}

function Do-CommitAll {
  if (-not (Test-GitAvailable)) {
    Write-Error "git is not installed or not on PATH. Install Git and retry."
    return
  }

  # Prefer the actual repo root, else fallback to project root
  $repoRoot = Get-GitRoot
  if (-not $repoRoot) {
    if (-not (Ask-YesNo "This folder isn't a git repo. Initialize one at '$($S.Root)'?")) { return }
    Push-Location $S.Root
    try {
      $init = Git-Run -GitArgs @('init') -Capture
      if ($init.code -ne 0) { Write-Error "git init failed:`n$($init.out)"; return }
      $bm = Git-Run -GitArgs @('branch','-M','main') -Capture
      if ($bm.code -ne 0) { Write-Warning "Could not set default branch to 'main':`n$($bm.out)" }
      Write-Host "[ASD] Git repository initialized at $($S.Root)."
    } finally { Pop-Location }
    $repoRoot = $S.Root
  }

  Push-Location $repoRoot
  try {
    & git status

    # Stage everything from the repo root
    $add = Git-Run -GitArgs @('add','-A','--','.') -Capture
    if ($add.code -ne 0) {
      Write-Error "git add failed:`n$($add.out)"
      return
    }

    # Any staged changes?
    $staged = (& git diff --cached --name-only) 2>$null
    if ([string]::IsNullOrWhiteSpace($staged)) {
      Write-Host "[ASD] Nothing staged; nothing to commit."
      return
    }

    # Commit
    $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
    $defaultMsg = "asd: batch changes ($ts)"
    $msg = Ask "Commit message" $defaultMsg
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $defaultMsg }

    $commit = Git-Run -GitArgs @('commit','-m', $msg) -Capture
    if ($commit.code -ne 0) {
      Write-Error "git commit failed:`n$($commit.out)"
      return
    }
    Write-Host "[ASD] Commit created."

    # Optional tag
    if (Ask-YesNo "Create a tag?") {
      $defaultTag = ""
      if ($cfg -and $cfg.PSObject.Properties.Name -contains 'Version' -and -not [string]::IsNullOrWhiteSpace($cfg.Version)) {
        $defaultTag = "v$($cfg.Version)"
      } else {
        $defaultTag = "v" + (Get-Date -Format "yyyy.MM.dd.HHmm")
      }
      $tag = Ask "Tag name" $defaultTag
      if (-not [string]::IsNullOrWhiteSpace($tag)) {
        $tagres = Git-Run -GitArgs @('tag','-a', $tag, '-m', $tag) -Capture
        if ($tagres.code -ne 0) { Write-Warning "git tag failed:`n$($tagres.out)" } else { Write-Host "[ASD] Tag '$tag' created." }
      }
    }

    # Optional push
    if (Ask-YesNo "Push to remote? (requires your git remote auth)") {
      $push = Git-Run -GitArgs @('push') -Capture
      if ($push.code -ne 0) { Write-Warning "git push failed:`n$($push.out)" } else { Write-Host "[ASD] Pushed commits." }
      if (Ask-YesNo "Push tags too?") {
        $pt = Git-Run -GitArgs @('push','--tags') -Capture
        if ($pt.code -ne 0) { Write-Warning "git push --tags failed:`n$($pt.out)" } else { Write-Host "[ASD] Pushed tags." }
      }
    }

  } finally {
    Pop-Location
  }
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
    '15' { Do-CommitAll }
    'q'  { break }
    'Q'  { break }
    default { Write-Host "Unknown choice." }
  }
}
