# 清空分享包里的 API Key（防止误把自己的 key 发出去）
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$share = Join-Path $PSScriptRoot 'config.json'
if (-not (Test-Path $share)) { Write-Host 'config.json 不存在' -ForegroundColor Red; Read-Host '回车关闭' | Out-Null; exit }

$j = Get-Content $share -Raw -Encoding UTF8 | ConvertFrom-Json
$old = $j.api_key
$j.api_key = ''
$out = [ordered]@{ api_base = $j.api_base; api_key = ''; model = $j.model; use_ai = $j.use_ai }
[System.IO.File]::WriteAllText($share, (ConvertTo-Json -InputObject $out -Depth 4), (New-Object System.Text.UTF8Encoding($false)))

if ([string]::IsNullOrWhiteSpace($old)) {
    Write-Host '这个文件夹里本来就没有密钥，无需清理。' -ForegroundColor Green
} else {
    Write-Host '已清空这个文件夹的 API Key' -ForegroundColor Green
    Write-Host ('  清掉的 key: ' + $old.Substring(0,7) + '...' + $old.Substring($old.Length-4)) -ForegroundColor DarkGray
}

# 顺带扫一遍有没有别的文件泄漏
$leak = Get-ChildItem $PSScriptRoot -Recurse -File -Include *.json,*.txt,*.log,*.ps1 -ErrorAction SilentlyContinue |
    Where-Object { $_.FullName -notmatch '清空分享包密钥' } |
    ForEach-Object {
        $t = Get-Content $_.FullName -Raw -ErrorAction SilentlyContinue
        if ($t -match 'sk-[a-zA-Z0-9]{20,}') { $_.FullName.Replace($PSScriptRoot,'.') }
    }
if ($leak) {
    Write-Host '警告：以下文件里还有密钥' -ForegroundColor Red
    $leak | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
} else {
    Write-Host '全文件夹扫描：无密钥残留' -ForegroundColor Green
}
Write-Host ''
Read-Host '按回车关闭' | Out-Null