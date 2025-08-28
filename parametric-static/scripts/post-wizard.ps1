<#
  post-wizard.ps1
  Interactive helper to run common ASD tasks.
  - PowerShell 5.1 compatible
  - Reads config.json via _lib.ps1 (single source of truth)
#>

#requires -Version 5.1
[CmdletBinding()]
param()

$ScriptsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptsDir "_lib.ps1")

# PS 5.1-safe strict mode
Set-StrictMode -Version 2.0

# Paths + config
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

function Ask {
  param([string]$Prompt, [string]$Default = "")
  if ([string]::IsNullOrWhiteSpace($Default)) {
    return (Read-Host $Prompt)
  } else {
    $v = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
    if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v }
  }
}

function Ask-YesNo {
  param([string]$Prompt, [bool]$DefaultNo = $true)
  $suffix = ""
  if ($DefaultNo) { $suffix = "(y/N)" } else { $suffix = "(Y/n)" }
  $ans = Read-Host ("{0} {1}" -f $Prompt, $suffix)
  if ([string]::IsNullOrWhiteSpace($ans)) { return (-not $DefaultNo) }
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
  Write-Host " -- Pages ------------------------------------------------------------"
  Write-Host " 16) New page          17) Edit page            18) Rename page"
  Write-Host " 19) Delete page       20) List pages"
  Write-Host "  q) Quit"
}

# ---------------- Posts actions ----------------

function Do-NewPost {
  $title = Ask "Title"
  $slug  = Ask "Slug (kebab-case)"
  $desc  = Ask "Description" ""
  $when  = Ask "ISO date (yyyy-MM-dd) or blank for today" ""

  $newPostPath = Join-Path $ScriptsDir "new-post.ps1"
  if (-not [string]::IsNullOrWhiteSpace($when)) {
    try { $d = [datetime]::Parse($when) } catch { $d = Get-Date }
    try { & $newPostPath -Title $title -Slug $slug -Description $desc -Date $d }
    catch { & $newPostPath -Title $title -Slug $slug -Description $desc }
  } else {
    & $newPostPath -Title $title -Slug $slug -Description $desc
  }
}

function Do-EditPost {
  $slug = Ask "Slug to edit"
  $t = Ask "New Title (leave blank to keep)" ""
  $d = Ask "New Description (leave blank to keep)" ""
  $b = Ask "New BodyHtml (leave blank to keep)" ""

  $callArgs = @('-Slug', $slug)
  if (-not [string]::IsNullOrWhiteSpace($t)) { $callArgs += @('-Title', $t) }
  if (-not [string]::IsNullOrWhiteSpace($d)) { $callArgs += @('-Description', $d) }
  if (-not [string]::IsNullOrWhiteSpace($b)) { $callArgs += @('-BodyHtml', $b) }

  & (Join-Path $ScriptsDir "update-post.ps1") @callArgs
}

function Do-RenamePost {
  $old = Ask "Old slug"
  $new = Ask "New slug"
  $keep = Ask-YesNo "Leave redirect file in place?" $true
  $switch = @()
  if ($keep) { $switch = @('-LeaveRedirect') }
  & (Join-Path $ScriptsDir "rename-post.ps1") -OldSlug $old -NewSlug $new @switch
}

function Do-DeletePost {
  $slug = Ask "Slug to delete"
  & (Join-Path $ScriptsDir "delete-post.ps1") -Slug $slug
}

function Do-Extract {
  $slug = Ask "Slug to extract to drafts"
  & (Join-Path $ScriptsDir "extract-post.ps1") -Slug $slug
}

function Do-ApplyDraft {
  $slug = Ask "Slug to apply draft to"
  & (Join-Path $ScriptsDir "apply-draft.ps1") -Slug $slug
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
  $redir = Join-Path $ScriptsDir "redirects.ps1"
  switch ($c) {
    '1' {
      $from = Ask "From path (e.g. /legacy or /old/*)"
      $to   = Ask "To URL or path (e.g. /blog/new.html)"
      $code = Ask "HTTP code (301, 302, 307, 308)" "301"
      & $redir -Add -From $from -To $to -Code ([int]$code)
    }
    '2' { $i = Ask "Index to remove";   & $redir -Remove  -Index ([int]$i) }
    '3' { $i = Ask "Index to disable";  & $redir -Disable -Index ([int]$i) }
    '4' { $i = Ask "Index to enable";   & $redir -Enable  -Index ([int]$i) }
    '5' { & $redir -List }
    default { Write-Host "Invalid choice." }
  }
}

function Do-BuildPagination {
  $size = Ask "Page size" "10"
  & (Join-Path $ScriptsDir "build-blog-index.ps1") -PageSize ([int]$size)
}

# --- Run heavy scripts in a clean child PowerShell to isolate parsing/strict-mode ---
function Invoke-Clean {
  param([string]$ScriptFullPath, [string[]]$Args = @())
  $psiArgs = @('-NoProfile','-ExecutionPolicy','Bypass','-File', $ScriptFullPath) + $Args
  & powershell.exe @psiArgs
  $code = $LASTEXITCODE
  if ($code -ne 0) {
    Write-Error ("Child process exited with code {0} running {1}" -f $code, $ScriptFullPath)
  }
}

function Do-Bake       { Invoke-Clean (Join-Path $ScriptsDir "bake.ps1") }
function Do-BuildBake  { Invoke-Clean (Join-Path $ScriptsDir "build-and-bake.ps1") }
function Do-CheckLinks { Invoke-Clean (Join-Path $ScriptsDir "check-links.ps1") }

function Do-ListPosts {
  if (-not (Test-Path $S.Blog)) { Write-Host "(no blog/ folder yet)"; return }
  Get-ChildItem -Path $S.Blog -Filter *.html -File | ForEach-Object { Write-Host $_.Name }
}

function Do-OpenPost {
  $slug = Ask "Slug to open in VS Code"
  $p = Join-Path $S.Blog ($slug + ".html")
  if (Test-Path $p) {
    Write-Host "[ASD] Opening $p in VS Code..."
    try { Start-Process code -ArgumentList @("--reuse-window","`"$p`"") -ErrorAction Stop }
    catch { Write-Warning "VS Code not found on PATH. Opening in Notepad."; notepad.exe $p }
  } else {
    Write-Warning "Post not found: $p"
  }
}

function Do-EditConfig {
  $cfgPath = Join-Path $S.Root "config.json"
  if (-not (Test-Path $cfgPath)) { $null = Get-ASDConfig -Root $S.Root } # ensure exists
  Write-Host "[ASD] Opening $cfgPath..."
  try { Start-Process code -ArgumentList @("--reuse-window","`"$cfgPath`"") -ErrorAction Stop }
  catch { notepad.exe $cfgPath }
}

# ---------------- Git helpers (Commit All) ----------------

function Test-GitAvailable {
  try { $null = (& git --version) 2>$null; return ($LASTEXITCODE -eq 0) } catch { return $false }
}

function Get-GitRoot {
  try {
    $root = (& git rev-parse --show-toplevel) 2>$null
    if ($LASTEXITCODE -eq 0 -and -not [string]::IsNullOrWhiteSpace($root)) { return $root }
  } catch {}
  return $null
}

function Git-Run {
  param([string[]]$GitArgs,[switch]$Capture)
  if ($Capture) { $out = & git @GitArgs 2>&1; return @{ code = $LASTEXITCODE; out = $out } }
  else          { & git @GitArgs;         return @{ code = $LASTEXITCODE; out = $null } }
}

function Do-CommitAll {
  if (-not (Test-GitAvailable)) { Write-Error "git is not installed or not on PATH."; return }
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
    $add = Git-Run -GitArgs @('add','-A','--','.') -Capture
    if ($add.code -ne 0) { Write-Error "git add failed:`n$($add.out)"; return }
    $staged = (& git diff --cached --name-only) 2>$null
    if ([string]::IsNullOrWhiteSpace($staged)) { Write-Host "[ASD] Nothing staged; nothing to commit."; return }

    $ts = Get-Date -Format "yyyy-MM-dd HH:mm"
    $defaultMsg = "asd: batch changes ($ts)"
    $msg = Ask "Commit message" $defaultMsg
    if ([string]::IsNullOrWhiteSpace($msg)) { $msg = $defaultMsg }

    $commit = Git-Run -GitArgs @('commit','-m', $msg) -Capture
    if ($commit.code -ne 0) { Write-Error "git commit failed:`n$($commit.out)"; return }
    Write-Host "[ASD] Commit created."

    if (Ask-YesNo "Push to remote? (requires your git remote auth)") {
      $push = Git-Run -GitArgs @('push') -Capture
      if ($push.code -ne 0) { Write-Warning "git push failed:`n$($push.out)" } else { Write-Host "[ASD] Pushed commits." }
      if (Ask-YesNo "Push tags too?") {
        $pt = Git-Run -GitArgs @('push','--tags') -Capture
        if ($pt.code -ne 0) { Write-Warning "git push --tags failed:`n$($pt.out)" } else { Write-Host "[ASD] Pushed tags." }
      }
    }
  } finally { Pop-Location }
}

# ---------------- Pages helpers/actions ----------------

function Normalize-PageRel([string]$p){
  $p = ($p -replace '\\','/').Trim()
  if ([string]::IsNullOrWhiteSpace($p)) { return $p }
  if ($p -notlike '*.html') { $p += '.html' }
  return $p
}

function Clamp160([string]$s){
  if ([string]::IsNullOrWhiteSpace($s)) { return "" }
  $t = [regex]::Replace($s,'\s+',' ').Trim()
  if ($t.Length -gt 160) { $t = $t.Substring(0,160) }
  return $t
}

function Do-NewPage {
  $path = Ask "Page path to create (e.g. about or legal/privacy)"
  $title = Ask "Title"
  $desc  = Ask "Description" ""
  $body  = Ask "BodyHtml (blank for default)" ""

  $rel = Normalize-PageRel $path
  if ([string]::IsNullOrWhiteSpace($rel)) { Write-Error "Path is required."; return }
  $fs  = Join-Path $S.Root $rel
  $dir = Split-Path -Parent $fs
  if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  if ([string]::IsNullOrWhiteSpace($body)) {
    $body = @"
<!-- KEEP CONTENT ON ONE LINE TO AVOID WHITESPACE GROWTH -->
<h1>$title</h1>
<p>Write your page content here.</p>
"@
  }

  $descClamped = Clamp160 $desc
  $content = @"
<!-- ASD:CONTENT_START -->
$body
<!-- ASD:DESCRIPTION: $descClamped -->
<!-- ASD:CONTENT_END -->
"@
  Set-Content -Encoding UTF8 -LiteralPath $fs $content
  Write-Host "[ASD] New page created: $rel"
}

function Do-EditPage {
  $path = Ask "Page path to edit (e.g. about or legal/privacy)"
  $t = Ask "New Title (blank=keep)" ""
  $d = Ask "New Description (blank=keep)" ""
  $b = Ask "New BodyHtml (blank=keep)" ""
  $a = ""  # optional override; leave blank to use config

  $ps = @{ Path = $path }
  if (-not [string]::IsNullOrWhiteSpace($t)) { $ps.Title       = $t }
  if (-not [string]::IsNullOrWhiteSpace($d)) { $ps.Description = $d }
  if (-not [string]::IsNullOrWhiteSpace($b)) { $ps.BodyHtml    = $b }
  if (-not [string]::IsNullOrWhiteSpace($a)) { $ps.Author      = $a }

  & (Join-Path $ScriptsDir "update-page.ps1") @ps
}

function Do-RenamePage {
  $old = Ask "Old page path (e.g. about or legal/privacy)"
  $new = Ask "New page path (e.g. about-us or legal/policy)"
  $keep = Ask-YesNo "Leave redirect file in place?" $true

  $relOld = Normalize-PageRel $old
  $relNew = Normalize-PageRel $new
  if ([string]::IsNullOrWhiteSpace($relOld) -or [string]::IsNullOrWhiteSpace($relNew)) { Write-Error "Both paths are required."; return }

  $script = Join-Path $ScriptsDir "rename-page.ps1"
  if (Test-Path $script) {
    $switch = @()
    if ($keep) { $switch = @('-LeaveRedirect') }
    & $script -OldPath $relOld -NewPath $relNew @switch
    return
  }

  # Fallback inline (if rename-page.ps1 isn't present)
  $fsOld = Join-Path $S.Root $relOld
  $fsNew = Join-Path $S.Root $relNew
  if (-not (Test-Path $fsOld)) { Write-Error "Source not found: $relOld"; return }
  $dirNew = Split-Path -Parent $fsNew
  if (-not (Test-Path $dirNew)) { New-Item -ItemType Directory -Force -Path $dirNew | Out-Null }

  Move-Item -Force $fsOld $fsNew
  Write-Host "[ASD] Renamed $relOld -> $relNew"

  if ($keep) {
    function _NormBase([string]$b){
      if ([string]::IsNullOrWhiteSpace($b)) { return "/" }
      $x = $b.Trim() -replace '^/+(?=https?:)','' -replace '^((?:https?):)/{1,}','$1//'
      $m = [regex]::Match($x,'^(https?://)(.+)$')
      if ($m.Success) { $x = $m.Groups[1].Value + $m.Groups[2].Value.TrimStart('/'); if (-not $x.EndsWith('/')){$x+='/'}; return $x }
      return '/' + ($x.Trim('/')) + '/'
    }
    $base = _NormBase ([string]$cfg.BaseUrl)
    $target =
      if ($base -match '^[a-z]+://') {
        try { (New-Object System.Uri((New-Object System.Uri($base)), $relNew)).AbsoluteUri }
        catch { $base.TrimEnd('/') + '/' + ($relNew.TrimStart('/')) }
      } else { $base.TrimEnd('/') + '/' + ($relNew.TrimStart('/')) }

    $fsOldDir = Split-Path -Parent $fsOld
    if (-not (Test-Path $fsOldDir)) { New-Item -ItemType Directory -Force -Path $fsOldDir | Out-Null }
    $esc = $target -replace '&','&amp;' -replace '<','&lt;' -replace '>','&gt;' -replace '"','&quot;'
    $jsu = $target -replace '\\','\\' -replace "'","\'"
    $html = @"
<!doctype html><html lang="en"><head>
<meta charset="utf-8"><title>Redirecting…</title>
<meta name="robots" content="noindex">
<meta http-equiv="refresh" content="0;url=$esc">
<script>location.replace('$jsu');</script>
</head><body>
<!-- ASD:REDIRECT to="$esc" code="301" -->
<p>If you are not redirected, <a href="$esc">click here</a>.</p>
</body></html>
"@
    Set-Content -Encoding UTF8 -LiteralPath $fsOld $html
    $redir = Join-Path $ScriptsDir "redirects.ps1"
    if (Test-Path $redir) {
      try { & $redir -Add -From ("/" + $relOld.TrimStart('/')) -To ("/" + $relNew.TrimStart('/')) -Code 301 } catch {}
    }
    Write-Host "[ASD] Redirect stub created at $relOld -> $target"
  }
}

function Do-DeletePage {
  $path = Ask "Page path to delete (e.g. about or legal/privacy)"
  $rel  = Normalize-PageRel $path
  if ([string]::IsNullOrWhiteSpace($rel)) { Write-Error "Path is required."; return }

  $fs = Join-Path $S.Root $rel
  if (-not (Test-Path $fs)) { Write-Error "Page not found: $rel"; return }

  if (-not (Ask-YesNo "Are you sure you want to delete '$rel'?" $true)) {
    Write-Host "[ASD] Cancelled."
    return
  }

  try {
    Remove-Item -LiteralPath $fs -Force
    Write-Host "[ASD] Deleted page: $rel"

    # If the containing directory is now empty, clean it up (but never delete the site root)
    $dir = Split-Path -Parent $fs
    if ($dir -and (Test-Path $dir) -and ($dir -ne $S.Root)) {
      $hasStuff = Get-ChildItem -LiteralPath $dir -Force | Select-Object -First 1
      if (-not $hasStuff) {
        try { Remove-Item -LiteralPath $dir -Force } catch {}
      }
    }
  } catch {
    Write-Error "Failed to delete: $($_.Exception.Message)"
  }
}

function Do-ListPages {
  if (-not (Test-Path $S.Root)) { return }
  $skip = '\\blog\\|\\assets\\|\\partials\\'
  Get-ChildItem -Path $S.Root -Recurse -File -Filter *.html |
    Where-Object { $_.FullName -notmatch $skip } |
    ForEach-Object {
      $rel = $_.FullName.Substring($S.Root.Length + 1) -replace '\\','/'
      Write-Host $rel
    }
}

# -------- Main loop --------
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
    '16' { Do-NewPage }
    '17' { Do-EditPage }
    '18' { Do-RenamePage }
    '19' { Do-DeletePage }
    '20' { Do-ListPages }
    'q'  { break }
    'Q'  { break }
    default { Write-Host "Unknown choice." }
  }
}
