@echo off
chcp 65001 >nul
setlocal
set "SCRIPT_DIR=%~dp0.."
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\01-Audit-UserProfile.ps1"
echo.
pause
