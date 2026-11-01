@echo off
chcp 65001 >nul 2>&1
title Clear API Key
cd /d "%~dp0"
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0???????.ps1"