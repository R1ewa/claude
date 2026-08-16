@echo off
rem Launcher for Test-GPU.ps1 - just double-click this file.
cd /d "%~dp0"
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0Test-GPU.ps1"
if errorlevel 1 pause
