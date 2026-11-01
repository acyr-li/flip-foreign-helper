@echo off
chcp 65001 >nul 2>&1
title Install OCR Component
cd /d "%~dp0"
if not exist "%~dp0??OCR??.ps1" (
    echo [ERROR] ps1 not found
    pause
    exit /b
)
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0??OCR??.ps1"