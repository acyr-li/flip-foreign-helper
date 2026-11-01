#requires -version 5.1
$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$root = Split-Path -Parent $MyInvocation.MyCommand.Definition
$cfgPath = Join-Path $root 'config.json'

function Show-Head($t) { Write-Host ''; Write-Host ('=' * 46) -ForegroundColor Cyan; Write-Host "  $t" -ForegroundColor Cyan; Write-Host ('=' * 46) -ForegroundColor Cyan }
function Pause-Exit { Write-Host ''; Read-Host '按回车关闭' | Out-Null; exit }

Show-Head '设置 / 更换 DeepSeek API Key'

$cur = ''
if (Test-Path $cfgPath) {
    try {
        $j = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($j.api_key) { $cur = $j.api_key }
    } catch { }
}
if ($cur) {
    $mask = $cur.Substring(0, [Math]::Min(7, $cur.Length)) + '....' + $cur.Substring([Math]::Max(0, $cur.Length - 4))
    Write-Host "当前已配置：$mask" -ForegroundColor Green
} else {
    Write-Host '当前还没有配置 key（只能用本地词典判题，正确率约 94%）' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '怎么拿到 key：' -ForegroundColor Yellow
Write-Host '  1. 浏览器打开  https://platform.deepseek.com'
Write-Host '  2. 注册 / 登录  ->  左侧「API keys」 -> 「创建 API key」'
Write-Host '  3. 复制 sk- 开头的那串（只显示一次，先存好）'
Write-Host '  4. 要用就得充值，最低 10 元，判题约 0.0003 元/道'
Write-Host ''
Write-Host '提示：直接回车 = 保持现状；输入 clear = 清空 key' -ForegroundColor DarkGray
Write-Host ''

$input1 = Read-Host '把 key 粘贴到这里，按回车'
$k = $input1.Trim().Trim('"').Trim("'").Trim()

if ($k -eq '') {
    Write-Host '没有改动，保持原样。' -ForegroundColor Yellow
    Pause-Exit
}
if ($k -eq 'clear') {
    $k = ''
    Write-Host '已清空 key。' -ForegroundColor Yellow
} elseif ($k -notmatch '^sk-') {
    Write-Host '这看起来不像 DeepSeek 的 key（正常应该以 sk- 开头）。' -ForegroundColor Yellow
    $yn = Read-Host '仍然保存吗？(y/n)'
    if ($yn -ne 'y') { Pause-Exit }
}

# 写回 config.json
$cfg = [ordered]@{ api_base = 'https://api.deepseek.com/v1'; api_key = ''; model = 'deepseek-chat'; use_ai = $true }
if (Test-Path $cfgPath) {
    try {
        $old = Get-Content $cfgPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $old.PSObject.Properties) { if ($cfg.Contains($p.Name)) { $cfg[$p.Name] = $p.Value } }
    } catch { }
}
$cfg['api_key'] = $k
[System.IO.File]::WriteAllText($cfgPath, (ConvertTo-Json -InputObject $cfg -Depth 4), (New-Object System.Text.UTF8Encoding($false)))
Write-Host ''
Write-Host '已写入 config.json' -ForegroundColor Green

if (-not $k) { Pause-Exit }

# 联网验证
Write-Host '正在联网验证这个 key ...' -ForegroundColor Cyan
$body = @{
    model    = $cfg['model']
    messages = @(@{ role = 'user'; content = '回答一个字：好' })
    max_tokens = 5
} | ConvertTo-Json -Depth 5
$headers = @{ Authorization = ('Bearer ' + $k); 'Content-Type' = 'application/json' }
try {
    $r = Invoke-RestMethod -Uri ($cfg['api_base'].TrimEnd('/') + '/chat/completions') -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 25
    $reply = [string]$r.choices[0].message.content
    Write-Host ('验证成功！模型回复：' + $reply.Trim()) -ForegroundColor Green
    Write-Host '以后双击「一键完成今日任务」就会用这个 key 判题。' -ForegroundColor Green
} catch {
    $msg = $_.Exception.Message
    Write-Host '验证失败：' -ForegroundColor Red
    Write-Host ('  ' + $msg) -ForegroundColor Red
    Write-Host ''
    Write-Host '常见原因：' -ForegroundColor Yellow
    Write-Host '  · key 复制不全 / 多了空格'
    Write-Host '  · 账号没充值，余额为 0'
    Write-Host '  · 公司或校园网挡了 api.deepseek.com'
    Write-Host '  · key 已被删除'
    Write-Host 'key 已保存，但判题时会自动退回本地词典。' -ForegroundColor Yellow
}
Pause-Exit
