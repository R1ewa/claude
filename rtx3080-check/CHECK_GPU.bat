@echo off
rem Launcher for Test-RTX3080.ps1 - just double-click this file.
cd /d "%~dp0"
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-RTX3080.ps1"
if errorlevel 1 pause
