@echo off
chcp 65001 >nul 2>&1
title Set DeepSeek API Key
cd /d "%~dp0"
if not exist "%~dp0setup_key.ps1" (
    echo [ERROR] setup_key.ps1 not found in this folder.
    pause
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0setup_key.ps1"