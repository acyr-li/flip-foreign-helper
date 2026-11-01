#requires -version 5.1
$ErrorActionPreference = 'Continue'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

Write-Host ''
Write-Host ('=' * 52) -ForegroundColor Cyan
Write-Host '  安装高精度 OCR 组件（RapidOCR）' -ForegroundColor Cyan
Write-Host ('=' * 52) -ForegroundColor Cyan
Write-Host ''
Write-Host '作用：单词卡片的题干是大字号英文（如 fry），Windows 自带 OCR 读不出来，' -ForegroundColor Gray
Write-Host '      装了这个组件就能准确识别，正确率才有保证。' -ForegroundColor Gray
Write-Host ''

$py = Get-Command python -ErrorAction SilentlyContinue
if (-not $py) {
    Write-Host '[!] 这台电脑没有 Python，装不了这个组件。' -ForegroundColor Yellow
    Write-Host ''
    Write-Host '两种选择：' -ForegroundColor Yellow
    Write-Host '  1) 装个 Python（推荐）：打开 https://www.python.org/downloads/'
    Write-Host '     下载安装时务必勾选 "Add python.exe to PATH"，装完再双击本文件'
    Write-Host '  2) 不装也能用：脚本会自动退回 Windows 自带 OCR'
    Write-Host '     · 50 题的测试完全没问题'
    Write-Host '     · 25 词的单词卡包，题干可能识别不出，偶尔会答错'
    Write-Host ''
    Read-Host '按回车关闭' | Out-Null
    exit
}

Write-Host ('已找到 Python: ' + $py.Source) -ForegroundColor Green
$ver = & python --version 2>&1
Write-Host ('版本: ' + $ver) -ForegroundColor Green
Write-Host ''
Write-Host '开始安装依赖（首次约 100~200MB，请耐心等 1-3 分钟）...' -ForegroundColor Cyan
Write-Host ''

& python -m pip install --upgrade pip --quiet --disable-pip-version-check 2>&1 | Out-Null
& python -m pip install rapidocr-onnxruntime --disable-pip-version-check 2>&1 | Select-Object -Last 12

Write-Host ''
Write-Host '验证安装...' -ForegroundColor Cyan
$chk = & python -c "from rapidocr_onnxruntime import RapidOCR; print('OK')" 2>&1
if ($chk -match 'OK') {
    Write-Host '[✓] 安装成功！以后双击一键完成，会自动用高精度 OCR。' -ForegroundColor Green
} else {
    Write-Host '[!] 安装后验证失败，可能网络受限。' -ForegroundColor Red
    Write-Host ('    错误: ' + ($chk -join ' ')) -ForegroundColor Red
    Write-Host '    脚本仍可运行，会退回 Windows 自带 OCR。' -ForegroundColor Yellow
}
Write-Host ''
Read-Host '按回车关闭' | Out-Null
