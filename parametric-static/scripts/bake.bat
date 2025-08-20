@echo off
REM Amaterasu Static Deploy — Windows launcher
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0bake.ps1" %*
