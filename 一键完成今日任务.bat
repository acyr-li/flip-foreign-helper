@echo off
chcp 65001 >nul 2>&1
title FlipForeign - Auto Daily Task
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0flip2.ps1" -Mode run
echo.
echo ============================================
echo  Done. Press any key to close this window.
echo ============================================
pause >nul
