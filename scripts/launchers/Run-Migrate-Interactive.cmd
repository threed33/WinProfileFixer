@echo off
chcp 65001 >nul
setlocal
set "SCRIPT_DIR=%~dp0.."
echo ====================================================================
echo   WinProfileFixer - Interactive Migration Launcher
echo   Please make sure you right-clicked "Run as administrator"
echo   inside a SEPARATE Admin account (Safe Mode strongly recommended).
echo ====================================================================
echo.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%SCRIPT_DIR%\03-Migrate-UserProfile.ps1"
echo.
pause
