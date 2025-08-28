# rename-page.ps1  (PS 5.1-safe)
# Renames a page (non-blog) and optionally leaves a redirect stub + updates redirects.json
param(
  [Parameter(Mandatory=$true)][string]$OldPath,  # e.g. "about" or "legal/privacy"
  [Parameter(Mandatory=$true)][string]$NewPath,
  [switch]$LeaveRedirect
)

. (Join-Path $PSScriptRoot "_lib.ps1")
$S   = Get-ASDPaths
$cfg = Get-ASDConfig -Root $S.Root

function Clean-Rel([string]$p){
  $p = ($p | ForEach-Object { $_ }) # ensure string
  if ([string]::IsNullOrWhiteSpace($p)) { return "" }
  $p = $p.Trim().Trim('/')
  $p = $p -replace '\\','/'
  if ($p -notmatch '\.html?$'){ $p += ".html" }
  return $p
}
function Normalize-BaseUrlLocal([string]$b) {
  if ([string]::IsNullOrWhiteSpace($b)) { return "/" }
  $x = $b.Trim(); $x = $x -replace '^/+(?=https?:)', ''; $x = $x -replace '^((?:https?):)/{1,}','${1}//'
  $m=[regex]::Match($x,'^(https?://)(.+)$')
  if($m.Success){ $x=$m.Groups[1].Value + $m.Groups[2].Value.TrimStart('/'); if(-not $x.EndsWith('/')){$x+='/'}; return $x } else { return '/' + $x.Trim('/') + '/' }
}
function Make-AbsUrl([string]$base, [string]$rel){
  $b = Normalize-BaseUrlLocal $base
  if ($b -match '^[a-z]+://') {
    try { return (New-Object System.Uri((New-Object System.Uri($b)), $rel)).AbsoluteUri } catch { return ($b.TrimEnd('/') + '/' + $rel.TrimStart('/')) }
  } else { return ($b.TrimEnd('/') + '/' + $rel.TrimStart('/')) }
}

$oldRel = Clean-Rel $OldPath
$newRel = Clean-Rel $NewPath
if ([string]::IsNullOrWhiteSpace($oldRel) -or [string]::IsNullOrWhiteSpace($newRel)) { Write-Error "OldPath/NewPath required."; exit 1 }

$src = Join-Path $S.Root $oldRel
$dst = Join-Path $S.Root $newRel
if (-not (Test-Path $src)) { Write-Error "Source not found: $oldRel"; exit 1 }
if ((Test-Path $dst)) { Write-Error "Target already exists: $newRel"; exit 1 }

# Move
$dstDir = Split-Path -Parent $dst
if (-not (Test-Path $dstDir)) { New-Item -ItemType Directory -Force -Path $dstDir | Out-Null }
Move-Item -Force $src $dst
Write-Host "[ASD] Renamed page: $oldRel -> $newRel"

# Redirect?
$redirPath = Join-Path $S.Root "redirects.json"
if ($LeaveRedirect) {
  # upsert mapping
  $items = @()
  if (Test-Path $redirPath) { try { $raw=Get-Content $redirPath -Raw; if(-not [string]::IsNullOrWhiteSpace($raw)){$items=$raw|ConvertFrom-Json} } catch { $items=@() } }
  if ($null -eq $items) { $items=@() }
  $from = "/" + $oldRel
  $to   = "/" + $newRel
  $found = $false
  $newItems = @()
  foreach($it in @($items)){
    if ($it -and $it.PSObject.Properties.Name -contains 'from' -and ($it.from -eq $from)) {
      $it.to = $to
      if ($it.PSObject.Properties.Name -contains 'enabled') { $it.enabled = $true } else { Add-Member -InputObject $it -NotePropertyName enabled -NotePropertyValue $true -Force }
      if ($it.PSObject.Properties.Name -notcontains 'code') { Add-Member -InputObject $it -NotePropertyName code -NotePropertyValue 301 -Force }
      $found = $true
    }
    $newItems += ,$it
  }
  if (-not $found) { $newItems += ,([pscustomobject]@{ from=$from; to=$to; code=301; enabled=$true }) }
  $newItems | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 $redirPath

  # Write stub file at old path
  $abs = Make-AbsUrl $cfg.BaseUrl $newRel
  $jsu = ($abs -replace '\\','\\' -replace "'","\'")
  $stub = @"
<!doctype html><html lang="en"><head>
  <meta charset="utf-8">
  <title>Redirecting…</title>
  <meta name="robots" content="noindex">
  <meta http-equiv="refresh" content="0;url=$abs">
  <script>location.replace('$jsu');</script>
</head><body>
  <!-- ASD:REDIRECT to="$abs" code="301" -->
  <p>If you are not redirected, <a href="$abs">click here</a>.</p>
</body></html>
"@
  $stubFs = Join-Path $S.Root $oldRel
  # Ensure parent exists (it should; we just moved the file)
  Set-Content -Encoding UTF8 $stubFs $stub
  Write-Host "[ASD] Redirect stub left at $oldRel -> $abs"
} else {
  # If mapping existed, disable/remove (optional: leave as-is)
}

Write-Host "[ASD] Done."
