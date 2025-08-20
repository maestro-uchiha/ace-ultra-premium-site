@echo off
setlocal ENABLEDELAYEDEXPANSION

REM ===== Amaterasu Static Deploy (ASD) version banner =====
set "ASD_VER="
if exist "VERSION" (
  for /f "usebackq tokens=*" %%v in ("VERSION") do set "ASD_VER=%%v"
) else if exist "%~dp0..\VERSION" (
  for /f "usebackq tokens=*" %%v in ("%~dp0..\VERSION") do set "ASD_VER=%%v"
)
if defined ASD_VER ( echo [Amaterasu Static Deploy] Version %ASD_VER% ) else ( echo [Amaterasu Static Deploy] Version (unknown) )
echo [Amaterasu Static Deploy] Baking…

REM ===== Inputs / defaults (CLI args override bake-config.json) =====
set BRAND=%~1
set MONEY=%~2
if "%BRAND%"=="" if exist "bake-config.json" (
  for /f "usebackq tokens=* delims=" %%J in (`powershell -NoProfile -Command "$c=Get-Content 'bake-config.json' -Raw | ConvertFrom-Json; $c.brand"`) do set BRAND=%%J
)
if "%MONEY%"=="" if exist "bake-config.json" (
  for /f "usebackq tokens=* delims=" %%J in (`powershell -NoProfile -Command "$c=Get-Content 'bake-config.json' -Raw | ConvertFrom-Json; $c.url"`) do set MONEY=%%J
)
if "%BRAND%"=="" set BRAND={{BRAND}}
if "%MONEY%"=="" set MONEY=https://YOUR-DOMAIN.com
for /f %%Y in ('powershell -NoProfile -Command "(Get-Date).Year"') do set YEAR=%%Y
echo [ASD] BRAND="%BRAND%" MONEY="%MONEY%" YEAR=%YEAR%

REM ===== Load partials =====
for /f "usebackq tokens=* delims=" %%L in ("partials\head-seo.html") do set "HEAD_PARTIAL=!HEAD_PARTIAL!%%L`n"
for /f "usebackq tokens=* delims=" %%L in ("partials\nav.html") do set "NAV_PARTIAL=!NAV_PARTIAL!%%L`n"
for /f "usebackq tokens=* delims=" %%L in ("partials\footer.html") do set "FOOT_PARTIAL=!FOOT_PARTIAL!%%L`n"
set "HEAD_PS=!HEAD_PARTIAL:`=``!"
set "NAV_PS=!NAV_PARTIAL:`=``!"
set "FOOT_PS=!FOOT_PARTIAL:`=``!"

REM ===== Replacement template (handles SSI-style includes) =====
set "PS_REPL=(Get-Content 'FILE_IN' -Raw) `
  -replace [regex]::Escape('<!--#include virtual=""partials/head-seo.html"" -->'), @'
HEAD_HERE
'@ `
  -replace [regex]::Escape('<!--#include virtual=""partials/nav.html"" -->'), @'
NAV_HERE
'@ `
  -replace [regex]::Escape('<!--#include virtual=""partials/footer.html"" -->'), @'
FOOT_HERE
'@ `
  -replace '{{BRAND}}','%BRAND%' `
  -replace '{{MONEY}}','%MONEY%' `
  -replace '{{YEAR}}','%YEAR%'; `
Set-Content 'FILE_IN' $PS_REPL"

REM ===== Process root HTML files
for %%F in (index.html about.html contact.html sitemap.html 404.html) do (
  if exist "%%F" (
    set "ONE=!PS_REPL:FILE_IN=%%F!"
    set "ONE=!ONE:HEAD_HERE=%HEAD_PS%!"
    set "ONE=!ONE:NAV_HERE=%NAV_PS%!"
    set "ONE=!ONE:FOOT_HERE=%FOOT_PS%!"
    powershell -NoProfile -Command "!ONE!"
  )
)

REM ===== Process legal pages
for %%F in (legal\privacy.html legal\terms.html legal\disclaimer.html) do (
  if exist "%%F" (
    set "ONE=!PS_REPL:FILE_IN=%%F!"
    set "ONE=!ONE:HEAD_HERE=%HEAD_PS%!"
    set "ONE=!ONE:NAV_HERE=%NAV_PS%!"
    set "ONE=!ONE:FOOT_HERE=%FOOT_PS%!"
    powershell -NoProfile -Command "!ONE!"
  )
)

REM ===== Process blog posts
for %%F in (blog\*.html) do (
  if exist "%%F" (
    set "ONE=!PS_REPL:FILE_IN=%%F!"
    set "ONE=!ONE:HEAD_HERE=%HEAD_PS%!"
    set "ONE=!ONE:NAV_HERE=%NAV_PS%!"
    set "ONE=!ONE:FOOT_HERE=%FOOT_PS%!"
    powershell -NoProfile -Command "!ONE!"
  )
)

REM ===== Update config.json (optional)
if exist config.json (
  powershell -NoProfile -Command ^
    "$c=Get-Content 'config.json' -Raw | ConvertFrom-Json; $c.brand='%BRAND%'; $c.moneySite='%MONEY%'; $c | ConvertTo-Json -Depth 6 | Set-Content 'config.json'"
)

REM ===== Build blog index (extract <title>, use file modified date)
set "POSTS="
for %%F in (blog\*.html) do (
  if /I not "%%~nxF"=="index.html" (
    for /f "usebackq tokens=*" %%T in (`powershell -NoProfile -Command "$h=Get-Content '%%F' -Raw; $m=[regex]::Match($h,'<title>(.*?)</title>','IgnoreCase'); if($m.Success){$m.Groups[1].Value}else{'(no title)'}"`) do (
      for /f "tokens=1,2 delims==" %%a in ('wmic datafile where "name='%%~fF'" get lastmodified /value ^| find "="') do set LM=%%b
      set YYYY=!LM:~0,4!
      set MM=!LM:~4,2!
      set DD=!LM:~6,2!
      set DATE=!YYYY!-!MM!-!DD!
      set REL=blog/%%~nxF
      set "POSTS=!POSTS!<li><a href='/!REL!'>%%T</a><small> — !DATE!</small></li>||"
    )
  )
)
if exist blog\index.html (
  powershell -NoProfile -Command ^
    "$p=Get-Content 'blog/index.html' -Raw; $items='%POSTS%'.Replace('||',[Environment]::NewLine);" ^
    "$p=[regex]::Replace($p,'(?s)<!-- POSTS_START -->.*?<!-- POSTS_END -->','<!-- POSTS_START -->'+[Environment]::NewLine+$items+[Environment]::NewLine+'<!-- POSTS_END -->');" ^
    "Set-Content 'blog/index.html' $p"
)

echo [Amaterasu Static Deploy] Done.
endlocal
