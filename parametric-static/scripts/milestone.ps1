# milestone.ps1  — PS 5.1-safe
# - Builds a changelog entry since the last tag (or from repo start)
# - Creates/updates CHANGELOG.md (prepends latest entry)
# - Creates an annotated git tag
# - Optionally pushes commit and tag
# - No version bump to config.json (can be added later if desired)

#requires -Version 5.1
Set-StrictMode -Version 2.0

$ScriptsDir = Split-Path -Parent $PSCommandPath
. (Join-Path $ScriptsDir "_lib.ps1")  # for Get-ASDPaths/Get-ASDConfig

$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

function Ask([string]$Prompt, [string]$Default = "") {
  if ([string]::IsNullOrWhiteSpace($Default)) { return (Read-Host $Prompt) }
  $v = Read-Host ("{0} [{1}]" -f $Prompt, $Default)
  if ([string]::IsNullOrWhiteSpace($v)) { return $Default } else { return $v }
}
function Ask-YesNo([string]$Prompt, [bool]$DefaultNo = $true) {
  $sfx = if ($DefaultNo) { "(y/N)" } else { "(Y/n)" }
  $ans = Read-Host ("{0} {1}" -f $Prompt, $sfx)
  if ([string]::IsNullOrWhiteSpace($ans)) { return (-not $DefaultNo) }
  return ($ans -match '^[Yy]')
}
function Git-Avail { try { $null = (& git --version) 2>$null; return ($LASTEXITCODE -eq 0) } catch { return $false } }
function Git-Run([string[]]$Args, [switch]$Capture) {
  if ($Capture) { $out = & git @Args 2>&1; return @{ code = $LASTEXITCODE; out = $out } }
  else { & git @Args; return @{ code = $LASTEXITCODE; out = $null } }
}
function Git-Root {
  $r = Git-Run @('rev-parse','--show-toplevel') -Capture
  if ($r.code -eq 0 -and $r.out -and $r.out.Count -gt 0) { return [string]$r.out[0] }
  return $null
}
function Get-LastTag {
  $r = Git-Run @('describe','--tags','--abbrev=0') -Capture
  if ($r.code -eq 0 -and $r.out -and $r.out.Count -gt 0) { return [string]$r.out[0].Trim() }
  return $null
}
function Tag-Exists([string]$tag) {
  $r = Git-Run @('rev-parse','-q','--verify', "refs/tags/$tag") -Capture
  return ($r.code -eq 0)
}
function Unique-Tag([string]$base) {
  if (-not (Tag-Exists $base)) { return $base }
  for ($i=2; $i -le 999; $i++) {
    $cand = "$base-$i"
    if (-not (Tag-Exists $cand)) { return $cand }
  }
  return ($base + '-' + [Guid]::NewGuid().ToString('N').Substring(0,6))
}
function Build-Changes([string]$sinceTag) {
  if ([string]::IsNullOrWhiteSpace($sinceTag)) {
    $r = Git-Run @('log','--pretty=format:- %s (%h)') -Capture
  } else {
    $r = Git-Run @('log',("$sinceTag..HEAD"),'--pretty=format:- %s (%h)') -Capture
  }
  if ($r.code -ne 0 -or -not $r.out) { return @() }
  $lines = @()
  foreach ($ln in $r.out) { if (-not [string]::IsNullOrWhiteSpace($ln)) { $lines += ,([string]$ln) } }
  return $lines
}
function Prepend-File([string]$path,[string]$content) {
  $existing = ""; if (Test-Path $path) { $existing = Get-Content $path -Raw }
  Set-Content -Encoding UTF8 $path ($content + $existing)
}
function Ensure-Changelog([string]$tag,[string[]]$items) {
  $today = (Get-Date).ToString('yyyy-MM-dd')
  $site  = if ($cfg -and $cfg.PSObject.Properties.Name -contains 'SiteName' -and $cfg.SiteName) { [string]$cfg.SiteName } else { 'ASD Site' }
  $header = "# Changelog"
  $entry  = "## $tag — $today`r`n`r`n"
  if ($items -and $items.Count -gt 0) {
    $entry += ($items -join "`r`n") + "`r`n`r`n"
  } else {
    $entry += "- No code changes since last tag.`r`n`r`n"
  }

  $chlog = Join-Path $S.Root 'CHANGELOG.md'
  if (-not (Test-Path $chlog)) {
    $body = $header + "`r`n`r`n" + $entry
    Set-Content -Encoding UTF8 $chlog $body
  } else {
    # If file starts with # Changelog, insert after first header; else just prepend.
    $raw = Get-Content $chlog -Raw
    if ($raw -match '^\s*#\s*Changelog') {
      $ix = $raw.IndexOf("`n")
      if ($ix -gt -1) {
        $new = $raw.Substring(0,$ix+1) + "`r`n" + $entry + $raw.Substring($ix+1)
        Set-Content -Encoding UTF8 $chlog $new
      } else {
        Prepend-File $chlog ($header + "`r`n`r`n" + $entry)
      }
    } else {
      Prepend-File $chlog ($header + "`r`n`r`n" + $entry)
    }
  }
  return $chlog
}

if (-not (Git-Avail)) { Write-Error "git is not installed or not on PATH."; exit 1 }
$root = Git-Root
if (-not $root) { Write-Error "This folder is not a git repository. Run the wizard's 'Commit all (git)' first."; exit 1 }

Push-Location $root
try {
  $defaultTag = "v" + (Get-Date).ToString('yyyy.MM.dd')
  $tagBase = Ask "Tag name" $defaultTag
  $tag     = Unique-Tag $tagBase

  $titleDefault = if ($cfg -and $cfg.SiteName) { [string]$cfg.SiteName + " milestone" } else { "Milestone" }
  $title   = Ask "Release title" $titleDefault

  $lastTag = Get-LastTag
  if ($lastTag) { Write-Host "[milestone] Last tag: $lastTag" } else { Write-Host "[milestone] No previous tag found." }

  $changes = Build-Changes $lastTag
  if ($changes.Count -eq 0) { Write-Host "[milestone] No commits since last tag (or repository empty)." }

  $chFile = Ensure-Changelog -tag $tag -items $changes
  Write-Host "[milestone] CHANGELOG updated: $chFile"

  # Stage changelog and commit if staged
  $add = Git-Run @('add','-A','--','CHANGELOG.md') -Capture
  if ($add.code -ne 0) { Write-Warning "git add failed: $($add.out -join "`n")" }
  $staged = (Git-Run @('diff','--cached','--name-only') -Capture)
  if ($staged.code -eq 0 -and $staged.out -and $staged.out.Count -gt 0) {
    $cm = Git-Run @('commit','-m', ("chore: update changelog for {0}" -f $tag)) -Capture
    if ($cm.code -ne 0) { Write-Warning "git commit failed: $($cm.out -join "`n")" }
    else { Write-Host "[milestone] Commit created for CHANGELOG." }
  } else {
    Write-Host "[milestone] No staged changes to commit."
  }

  # Create annotated tag
  $tg = Git-Run @('tag','-a', $tag,'-m', ("Milestone: {0}" -f $title)) -Capture
  if ($tg.code -ne 0) {
    Write-Error "Failed to create tag:`n$($tg.out -join "`n")"
    exit 1
  }
  Write-Host "[milestone] Tag created: $tag"

  if (Ask-YesNo "Push CHANGELOG commit and tag now?" $false) {
    $p1 = Git-Run @('push') -Capture
    if ($p1.code -ne 0) { Write-Warning "git push failed:`n$($p1.out -join "`n")" } else { Write-Host "[milestone] Pushed commit(s)." }
    $p2 = Git-Run @('push','--tags') -Capture
    if ($p2.code -ne 0) { Write-Warning "git push --tags failed:`n$($p2.out -join "`n")" } else { Write-Host "[milestone] Pushed tags." }
  } else {
    Write-Host "[milestone] Skipped push."
  }

  Write-Host "[milestone] Done."
} finally {
  Pop-Location
}
