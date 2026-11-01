@echo off
chcp 65001 >nul 2>&1
title Export clean copy (API key removed)
echo.
echo ============================================================
echo   Export a CLEAN copy for someone else
echo   - your API key will be removed
echo   - logs and temp screenshots will be removed
echo ============================================================
echo.
set "DEST="
set /p DEST=Target folder (e.g. E:\FlipForeign ):
if "%DEST%"=="" goto abort
if exist "%DEST%" goto exists
echo.
echo Copying...
robocopy "%~dp0." "%DEST%" /E /XD logs /NFL /NDL /NJH /NJS /NC /NS /XF _s0.png _s1.png _s2.png _s3.png _ocr_big.png _stem_big.png _opts_big.png _zoombig.png >nul
if exist "%DEST%\logs" rd /s /q "%DEST%\logs"
md "%DEST%\logs" 2>nul
if exist "%DEST%\data" del /q "%DEST%\data\_*.png" 2>nul
powershell -NoProfile -ExecutionPolicy Bypass -Command "$p='%DEST%\config.json'; if(Test-Path $p){ $j=Get-Content -Raw -Encoding UTF8 $p | ConvertFrom-Json; $j.api_key=''; [System.IO.File]::WriteAllText($p,(ConvertTo-Json -InputObject $j -Depth 4),(New-Object System.Text.UTF8Encoding($false))) }"
echo.
echo Done. API key cleared.
echo Give that folder to your friend. He should run:
echo    1) setup key (optional): double click the "Set AI Key" bat
echo    2) double click the one-click bat
echo.
pause
exit /b

:exists
echo.
echo Target folder already exists. Choose another path.
pause
exit /b

:abort
echo Cancelled.
pause