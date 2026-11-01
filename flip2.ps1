#requires -version 5.1
<#
  翻转外语 今日任务 自动执行器 v2.0
  ── 不依赖主题颜色、不依赖屏幕分辨率、可接 AI 判题
  识别全部来自 OCR 文本坐标，点击位置随分辨率自适应；
  颜色只用于"有没有弹窗遮罩"的辅助判断，没有也不影响流程。
#>

param(
    [ValidateSet('run', 'once', 'check', 'selftest', 'learn')]
    [string]$Mode = 'run',
    [string]$Image = ''
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

$Root = $PSScriptRoot
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = Split-Path -Parent $MyInvocation.MyCommand.Definition }
if ([string]::IsNullOrWhiteSpace($Root)) { $Root = (Get-Location).Path }
$Bin     = Join-Path $Root 'bin'
$DataDir = Join-Path $Root 'data'
$LogDir  = Join-Path $Root 'logs'
$Adb     = Join-Path $Bin 'adb.exe'
$CfgFile = Join-Path $Root 'config.json'
$StateFile = Join-Path $DataDir 'state.json'
foreach ($d in @($DataDir, $LogDir)) { if (-not (Test-Path $d)) { New-Item -ItemType Directory -Force -Path $d | Out-Null } }

$script:LogBuf = New-Object System.Collections.Generic.List[string]
$script:W = 1080; $script:H = 2376
$script:Seq = 0
$script:OcrEngine = $null
$script:AsTaskGeneric = $null

function Say([string]$msg, [string]$color = 'Gray') {
    if ([string]::IsNullOrWhiteSpace($color)) { $color = 'Gray' }
    $line = (Get-Date -Format 'HH:mm:ss') + '  ' + $msg
    try {
        Write-Host $line -ForegroundColor $color
    } catch {
        Write-Host $line
    }
    if ($script:LogBuf) { $script:LogBuf.Add($line) }
    # 同时写一份实时日志，方便外部观察进度
    try {
        if ($script:LiveLog) {
            [System.IO.File]::AppendAllText($script:LiveLog, $line + "`r`n", (New-Object System.Text.UTF8Encoding($false)))
        }
    } catch { }
}

# ==================== 配置 ====================
function Get-Config {
    $def = [ordered]@{
        api_base = 'https://api.deepseek.com/v1'
        api_key  = ''
        model    = 'deepseek-chat'
        use_ai   = $true
        think_ms = 0
    }
    if (Test-Path $CfgFile) {
        try {
            $j = Get-Content -Raw -Encoding UTF8 $CfgFile | ConvertFrom-Json
            foreach ($k in @($def.Keys)) {
                if ($j.PSObject.Properties.Name -contains $k -and $j.$k) { $def[$k] = $j.$k }
            }
        } catch { }
    }
    return $def
}
$script:Cfg = Get-Config

# ==================== 图像辅助（仅用于弹窗遮罩判断） ====================
if (-not ('Probe2' -as [type])) {
Add-Type -ReferencedAssemblies System.Drawing -TypeDefinition @'
using System;
using System.Drawing;
public class Probe2 {
    static Bitmap Load(string path) {
        var ms = new System.IO.MemoryStream(System.IO.File.ReadAllBytes(path));
        return new Bitmap(ms);
    }
    public static void Binarize(string src, string dst, int th) {
        using (var ms = new System.IO.MemoryStream(System.IO.File.ReadAllBytes(src)))
        using (var bm = new Bitmap(ms)) {
            using (var nb = new Bitmap(bm.Width, bm.Height)) {
                var rect = new Rectangle(0, 0, bm.Width, bm.Height);
                var data = bm.LockBits(rect, System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                var nd = nb.LockBits(rect, System.Drawing.Imaging.ImageLockMode.WriteOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
                int bytes = Math.Abs(data.Stride) * bm.Height;
                byte[] buf = new byte[bytes];
                System.Runtime.InteropServices.Marshal.Copy(data.Scan0, buf, 0, bytes);
                for (int i = 0; i < bytes; i += 4) {
                    int g = (buf[i + 2] * 30 + buf[i + 1] * 59 + buf[i] * 11) / 100;
                    byte v = (byte)(g < th ? 0 : 255);
                    buf[i] = v; buf[i + 1] = v; buf[i + 2] = v; buf[i + 3] = 255;
                }
                System.Runtime.InteropServices.Marshal.Copy(buf, 0, nd.Scan0, bytes);
                bm.UnlockBits(data);
                nb.UnlockBits(nd);
                nb.Save(dst, System.Drawing.Imaging.ImageFormat.Png);
            }
        }
    }
    public static string FindDividers(string path, int y0, int y1) {
        try {
            using (var ms = new System.IO.MemoryStream(System.IO.File.ReadAllBytes(path)))
            using (var bm = new Bitmap(ms)) {
                int ya = Math.Max(2, y0), yb = Math.Min(bm.Height - 2, y1);
                int cnt = yb - ya;
                if (cnt < 40) return "";
                double[] avg = new double[cnt];
                for (int i = 0; i < cnt; i++) {
                    int y = ya + i;
                    long s = 0; int n = 0;
                    for (int x = 200; x < Math.Min(900, bm.Width); x += 4) {
                        Color p = bm.GetPixel(x, y);
                        s += (p.R * 30 + p.G * 59 + p.B * 11) / 100;
                        n++;
                    }
                    avg[i] = (double)s / n;
                }
                // 局部突变：该行比上下 8px 的平均值高/低 6 以上，且是全宽一致的细线
                var res = new System.Collections.Generic.List<int>();
                for (int i = 8; i < cnt - 8; i++) {
                    double around = (avg[i - 8] + avg[i + 8]) / 2.0;
                    double diff = Math.Abs(avg[i] - around);
                    if (diff >= 5.0) {
                        // 连续同向突变的取中点
                        int j = i;
                        while (j < cnt - 8 && Math.Abs(avg[j] - around) >= 5.0) j++;
                        int mid = (i + j - 1) / 2;
                        if (res.Count == 0 || mid - res[res.Count - 1] > 40) res.Add(ya + mid);
                        i = j;
                    }
                }
                return string.Join(",", res);
            }
        } catch { return ""; }
    }
    public static string RegionSig(string path, int y0, int y1) {
        try {
            using (var ms = new System.IO.MemoryStream(System.IO.File.ReadAllBytes(path)))
            using (var bm = new Bitmap(ms)) {
                int ya = Math.Max(0, y0), yb = Math.Min(bm.Height, y1);
                long sum = 0; int n = 0;
                for (int y = ya; y < yb; y += 7)
                    for (int x = 20; x < bm.Width - 20; x += 9) {
                        Color p = bm.GetPixel(x, y);
                        sum += (p.R * 31 + p.G * 37 + p.B * 41);
                        n++;
                    }
                if (n == 0) return "0";
                return (sum / n).ToString();
            }
        } catch { return "0"; }
    }
    public static string OptColor(string path, int y0, int y1) {
        try {
            using (var ms = new System.IO.MemoryStream(System.IO.File.ReadAllBytes(path)))
            using (var bm = new Bitmap(ms)) {
                int g = 0, r = 0, d = 0, n = 0;
                int x0 = (int)(bm.Width * 0.08), x1 = (int)(bm.Width * 0.92);
                int ya = Math.Max(0, y0), yb = Math.Min(bm.Height, y1);
                for (int y = ya; y < yb; y += 3)
                    for (int x = x0; x < x1; x += 6) {
                        Color p = bm.GetPixel(x, y);
                            if (p.G > 150 && p.G > p.R + 30 && p.G > p.B + 10) g++;
                        if (p.R > 175 && p.G < 155 && p.B < 155 && p.R > p.G + 30) r++;
                        if (p.R < 110 && p.G < 110 && p.B < 110) d++;
                        n++;
                    }
                if (n == 0) return "NONE";
                if (g * 100 / n > 15) return "GREEN";
                if (r * 100 / n > 15) return "RED";
                return "NONE";
            }
        } catch { return "NONE"; }
    }
    public static bool HasMask(string path) {
        try {
            using (var bm = Load(path)) {
                int w = bm.Width, h = bm.Height;
                Color a = bm.GetPixel((int)(w * 0.05), (int)(h * 0.42));
                Color b = bm.GetPixel((int)(w * 0.50), (int)(h * 0.42));
                int la = (a.R * 30 + a.G * 59 + a.B * 11) / 100;
                int lb = (b.R * 30 + b.G * 59 + b.B * 11) / 100;
                return (lb - la) > 45;
            }
        } catch { return false; }
    }
    public static void SaveRegion(string src, string dst, int x, int y, int w, int h, double scale) {
        using (var ms = new System.IO.MemoryStream(System.IO.File.ReadAllBytes(src)))
        using (var bm = new Bitmap(ms)) {
            int rw = Math.Min(w, bm.Width - x), rh = Math.Min(h, bm.Height - y);
            if (rw <= 4 || rh <= 4) return;
            var rect = new Rectangle(x, y, rw, rh);
            using (var nb = new Bitmap((int)(rw * scale), (int)(rh * scale)))
            using (var g = Graphics.FromImage(nb)) {
                g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.HighQualityBicubic;
                g.DrawImage(bm, new Rectangle(0, 0, nb.Width, nb.Height), rect, GraphicsUnit.Pixel);
                nb.Save(dst, System.Drawing.Imaging.ImageFormat.Png);
            }
        }
    }
}
'@
}

# ==================== adb ====================
function Invoke-Adb {
    param([string[]]$Arguments, [switch]$Binary)
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $Adb
    $psi.Arguments = ($Arguments -join ' ')
    $psi.RedirectStandardOutput = $true
    $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false
    $psi.CreateNoWindow = $true
    $p = [System.Diagnostics.Process]::Start($psi)
    if ($Binary) {
        $ms = New-Object System.IO.MemoryStream
        $p.StandardOutput.BaseStream.CopyTo($ms)
        $p.WaitForExit()
        return $ms.ToArray()
    }
    $o = $p.StandardOutput.ReadToEnd()
    $e = $p.StandardError.ReadToEnd()
    $p.WaitForExit()
    return ($o + $e)
}

function Get-Device {
    $txt = Invoke-Adb @('devices')
    $lines = @(($txt -split "`r?`n") | Where-Object { $_ -match '\sdevice\b' })
    if ($lines.Count -gt 0) { return (($lines[0] -split '\s+')[0]) }
    return $null
}

function Shot {
    $bytes = Invoke-Adb @('exec-out', 'screencap', '-p') -Binary
    if (-not $bytes -or $bytes.Length -lt 20000) { return $null }
    $script:Seq++
    $path = Join-Path $DataDir ('_s{0}.png' -f ($script:Seq % 4))
    for ($i = 0; $i -lt 6; $i++) {
        try { [System.IO.File]::WriteAllBytes($path, $bytes); return $path }
        catch { $script:Seq++; $path = Join-Path $DataDir ('_s{0}.png' -f ($script:Seq % 4)); Start-Sleep -Milliseconds 40 }
    }
    return $null
}

function TapPoint([int]$x, [int]$y, [int]$wait = 150) {
    [void](Invoke-Adb @('shell', 'input', 'tap', "$x", "$y"))
    if ($wait -gt 0) { Start-Sleep -Milliseconds $wait }
}

function SwipeP([double]$x1, [double]$y1, [double]$x2, [double]$y2, [int]$ms = 320) {
    [void](Invoke-Adb @('shell', 'input', 'swipe', "$([int]$x1)", "$([int]$y1)", "$([int]$x2)", "$([int]$y2)", "$ms"))
}

# 翻到下一题：手势按屏幕比例，不依赖分辨率
function Advance {
    SwipeP ($script:W * 0.5) ($script:H * 0.78) ($script:W * 0.5) ($script:H * 0.32) 340
    Start-Sleep -Milliseconds 420
}

# ==================== OCR ====================
function Initialize-Ocr {
    if ($script:OcrEngine) { return $true }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $script:AsTaskGeneric = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
            $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
            $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
        })[0]
        [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime] | Out-Null
        [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime] | Out-Null
        [Windows.Graphics.Imaging.BitmapDecoder, Windows.Graphics, ContentType = WindowsRuntime] | Out-Null
        $script:OcrEngine = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        return ($null -ne $script:OcrEngine)
    } catch { return $false }
}

function Await-Op($op, $type) {
    $t = $script:AsTaskGeneric.MakeGenericMethod($type).Invoke($null, @($op))
    $t.Wait(-1) | Out-Null
    $t.Result
}

$script:OcrEngineEn = $null
function Ocr-RawEn([string]$path) {
    if (-not $script:OcrEngineEn) {
        try {
            if (-not $script:AsTaskGeneric) { [void](Initialize-Ocr) }
            [Windows.Globalization.Language, Windows.Globalization, ContentType = WindowsRuntime] | Out-Null
            $lang = New-Object Windows.Globalization.Language 'en-US'
            $script:OcrEngineEn = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage($lang)
        } catch { return @() }
    }
    if (-not $script:OcrEngineEn) { return @() }
    $out = New-Object System.Collections.ArrayList
    $stream = $null; $bmp = $null
    try {
        $file = Await-Op ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
        $stream = Await-Op ($file.OpenAsync(0)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Await-Op ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bmp = Await-Op ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $res = Await-Op ($script:OcrEngineEn.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
        foreach ($line in $res.Lines) {
            $ws = @($line.Words | Select-Object -First 1)
            $y = 0; $x = 0
            if ($ws.Count -gt 0) { $y = [int]$ws[0].BoundingRect.Y; $x = [int]$ws[0].BoundingRect.X }
            if ($line.Text.Trim().Length -gt 0) { [void]$out.Add([pscustomobject]@{ text = $line.Text; x = $x; y = $y; w = 0; h = 0 }) }
        }
    } catch { } finally {
        if ($bmp) { $bmp.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
    return $out.ToArray()
}
function Ocr-Raw([string]$path) {
    if (-not (Initialize-Ocr)) { return @() }
    $out = New-Object System.Collections.ArrayList
    $stream = $null; $bmp = $null
    try {
        $file = Await-Op ([Windows.Storage.StorageFile]::GetFileFromPathAsync($path)) ([Windows.Storage.StorageFile])
        $stream = Await-Op ($file.OpenAsync(0)) ([Windows.Storage.Streams.IRandomAccessStream])
        $decoder = Await-Op ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bmp = Await-Op ($decoder.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $res = Await-Op ($script:OcrEngine.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
        foreach ($line in $res.Lines) {
            $text = ''; $minX = 99999; $minY = 99999; $maxX = 0; $maxY = 0
            foreach ($w in $line.Words) {
                $text += $w.Text
                $r = $w.BoundingRect
                if ($r.X -lt $minX) { $minX = [int]$r.X }
                if ($r.Y -lt $minY) { $minY = [int]$r.Y }
                if (($r.X + $r.Width) -gt $maxX) { $maxX = [int]($r.X + $r.Width) }
                if (($r.Y + $r.Height) -gt $maxY) { $maxY = [int]($r.Y + $r.Height) }
            }
            if ($text.Trim().Length -gt 0) {
                [void]$out.Add([pscustomobject]@{
                    text = $text; x = $minX; y = $minY
                    w = ($maxX - $minX); h = ($maxY - $minY)
                    cx = [int](($minX + $maxX) / 2); cy = [int](($minY + $maxY) / 2)
                })
            }
        }
    } catch { } finally {
        if ($bmp) { $bmp.Dispose() }
        if ($stream) { $stream.Dispose() }
    }
    return $out.ToArray()
}

# 等页面稳定再返回（连续两次 OCR 文本一致）
function Read-StableScreen {
    $prev = ''
    $last = $null
    for ($i = 0; $i -lt 6; $i++) {
        $scr = Read-Screen
        if (-not $scr) {
            Start-Sleep -Milliseconds 400
            continue
        }
        $last = $scr
        if ($scr.text -eq $prev) { return $scr }
        $prev = $scr.text
        Start-Sleep -Milliseconds 450
    }
    return $last
}

# ---------- RapidOCR 常驻服务（识别超大字号英文更准）----------
$script:OcrProc = $null
$script:UseRapid = $false

function Start-OcrServer {
    try {
        $py = (Get-Command python -ErrorAction Stop).Source
    } catch { return $false }
    $helper = Join-Path $Root 'ocr_helper.py'
    if (-not (Test-Path $helper)) { return $false }
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo
        $psi.FileName = $py
        $psi.Arguments = '"' + $helper + '" --server'
        $psi.RedirectStandardInput = $true
        $psi.RedirectStandardOutput = $true
        $psi.UseShellExecute = $false
        $psi.CreateNoWindow = $true
        $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
        $script:OcrProc = [System.Diagnostics.Process]::Start($psi)
        $ready = $script:OcrProc.StandardOutput.ReadLine()
        if ($ready -eq 'READY') { return $true }
    } catch { }
    return $false
}

function Stop-OcrServer {
    if ($script:OcrProc) {
        try { $script:OcrProc.StandardInput.WriteLine('QUIT') } catch { }
        Start-Sleep -Milliseconds 200
        try { if (-not $script:OcrProc.HasExited) { $script:OcrProc.Kill() } } catch { }
        $script:OcrProc = $null
    }
}

function Ocr-Rapid([string]$path) {
    if (-not $script:OcrProc) { return $null }
    try {
        $script:OcrProc.StandardInput.WriteLine($path)
        $script:OcrProc.StandardInput.Flush()
        $rd = $script:OcrProc.StandardOutput.ReadLine()
        if (-not $rd) { return $null }
        $j = $rd | ConvertFrom-Json
        if (-not $j.lines) { return @() }
        return @($j.lines | ForEach-Object {
            [pscustomobject]@{ text = $_.text; x = $_.x; y = $_.y; w = $_.w; h = $_.h; cx = $_.cx; cy = $_.cy }
        })
    } catch { return $null }
}

# 读一屏：优先 RapidOCR，失败退回 Windows OCR
function Read-Screen {
    $p = Shot
    if (-not $p) { return $null }
    # RapidOCR 准确率明显高于 Windows 自带 OCR（后者会把中英混排读成乱码），
    # 所以只要 Rapid 有结果就独占使用，绝不合并，避免乱码污染。
    $ls = @()
    if ($script:UseRapid) { $ls = @(Ocr-Rapid $p) }
    if ($ls.Count -lt 3) {
        $win = @(Ocr-Raw $p)
        if ($win.Count -gt $ls.Count) { $ls = $win }
    }
    $ls = @($ls | Sort-Object y)
    return [pscustomobject]@{
        path  = $p
        lines = $ls
        text  = (($ls | ForEach-Object { $_.text }) -join ' ')
    }
}

# ==================== 状态机（纯文本） ====================
$OptPat = '^\s*[A-Da-d]\s*[.、．:：·]\s*\S'

function Get-OptLines($scr) {
    return @($scr.lines | Where-Object { $_.text -match $OptPat } | Sort-Object y)
}

function Get-State2($scr) {
    if (-not $scr) { return 'NONE' }
    $t = $scr.text
    if ($t -match '今日学习|今日任务|今日完成率|完成率') { return 'HOME' }
    if ($t -match '已完成\s*\d+\s*/\s*\d+' -and $t -match '测试|听力|写作|口语|阅读') { return 'HOME' }
    $confirm = @($scr.lines | Where-Object { $_.text.Length -le 8 -and $_.text -match '^确认|^确定|^我知道了|^知道了|^好的|^继续' })
    if ($confirm.Count -gt 0) { return 'DIALOG' }
    $packCnt = @($scr.lines | Where-Object { $_.text -match '卡包\s*\d' }).Count
    if ($packCnt -ge 2) { return 'PACKLIST' }
    if ($t -match '随堂测试|系统测试') { return 'TESTLIST' }
    if ($t -match '待强化|遇到错词') { return 'STRENGTH' }
    if ($t -match 'COMPLETE|恭喜你完成|本次学习') { return 'DIALOG' }
    $btn = Find-Button $scr
    if ($btn) { return 'DIALOG' }
    $enLines = @($scr.lines | Where-Object { $_.text -match '^[A-Za-z][A-Za-z\-'' ]{2,28}$' })
    $shortPage = (@($scr.lines).Count -le 8)
    if ($enLines.Count -ge 1 -and $shortPage -and $t -match '学习|卡包|\d+\s*/\s*\d+') { return 'LEARN' }
    if ($enLines.Count -ge 1 -and $shortPage -and -not ($t -match '今日|完成率')) { return 'LEARN' }
    $qd = Get-QuizData $scr
    if ($qd) { return 'QUIZ' }
    if ($t -match '学习\s*\d+\s*/\s*\d+') { return 'LEARN' }
    return 'UNKNOWN'
}
function Get-OptsZoom($scr) {
    $base = @(Get-OptLines $scr)
    if ($base.Count -ge 4) { return $base }
    if ($base.Count -eq 0) { return $base }
    try {
        $y0 = [int](($base | Measure-Object y -Minimum).Minimum)
        $y1 = [int](($base | Measure-Object y -Maximum).Maximum)
        $topY = [Math]::Max(0, $y0 - 50)
        $h = [Math]::Min($script:H - $topY, ($y1 - $y0) + 140)
        if ($h -lt 80) { return $base }
        $big = Join-Path $DataDir '_zoombig.png'
        [Probe2]::SaveRegion($scr.path, $big, 0, $topY, $script:W, $h, 2.0)
        $ls2 = @(Ocr-Raw $big)
        $byKey = @{}
        foreach ($ln in $ls2) {
            if ($ln.text -notmatch $OptPat) { continue }
            $kk = ([regex]::Match($ln.text, '^\s*([A-Da-d])')).Groups[1].Value.ToUpper()
            if (-not $kk) { continue }
            $cy = [int]($ln.y / 2) + $topY + [int]($ln.h / 4)
            $cx = [int]($ln.x / 2) + [int]($ln.w / 4)
            $byKey[$kk] = [pscustomobject]@{ text = $ln.text; x = [int]($ln.x / 2); y = ([int]($ln.y / 2) + $topY); w = [int]($ln.w / 2); h = [int]($ln.h / 2); cx = $cx; cy = $cy }
        }
        $merged = @()
        foreach ($k in @('A', 'B', 'C', 'D')) {
            if ($byKey.ContainsKey($k)) { $merged += $byKey[$k] }
            else {
                $old = @($base | Where-Object { $_.text -match ('^\s*' + $k) })[0]
                if ($old) { $merged += $old }
            }
        }
        if ($merged.Count -gt $base.Count) { Say ('选项补识别: ' + $base.Count + ' -> ' + $merged.Count) 'DarkGray' }
        return $merged
    } catch { return $base }
}
$script:BtnPat = '^完成|^结束|^下一步|^开始|开始答题|开始测试|^继续|^我知道了|^确认|^确定|^好的|^准备好了|^立即开始|^进入'

function Find-Button($scr, [string]$mode = 'any') {
    $pat = $script:BtnPat
    if ($mode -eq 'confirm') {
        $pat = '^确认|^确定|^我知道了|^知道了|^好的|^继续|^完成$|^结束'
    }
    $cand = @($scr.lines | Where-Object {
        $_.text.Length -le 10 -and $_.text -match $pat -and
        $_.text -notmatch '^\s*[A-Da-d]\s*[.、．:：·]' -and
        $_.text -notmatch '进入强化|进入学习|待强化|本次学习|强化$' -and
        $_.y -gt ($script:H * 0.18)
    } | Sort-Object y)
    if ($cand.Count -gt 0) { return $cand[0] }
    return $null
}

function Handle-Popup($scr) {
    $st = Get-State2 $scr
    if ($st -eq 'DIALOG' -or $st -eq 'READY' -or $st -eq 'STRENGTH') {
        $btn = Find-Button $scr 'confirm'
        if ($btn) {
            Say ('弹窗/准备页 -> 点「' + $btn.text + '」') 'DarkGray'
            TapPoint $btn.cx $btn.cy 1400
            return $true
        }
    }
    return $false
}

function Group-Lines($lines) {
    $sorted = @($lines | Sort-Object y)
    $clusters = New-Object System.Collections.ArrayList
    $cur = New-Object System.Collections.ArrayList
    $prev = -9999
    foreach ($ln in $sorted) {
        if ($cur.Count -gt 0 -and ($ln.y - $prev) -gt 55) {
            [void]$clusters.Add(@($cur))
            $cur = New-Object System.Collections.ArrayList
        }
        [void]$cur.Add($ln)
        $prev = $ln.y
    }
    if ($cur.Count -gt 0) { [void]$clusters.Add(@($cur)) }
    return $clusters
}

function Get-QuizData($scr) {
    $all = @($scr.lines | Sort-Object y)
    if ($all.Count -lt 4) { return $null }

    # 先按 y 聚类（同一选项被拆成 "A." 和 "raw" 两行时能合起来），再判等距
    $groups = @(Group-Lines $all)
    $optRows = $null
    if ($groups.Count -ge 4) {
        $gc = @($groups | ForEach-Object {
            $mn = [int](($_ | Measure-Object y -Minimum).Minimum)
            [pscustomobject]@{
                y = $mn
                h = 40
                x = [int](($_ | Sort-Object x | Select-Object -First 1).x)
                w = [int](($_ | Measure-Object w -Maximum).Maximum)
                text = (($_ | Sort-Object x | ForEach-Object { $_.text }) -join '')
            }
        })
        for ($i = 0; $i -le $gc.Count - 4; $i++) {
            $g1 = $gc[$i + 1].y - $gc[$i].y
            $g2 = $gc[$i + 2].y - $gc[$i + 1].y
            $g3 = $gc[$i + 3].y - $gc[$i + 2].y
            if ($g1 -gt 70 -and $g1 -lt 420 -and [Math]::Abs($g1 - $g2) -lt 55 -and [Math]::Abs($g2 - $g3) -lt 55) {
                $optRows = @($gc[$i..($i + 3)])
                break
            }
        }
    }
    if (-not $optRows) {
        for ($i = 0; $i -le $all.Count - 4; $i++) {
            $g1 = $all[$i + 1].y - $all[$i].y
            $g2 = $all[$i + 2].y - $all[$i + 1].y
            $g3 = $all[$i + 3].y - $all[$i + 2].y
            if ($g1 -gt 70 -and $g1 -lt 420 -and [Math]::Abs($g1 - $g2) -lt 50 -and [Math]::Abs($g2 - $g3) -lt 50) {
                $optRows = @($all[$i..($i + 3)])
                break
            }
        }
    }

    $opts = @{}
    $letters = @('A', 'B', 'C', 'D')
    $optTopY = 0
    if ($optRows) {
        $optTopY = [int]$optRows[0].y
        $span = [int]$optRows[3].y - [int]$optRows[0].y
        $rowH = [int]($span / 3)
        if ($rowH -lt 60 -or $rowH -gt 400) { $rowH = 150 }

        # 首选：检测选项之间的分隔线，用它算真实行中心（最准）
        # 实测：行中心 = 文字顶部 + 25（与分隔线推算一致）
        $centers = @()
        for ($i = 0; $i -lt 4; $i++) { $centers += [int]$optRows[$i].y + 25 }

        for ($i = 0; $i -lt 4; $i++) {
            $ln = $optRows[$i]
            $clean = [regex]::Replace($ln.text, '^\s*[A-Da-d]\s*[.、．:：·]\s*', '')
            $clean = [regex]::Replace($clean, '^\s*[A-Da-d]\s+', '')
            $clean = $clean -replace '[丨｜¦│]', 'l'
            $clean = $clean.Trim()
            if ($clean.Length -lt 1) { continue }
            $opts[$letters[$i]] = [pscustomobject]@{
                text = $clean; x = [int]$ln.x; y = [int]$centers[$i]; w = [int]$ln.w; h = $rowH
                cx = [int]($script:W * 0.5); cy = [int]$centers[$i]
            }
        }
    }

    if ($opts.Count -lt 3) {
        # 退化路径：按簇分组
        $zone = @($all | Where-Object { $_.y -gt ($script:H * 0.28) })
        if ($zone.Count -lt 3) { $zone = $all }
        $clusters = @(Group-Lines $zone)
        if ($clusters.Count -lt 3) { return $null }
        $take = [Math]::Min(4, $clusters.Count)
        $use = @($clusters[($clusters.Count - $take)..($clusters.Count - 1)])
        if ($use.Count -gt 0) { $optTopY = [int](($use[0] | Measure-Object y -Minimum).Minimum) }
        for ($i = 0; $i -lt $use.Count; $i++) {
            $cl = $use[$i]
            $raw = (($cl | ForEach-Object { $_.text }) -join '')
            $clean = [regex]::Replace($raw, '^\s*[A-Da-d]\s*[.、．:：·]\s*', '')
            $clean = $clean -replace '[丨｜¦│]', 'l'
            $clean = $clean.Trim()
            if ($clean.Length -lt 1) { continue }
            $xmid = 0
            foreach ($lnl in $cl) { $xmid += $lnl.x + [int]($lnl.w / 2) }
            $xmid = [int]($xmid / $cl.Count)
            $opts[$letters[$i]] = [pscustomobject]@{
                text = $clean; x = [int]($cl[0].x); y = [int](($cl | Measure-Object y -Minimum).Minimum)
                w = $script:W; h = 40; cx = [int]($script:W * 0.5); cy = ([int](($cl | Measure-Object y -Minimum).Minimum) + 75)
            }
        }
    }
    if ($opts.Count -lt 4) { return $null }

    # 严格校验：4 个选项文本必须互不相同、长度合理
    $txts = @()
    foreach ($k in @('A','B','C','D')) { if ($opts.ContainsKey($k)) { $txts += $opts[$k].text } }
    if ($txts.Count -lt 3) { return $null }
    $uniq = @($txts | Select-Object -Unique)
    if ($uniq.Count -lt $txts.Count) { return $null }
    foreach ($tx in $txts) { if ($tx.Length -lt 2 -or $tx.Length -gt 90) { return $null } }

    # 题干：选项上方、排除字母行
    $stemParts = @($all | Where-Object {
        $_.y -lt ($optTopY - 12) -and $_.y -gt ($script:H * 0.17) -and
        $_.text -notmatch '条\]|不想说话|KB/s' -and
        $_.text.Length -ge 1 -and
        $_.text -notmatch '^[A-Da-d]\s*[.、．:：·]' -and
        $_.text -notmatch '学习|强化|完成|进度|卡包|三级词书|词书|\d+\s*/\s*\d+|^\s*\d{1,2}[：:]\d{2}|KB/s|CD|5G|4G'
    } | ForEach-Object { $_.text })
    $stem = ($stemParts -join '').Trim()
    $stem = [regex]::Replace($stem, '(?<=[\u4e00-\u9fff])\s+(?=[\u4e00-\u9fff])', '')

    # 题干实在读不到 -> 放大题干区
    if (($stem.Length -lt 2 -or $stem -match "条\]|不想说话") -and $optTopY -gt 260) {
        try {
            $sy0 = [Math]::Max([int]($script:H * 0.15), [int]$optTopY - 720)
            $sh = [int]$optTopY - $sy0 - 25
            if ($sh -gt 90) {
                $sbig = Join-Path $DataDir '_stembig.png'
                [Probe2]::SaveRegion($scr.path, $sbig, 0, $sy0, $script:W, $sh, 1.0)
                $stx = ''
                if ($script:UseRapid) {
                    $sls = @(Ocr-Rapid $sbig)
                    if ($sls.Count -gt 0) {
                        $parts = @($sls | Where-Object {
                            $_.text.Length -ge 1 -and
                            $_.text -notmatch '^\s*[A-Da-d]\s*[.、．:：·]' -and
                            $_.text -notmatch '^\s*\d+\s*$|学习|强化|完成|卡包|三级词书|KB/s|5G|4G|CD'
                        } | Sort-Object y | ForEach-Object { $_.text })
                        $stx = (($parts -join '')).Trim()
                    }
                }
                if ($stx.Length -lt 2) {
                    $sls2 = @(Ocr-Raw $sbig)
                    if ($sls2.Count -gt 0) {
                        $parts2 = @($sls2 | Where-Object {
                            $_.text.Length -ge 1 -and
                            $_.text -notmatch '^\s*[A-Da-d]\s*[.、．:：·]' -and
                            $_.text -notmatch '^\s*\d+\s*$|学习|强化|完成|卡包|三级词书|KB/s|5G|4G|CD'
                        } | Sort-Object y | ForEach-Object { $_.text })
                        $stx = (($parts2 -join '')).Trim()
                    }
                }
                if ($stx.Length -ge 1) { $stem = $stx }
            }
        } catch { }
    }
    if ($stem.Length -lt 1) { return $null }
    if ($stem.Length -gt 80) { return $null }
    foreach ($tx in $txts) { if ($stem -eq $tx) { return $null } }
    return [pscustomobject]@{ stem = $stem; opts = $opts }
}
function Load-State {
    if (Test-Path $StateFile) {
        try {
            $raw = Get-Content -Raw -Encoding UTF8 $StateFile
            if ($raw.Trim()) {
                $j = $raw | ConvertFrom-Json
                foreach ($k in @('q', 'w', 'zh')) {
                    $h = @{}
                    if ($j.PSObject.Properties.Name -contains $k -and $j.$k) {
                        foreach ($p in $j.$k.PSObject.Properties) { $h[$p.Name] = $p.Value }
                    }
                    $script:Store[$k] = $h
                }
            }
        } catch { }
    }
}
function Save-State {
    try {
        $obj = [ordered]@{ q = $script:Store.q; w = $script:Store.w; zh = $script:Store.zh }
        [System.IO.File]::WriteAllText($StateFile, (ConvertTo-Json -InputObject $obj -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding($false)))
    } catch { }
}
function Get-QKey([string]$stem) {
    $s = ($stem -replace '[^\u4e00-\u9fa5A-Za-z0-9]', '').ToLower()
    if ($s.Length -gt 9) { $s = $s.Substring(0, 9) }
    $md5 = [System.Security.Cryptography.MD5]::Create()
    $h = $md5.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($s))
    return ([System.BitConverter]::ToString($h) -replace '-', '').Substring(0, 16)
}

# ==================== 词典 ====================
function Invoke-DictApi([string]$q) {
    try {
        $r = Invoke-RestMethod -Uri ('https://dict.youdao.com/suggest?q=' + [uri]::EscapeDataString($q) + '&num=6&doctype=json') -TimeoutSec 8 -UserAgent 'Mozilla/5.0'
        if ($r.data.entries) { return @($r.data.entries) }
    } catch { }
    return @()
}
function Get-EnExplain([string]$word) {
    $w = $word.ToLower()
    if ($script:Store.w.ContainsKey($w)) { return $script:Store.w[$w] }
    $entries = Invoke-DictApi $w
    $best = ''
    foreach ($e in $entries) { if ($e.entry -and $e.entry.ToLower() -eq $w -and $e.explain) { $best = $e.explain; break } }
    if (-not $best -and @($entries).Count -gt 0) { $best = (@($entries)[0]).explain }
    if ($best) { $script:Store.w[$w] = $best; Save-State }
    return $best
}
function Get-ZhToEn([string]$phrase) {
    $p1 = $phrase.Trim()
    if (-not $p1) { return @() }
    if ($script:Store.zh.ContainsKey($p1)) { return $script:Store.zh[$p1] }
    $set = New-Object System.Collections.Generic.HashSet[string]
    foreach ($e in (Invoke-DictApi $p1)) {
        if (-not $e.explain) { continue }
        foreach ($piece in ($e.explain -split '[;,；，]')) {
            $t = $piece.Trim().TrimEnd('.', [char]0x2026)
            if ($t -match '^[A-Za-z][A-Za-z\- ]{0,24}$') { [void]$set.Add($t.ToLower()) }
        }
    }
    $arr = @($set)
    if ($arr.Count -gt 0) { if ($arr.Count -gt 20) { $arr = $arr[0..19] }; $script:Store.zh[$p1] = $arr; Save-State }
    return $arr
}

# ==================== 文本工具 ====================
function Split-ZhTokens([string]$s) {
    $t = [regex]::Replace($s, '[（(][^）)]*[）)]', ' ')
    $t = [regex]::Replace($t, '[（(].*$', ' ')
    $t = [regex]::Replace($t, '(?<=[\u4e00-\u9fff])\s+(?=[\u4e00-\u9fff])', '')
    $t = [regex]::Replace($t, '[^\u4e00-\u9fff]+', ' ')
    $stop = '^(的|了|和|与|或|是|在|把|被|给|对|从|向|及|之|使|其|而|且|就|都|也|很|更|最|等|以|为|于|上|下|中|人|事|物)$'
    $o = @()
    foreach ($p1 in ($t -split '\s+')) { $v = $p1.Trim(); if ($v.Length -eq 0) { continue }; if ($v -match $stop) { continue }; $o += $v }
    return $o
}
function Get-ZhSim([string]$a, [string]$b) {
    $ta = @(Split-ZhTokens $a); $tb = @(Split-ZhTokens $b)
    if ($ta.Count -eq 0 -or $tb.Count -eq 0) { return 0.0 }
    $short = $ta; $long = $tb
    if ($ta.Count -gt $tb.Count) { $short = $tb; $long = $ta }
    $sum = 0.0
    foreach ($x in $short) {
        $best = 0.0
        foreach ($y in $long) {
            if ($x -eq $y) { $best = 1.0 }
            elseif ($x.Contains($y) -or $y.Contains($x)) { if ($best -lt 0.85) { $best = 0.85 } }
        }
        $sum += $best
    }
    return [Math]::Round(($sum / $short.Count), 3)
}
function Get-PosSet([string]$text) {
    $h = @{}
    foreach ($m in [regex]::Matches($text, '(?i)\b(n|v|vt|vi|adj|adv|prep|conj|pron|num|art|int)\s*[.·．:：]')) {
        $p1 = $m.Groups[1].Value.ToLower()
        if ($p1 -eq 'vt' -or $p1 -eq 'vi') { $p1 = 'v' }
        $h[$p1] = $true
    }
    return $h
}
function Get-PosBonus($a, $b) {
    if ($a.Count -eq 0 -or $b.Count -eq 0) { return 0.0 }
    foreach ($p1 in $a.Keys) { if ($b.ContainsKey($p1)) { return 0.25 } }
    return -0.2
}
function Test-WordMatch([string]$a, [string]$b) {
    if (-not $a -or -not $b) { return $false }
    $a = $a.ToLower().Trim(); $b = $b.ToLower().Trim()
    if ($a -eq $b) { return $true }
    if ($a.Length -ge 3 -and $b.Length -ge 3) {
        if ($a.StartsWith($b) -or $b.StartsWith($a)) { return $true }
        if ($a.Length -ge 5 -and $b.Length -ge 5 -and $a.Substring(0, 4) -eq $b.Substring(0, 4) -and [Math]::Abs($a.Length - $b.Length) -le 2) { return $true }
    }
    return $false
}

# ==================== AI 判题 ====================
$script:AiFail = 0
function Ask-AI([string]$stem, $opts) {
    if (-not $script:Cfg.use_ai -or -not $script:Cfg.api_key) { return $null }
    if ($script:AiFail -ge 12) { return $null }   # 连续失败才停用，成功会清零
    $keys = @($opts.Keys | Sort-Object)
    $lines = @()
    foreach ($k in $keys) { $lines += ("$k. " + $opts[$k].text) }
    $isEnStem = ($stem -match '^[a-zA-Z][a-zA-Z\-]{1,24}$')
    $content = "你是英语词汇选择题判题器。" + [char]10
    if ($isEnStem) {
        $content += "题干是一个英文单词，但它是由截图 OCR 得到的，可能有识别错字（例如 umon 实际是 union、screan 实际是 scream、lnspire 实际是 inspire）。请先结合四个选项的中文释义，推断题干最可能是哪个真实英文单词，再做选择。" + [char]10
    } else {
        $content += "题干是一段中文释义（可能带 n./v./adj./adv. 词性标注），四个选项是与它对应的英文单词或中文释义。请先确定题干所指的英文单词，再选出语义一致的那个选项。" + [char]10
    }
    $content += "判断原则：词性不符的选项直接排除；同义词近义词算对；形近但意思不同的不要选。" + [char]10
    $content += "题干：" + $stem + [char]10
    $content += "选项：" + [char]10 + ($lines -join [char]10) + [char]10
    $content += "只输出一个字母（A/B/C/D），不要任何解释。"
    $body = @{
        model       = $script:Cfg.model
        messages    = @(@{ role = 'user'; content = $content })
        temperature = 0
        max_tokens  = 8
    } | ConvertTo-Json -Depth 6
    $headers = @{ Authorization = ('Bearer ' + $script:Cfg.api_key); 'Content-Type' = 'application/json' }
    for ($try = 0; $try -lt 2; $try++) {
        try {
            $r = Invoke-RestMethod -Uri ($script:Cfg.api_base.TrimEnd('/') + '/chat/completions') -Method Post -Headers $headers -Body ([System.Text.Encoding]::UTF8.GetBytes($body)) -TimeoutSec 25
            $ans = [string]$r.choices[0].message.content
            $m = [regex]::Match($ans.ToUpper(), '[ABCD]')
            if ($m.Success -and $opts.ContainsKey($m.Value)) {
                $script:AiFail = 0     # 成功即清零，绝不能因为几次抖动就永久停用 AI
                return $m.Value
            }
        } catch { Start-Sleep -Milliseconds 300 }
    }
    $script:AiFail++
    return $null
}

# ==================== 兜底判题（本地词典） ====================
function Get-AnswerLocal($stem, $opts) {
    if ($opts.Count -lt 2) { return $null }
    $key = Get-QKey $stem
    if ($script:Store.q.ContainsKey($key)) {
        $ansText = $script:Store.q[$key].ans
        $bk = $null; $bs = 0.0
        foreach ($k in $opts.Keys) {
            $s = Get-ZhSim $opts[$k].text $ansText
            if ($s -gt $bs) { $bs = $s; $bk = $k }
        }
        if ($bk -and $bs -ge 0.5) { return $bk }
    }
    $lc = ([regex]::Matches($stem, '[A-Za-z]')).Count
    $isEn = ($lc -ge 3 -and ($lc * 2) -gt $stem.Length)
    $allZh = $true
    foreach ($k in $opts.Keys) { if ($opts[$k].text -notmatch '[\u4e00-\u9fff]') { $allZh = $false } }
    $stemPos = Get-PosSet $stem

    if ($isEn -and $allZh) {
        $w = ([regex]::Match($stem, "[A-Za-z][A-Za-z\-']{1,28}")).Value.ToLower()
        $explain = Get-EnExplain $w
        $wordPos = @{}
        if ($explain) { $wordPos = Get-PosSet $explain }
        $bk = $null; $bs = -9.0
        foreach ($k in $opts.Keys) {
            $sim = 0.0
            if ($explain) { $sim = Get-ZhSim $explain $opts[$k].text }
            $back = @(); foreach ($tk in (Split-ZhTokens $opts[$k].text)) { $back += @(Get-ZhToEn $tk) }
            $hit = 0
            foreach ($c in $back) { if (Test-WordMatch $w $c) { $hit = 1; break } }
            $score = $sim + ($hit * 1.0) + (Get-PosBonus $wordPos (Get-PosSet $opts[$k].text))
            if ($score -gt $bs) { $bs = $score; $bk = $k }
        }
        if ($bk -and $bs -gt 0) { return $bk }
        return $null
    }

    $frags = @(Split-ZhTokens $stem)
    if ($frags.Count -gt 4) { $frags = $frags[0..3] }
    if ($frags.Count -eq 0) { return $null }
    $stemSet = New-Object System.Collections.Generic.HashSet[string]
    foreach ($f in $frags) { foreach ($x in (Get-ZhToEn $f)) { [void]$stemSet.Add($x) } }
    $allEn = $true
    foreach ($k in $opts.Keys) { if ($opts[$k].text -match '[\u4e00-\u9fff]') { $allEn = $false } }

    if ($allEn) {
        $bk = $null; $bs = -9.0
        foreach ($k in $opts.Keys) {
            $w = (($opts[$k].text -split '\s+')[0]).Trim()
            $hit = 0
            foreach ($c in $stemSet) { if (Test-WordMatch $w $c) { $hit = 1; break } }
            $ex = Get-EnExplain $w
            $sim = 0.0; $optPos = @{}
            if ($ex) { $sim = Get-ZhSim $stem $ex; $optPos = Get-PosSet $ex }
            $score = ($hit * 1.2) + $sim + (Get-PosBonus $stemPos $optPos)
            if ($score -gt $bs) { $bs = $score; $bk = $k }
        }
        if ($bk -and $bs -gt 0) { return $bk }
        return $null
    }

    $bk = $null; $bs = -9.0
    foreach ($k in $opts.Keys) {
        $hits = 0
        $allW = @(); foreach ($tk in (Split-ZhTokens $opts[$k].text)) { $allW += @(Get-ZhToEn $tk) }
        foreach ($w in $allW) {
            foreach ($c in $stemSet) { if (Test-WordMatch $w $c) { $hits++; break } }
        }
        $score = ($hits * 1.2) + (Get-PosBonus $stemPos (Get-PosSet $opts[$k].text))
        if ($score -gt $bs) { $bs = $score; $bk = $k }
    }
    if ($bk -and $bs -gt 0) { return $bk }
    return $null
}

# ==================== 数据质量门禁 ====================
# 返回空字符串表示数据可信；非空表示不可信的原因（要停下来）
function Test-QuizData([string]$stem, $opts) {
    if ($stem.Length -lt 1) { return '题干太短' }
    if ($stem.Length -gt 90) { return '题干过长' }
    # 乱码特征：中英混杂的碎片、连续标点、孤立的音标符号
    if ($stem -match '[·•｜¦]{3,}') { return '题干含连续乱码符号' }
    if ($stem -match '[\u4e00-\u9fa5]\s*[·•]\s*[\u4e00-\u9fa5]\s*[·•]') { return '题干呈碎片化' }
    if ($stem -match '[\u4e00-\u9fa5]{1,3}[·•][a-zA-Z]{1,2}[·•]') { return '题干中英混杂碎片' }
    if ($stem -match '(匕|囗|丷|丶|丨)') { return '题干含生僻识别错字' }
    if (@($opts.Keys).Count -lt 4) { return '选项不足 4 个' }
    $seen = @{}
    foreach ($k in @('A','B','C','D')) {
        if (-not $opts.ContainsKey($k)) { return ('缺少选项 ' + $k) }
        $t = [string]$opts[$k].text
        if ($t.Length -lt 2) { return ('选项 ' + $k + ' 过短') }
        if ($t.Length -gt 90) { return ('选项 ' + $k + ' 过长') }
        if ($seen.ContainsKey($t)) { return ('选项 ' + $k + ' 与前面重复') }
        $seen[$t] = 1
        # 选项里不该出现连续乱码符号
        if ($t -match '[·•｜¦]{4,}') { return ('选项 ' + $k + ' 含乱码') }
    }
    return ''
}

# ==================== 题干纠错（OCR 认错英文单词时） ====================
function Get-EditDistance([string]$a, [string]$b) {
    $a = $a.ToLower(); $b = $b.ToLower()
    $la = $a.Length; $lb = $b.Length
    if ($la -eq 0) { return $lb }
    if ($lb -eq 0) { return $la }
    $prev = New-Object int[] ($lb + 1)
    $cur = New-Object int[] ($lb + 1)
    for ($j = 0; $j -le $lb; $j++) { $prev[$j] = $j }
    for ($i = 1; $i -le $la; $i++) {
        $cur[0] = $i
        for ($j = 1; $j -le $lb; $j++) {
            $cost = 1
            if ($a[$i - 1] -eq $b[$j - 1]) { $cost = 0 }
            $v1 = $prev[$j] + 1
            $v2 = $cur[$j - 1] + 1
            $v3 = $prev[$j - 1] + $cost
            $m = $v1
            if ($v2 -lt $m) { $m = $v2 }
            if ($v3 -lt $m) { $m = $v3 }
            $cur[$j] = $m
        }
        for ($j = 0; $j -le $lb; $j++) { $prev[$j] = $cur[$j] }
    }
    return $prev[$lb]
}

# 题干是英文短词时，用各选项反查出的英文单词做拼写比对，纠正 OCR 错字
function Correct-EnglishStem($stem, $opts) {
    $s = $stem.Trim().ToLower()
    if ($s -notmatch '^[a-z]{3,20}$') { return $null }
    # 词典查不到才纠错（能查到说明词是对的）
    $ex = Get-EnExplain $s
    if ($ex) { return $null }
    $bestK = $null; $bestSim = 0.0; $bestW = ''
    foreach ($k in $opts.Keys) {
        $toks = @(Split-ZhTokens $opts[$k].text)
        foreach ($tk in $toks) {
            foreach ($w in (Get-ZhToEn $tk)) {
                if ($w.Length -lt 3 -or $w -notmatch '^[a-z\- ]+$') { continue }
                $w1 = ($w -split ' ')[0]
                $d = Get-EditDistance $s $w1
                $maxLen = [Math]::Max($s.Length, $w1.Length)
                if ($maxLen -eq 0) { continue }
                $sim = 1.0 - ($d / $maxLen)
                if ($sim -gt $bestSim) { $bestSim = $sim; $bestK = $k; $bestW = $w1 }
            }
        }
    }
    if ($bestK -and $bestSim -ge 0.62) { return @($bestK, $bestW, [Math]::Round($bestSim, 2)) }
    return $null
}

# ==================== 判题入口 ====================
function Decide($stem, $opts) {
    if (-not $script:Store) { $script:Store = @{ q = @{}; w = @{}; zh = @{} } }
    foreach ($sk in @('q', 'w', 'zh')) { if (-not $script:Store[$sk]) { $script:Store[$sk] = @{} } }
    # 题干是英文且词典查不到 -> 先用拼写比对纠错（OCR 可能认错单词）
    $fix = Correct-EnglishStem $stem $opts
    if ($fix) { return @($fix[0], ('纠错->' + $fix[1])) }
    # AI 优先（记忆可能被污染，只作兜底）
    $ai = Ask-AI $stem $opts
    if ($ai) { return @($ai, 'AI') }
    $key = Get-QKey $stem
    if ($script:Store.q.ContainsKey($key)) {
        $ansText = $script:Store.q[$key].ans
        $bk = $null; $bs = 0.0
        foreach ($k in $opts.Keys) {
            $s = Get-ZhSim $opts[$k].text $ansText
            if ($s -gt $bs) { $bs = $s; $bk = $k }
        }
        if ($bk -and $bs -ge 0.6) { return @($bk, '记忆') }
    }
    $local = Get-AnswerLocal $stem $opts
    if ($local) { return @($local, '词典') }
    return @($null, '未知')
}

# ==================== 动作 ====================
function Click-Option($opt) {
    TapPoint $opt.cx $opt.cy 140
}

# 点击选项：整行可点，横向左侧（远离边缘）更稳；必须"换题/结算"才算成功
function Click-OptionRobust($opt, [string]$stem, [string]$shotPath) {
    # 点选项只是"选中"，页面不会自己翻，必须上滑才进下一题。
    # 所以这里只负责点选，返回 App 是否给了对错标记（null=没反应）。
    TapPoint ([int]($script:W * 0.4)) ([int]$opt.cy) 200
    Start-Sleep -Milliseconds 1200
    $shot2 = Shot
    if (-not $shot2) { return $null }
    return $shot2
}
function Find-Line($scr, [string]$pat) {
    return @($scr.lines | Where-Object { $_.text -match $pat } | Sort-Object y) | Select-Object -First 1
}

function Do-Home {
    # 回首页：优先点左上角返回箭头（小程序内部返回），绝不用系统返回键（会退出小程序）
    for ($i = 0; $i -lt 8; $i++) {
        $scr = Read-StableScreen
        if (-not $scr) { Start-Sleep -Milliseconds 500; continue }
        $st = Get-State2 $scr
        if ($st -eq 'HOME') { return $true }
        if ($st -eq 'QUIZ' -or $st -eq 'LEARN') {
            # 答题/卡片页不动（会打乱做题）
            return $false
        }
        if (Handle-Popup $scr) { continue }
        # 点左上角返回箭头（图标区域）
        $backX = [int]($script:W * 0.055)
        $backY = [int]($script:H * 0.065)
        TapPoint $backX $backY 1500
    }
    $scr2 = Read-StableScreen
    if ($scr2 -and (Get-State2 $scr2) -eq 'HOME') { return $true }
    return $false
}
function Run-Quiz([int]$limit = 300) {
    $done = 0
    $lastStem = ''
    $failCount = 0
    $script:BtnRepeat = 0
    $script:LastBtnKey = ''
    while ($done -lt $limit) {
        $scr = Read-StableScreen
        if (-not $scr) {
            $failCount++
            if ($failCount -ge 12) {
                Write-Host ''
                Say '========================================' 'Red'
                Say '  手机断开连接了，已停止' 'Red'
                Say '========================================' 'Red'
                Say '  检查数据线，重新插好后再次运行' 'Yellow'
                return $done
            }
            Start-Sleep -Milliseconds 600
            continue
        }
        $failCount = 0
    $script:BtnRepeat = 0
    $script:LastBtnKey = ''
        $st = Get-State2 $scr

        if ($st -eq 'HOME') { return $done }

        if ($st -eq 'DIALOG' -or $st -eq 'STRENGTH' -or $st -eq 'READY') {
            $btn = Find-Button $scr 'confirm'
            if ($btn) {
                if ($script:LastBtnKey -eq $btn.text) { $script:BtnRepeat++ } else { $script:BtnRepeat = 0 }
                $script:LastBtnKey = $btn.text
                if ($script:BtnRepeat -ge 3) {
                    Write-Host ''
                    Say '========================================' 'Red'
                    Say ('  「' + $btn.text + '」点了 4 次还是没消失，已停止') 'Red'
                    Say '========================================' 'Red'
                    Say '  请在手机上手动处理一下，再重新运行' 'Yellow'
                    return $done
                }
                Say ('点「' + $btn.text + '」') 'DarkGray'
                TapPoint $btn.cx $btn.cy 1300
                continue
            }
            return $done
        }

        if ($st -eq 'LEARN') { Advance; Start-Sleep -Milliseconds 650; continue }
        if ($st -ne 'QUIZ') { return $done }

        $qd = Get-QuizData $scr
        if (-not $qd -and $st -eq 'QUIZ') {
            # 状态是答题页但选项没解析全（OCR 偶发漏行）-> 重抓重识别
            for ($rt = 0; $rt -lt 3; $rt++) {
                Say ('  选项没解析全，重新识别 ' + ($rt + 1) + '/3') 'DarkGray'
                Start-Sleep -Milliseconds 800
                $scrR2 = Read-Screen
                if (-not $scrR2) { continue }
                $qdR2 = Get-QuizData $scrR2
                if ($qdR2) { $scr = $scrR2; $qd = $qdR2; break }
            }
        }
        if (-not $qd) {
            # 单词卡片页（还没出题）才会走到上滑；其余情况一律视为识别失败并停止
            if ($scr.text -match '学习\s*\d+\s*/\s*\d+' -and $scr.text -notmatch '[A-D]\s*[.、．:：]') {
                Advance
                Start-Sleep -Milliseconds 650
                continue
            }
            Write-Host ''
            Say '========================================' 'Red'
            Say '  这屏识别不出题目，已停止' 'Red'
            Say '========================================' 'Red'
            Say ('  页面文字：' + $scr.text.Substring(0, [Math]::Min(220, $scr.text.Length))) 'Yellow'
            Say '  可能是页面还没加载完，重新运行即可' 'Yellow'
            Write-Host ''
            return $done
        }

        # 先过质量门禁：数据不可信就停，绝不带着脏数据答题
        $badWhy = Test-QuizData $qd.stem $qd.opts
        if ($badWhy -ne '') {
            # 拦截前先重试一次识别（页面可能刚好在重绘）
            Say ('  识别存疑（' + $badWhy + '），重新识别中') 'Yellow'
            Start-Sleep -Milliseconds 900
            $scR = Read-Screen
            if ($scR) {
                $qdR = Get-QuizData $scR
                if ($qdR) {
                    $badWhyR = Test-QuizData $qdR.stem $qdR.opts
                    if ($badWhyR -eq '') {
                        $qd = $qdR
                        $badWhy = ''
                        Say '  重新识别成功' 'Green'
                    } else {
                        # 仍然不可靠：裁出题干区单独识别（整屏识别时长文本容易串行）
                        try {
                            $optA = $qdR.opts['A']
                            $sy0 = [Math]::Max([int]($script:H * 0.12), [int]$optA.y - 760)
                            $sh = [int]$optA.y - $sy0 - 40
                            if ($sh -gt 120) {
                                $stemPic = Join-Path $DataDir '_stemzoom.png'
                                [Probe2]::SaveRegion($scR.path, $stemPic, 0, $sy0, $script:W, $sh, 1.0)
                                $sls = @()
                                if ($script:UseRapid) { $sls = @(Ocr-Rapid $stemPic) }
                                if (@($sls).Count -eq 0) { $sls = @(Ocr-Raw $stemPic) }
                                if (@($sls).Count -gt 0) {
                                    $parts = @($sls | Where-Object {
                                        $_.text.Length -ge 2 -and
                                        $_.text -notmatch '^\s*[A-Da-d]\s*[.、．:：·]' -and
                                        $_.text -notmatch '学习|强化|完成|卡包|词书|KB/s|5G|4G|CD|^\s*\d+\s*$'
                                    } | Sort-Object y | ForEach-Object { $_.text })
                                    $st2 = (($parts -join '')).Trim()
                                    if ($st2.Length -ge 2) {
                                        $qdR.stem = $st2
                                        $badWhyR = Test-QuizData $qdR.stem $qdR.opts
                                        if ($badWhyR -eq '') {
                                            $qd = $qdR
                                            $badWhy = ''
                                            Say ('  题干区单独识别成功：' + $st2) 'Green'
                                        }
                                    }
                                }
                            }
                        } catch { }
                    }
                }
            }
        }
        if ($badWhy -ne '') {
            Write-Host ''
            Say '========================================' 'Red'
            Say '  这一屏识别不可靠，已停止' 'Red'
            Say '========================================' 'Red'
            Say ('  原因：' + $badWhy) 'Yellow'
            Say ('  题干：' + $qd.stem) 'Yellow'
            foreach ($dk in @('A','B','C','D')) {
                if ($qd.opts.ContainsKey($dk)) { Say ('    ' + $dk + '. ' + $qd.opts[$dk].text) 'Yellow' }
            }
            Say '  请手动处理，或在手机上看一眼题目' 'Yellow'
            Say '' ''
            return $done
        }
        $ans, $why = Decide $qd.stem $qd.opts
        # 点击点越界保护（重新识别后坐标可能变了）：太靠边（<5% 或 >93%）就停，不硬点
        if ($ans) {
            $tcy = [int]$qd.opts[$ans].cy
            $safeTop = [int]($script:H * 0.05)
            $safeBot = [int]($script:H * 0.93)
            if ($tcy -lt $safeTop -or $tcy -gt $safeBot) {
                # 越界时先小幅上滑，让选项整体上移，再重新定位
                Say ('  目标行越界(y=' + $tcy + ')，先滚一下') 'Yellow'
                $dy = 0
                if ($tcy -gt $safeBot) { $dy = [int]($script:H * 0.10) } else { $dy = -[int]($script:H * 0.10) }
                $swx = [int]($script:W * 0.5)
                $swy1 = [int]($script:H * 0.62)
                $swy2 = $swy1 - $dy
                SwipeP $swx $swy1 $swx $swy2 400
                Start-Sleep -Milliseconds 1400
                $scrR = Read-Screen
                if ($scrR) { $qdR = Get-QuizData $scrR }
                if ($qdR -and $qdR.opts.ContainsKey($ans)) {
                    $qd.opts[$ans].cy = [int]$qdR.opts[$ans].cy
                    $tcy = [int]$qd.opts[$ans].cy
                    Say ('  滚动后新位置 y=' + $tcy) 'DarkGray'
                }
            }
            if ($tcy -lt $safeTop -or $tcy -gt $safeBot) {
                Write-Host ''
                Say '========================================' 'Red'
                Say '  算出的点击点太靠边，已停止' 'Red'
                Say '========================================' 'Red'
                Say ('  题干：' + $qd.stem + '   想选：' + $ans) 'Yellow'
                Say ('  点击点 y=' + $tcy + '  屏幕高 ' + $script:H + '（安全区 ' + $safeTop + '-' + $safeBot + '）') 'Yellow'
                foreach ($dk in @('A','B','C','D')) {
                    if ($qd.opts.ContainsKey($dk)) { Say ('    ' + $dk + '. y=' + $qd.opts[$dk].cy + '  ' + $qd.opts[$dk].text) 'Yellow' }
                }
                Say '  选项可能已滑出安全区，请手动处理' 'Yellow'
                Write-Host ''
                return $done
            }
        }
        if (-not $ans) {
            Write-Host '' ''
            Say '========================================' 'Red'
            Say '  这道题没把握，已停止做题' 'Red'
            Say '========================================' 'Red'
            Say ('  题干：' + $qd.stem) 'Yellow'
            foreach ($dk in @('A','B','C','D')) {
                if ($qd.opts.ContainsKey($dk)) { Say ('    ' + $dk + '. ' + $qd.opts[$dk].text) 'Yellow' }
            }
            Say ('  原因：' + $why) 'Yellow'
            Say '  请你手动选一个，然后重新双击运行继续' 'Yellow'
            Write-Host ''
            return $done
        }
        $show = $qd.stem
        if ($show.Length -gt 28) { $show = $show.Substring(0, 28) }
        Say ("[$done] $show -> $ans ($why)") $(if ($why -eq 'AI') { 'Green' } elseif ($why -eq '记忆') { 'Cyan' } else { 'Gray' })

        # 详细记录，便于事后核对正确率
        try {
            $detail = 'Q=' + $qd.stem
            foreach ($dk in @('A','B','C','D')) {
                if ($qd.opts.ContainsKey($dk)) { $detail += ' || ' + $dk + ':' + $qd.opts[$dk].text }
            }
            $detail += ' || ANS=' + $ans + ' AT=' + $qd.opts[$ans].cx + ',' + $qd.opts[$ans].cy + ' WHY=' + $why
            if (-not $script:AnsLog) {
                $script:AnsLog = Join-Path $LogDir ('answers_' + (Get-Date -Format 'yyyyMMdd_HHmmss') + '.txt')
            }
            Add-Content -Path $script:AnsLog -Value $detail -Encoding UTF8
        } catch { }
        # 点选答案。注意两种模块行为不同：
        #   测试模块：点完自动翻到下一题，不出对错标记
        #   单词模块：点完变色（绿勾/红叉），要上滑才翻
        TapPoint ([int]($script:W * 0.4)) ([int]$qd.opts[$ans].cy) 200
        # 关键：对错标记只在点完后约 0.5-2.0 秒内出现，之后立即翻页。
        # 所以必须在这个窗口内抓图，晚一点就什么都看不到。
        Start-Sleep -Milliseconds 700
        $shot2 = Shot
        # 先确认这张图还是同一道题（题干区没变），否则绿色可能是结算页按钮
        $sameScreen = $false
        if ($shot2) {
            $preSig = [Probe2]::RegionSig($scr.path, [int]($script:H * 0.30), [int]($script:H * 0.46))
            $postSig = [Probe2]::RegionSig($shot2, [int]($script:H * 0.30), [int]($script:H * 0.46))
            $sameScreen = ($preSig -eq $postSig)
        }
        if ($shot2 -and -not $sameScreen) { $shot2 = $null }
        if ($shot2) {
            try {
                $qPic = Join-Path $LogDir ('q_' + (Get-Date -Format 'HHmmss') + '_' + $ans + '.png')
                Copy-Item -LiteralPath $shot2 -Destination $qPic -Force
            } catch { }
        }
        Start-Sleep -Milliseconds 2200
        $sc2 = Read-Screen
        $qd2 = $null
        if ($sc2) { $qd2 = Get-QuizData $sc2 }

        # 情况A：题干变了 -> 自动翻页（测试模块），成功
        if ($qd2 -and $qd2.stem -ne $qd.stem) {
            $done++
            $lastStem = $qd.stem
            continue
        }
        # 情况B：离开题目页 -> 也是成功
        if ($sc2 -and $sc2.text -match 'COMPLETE|恭喜你完成|本次学习') {
            $done++
            $lastStem = $qd.stem
            continue
        }
        # 情况C：还在同一题 -> 查对错标记（单词模块）
        $wrongK = $null; $rightK = $null
        if ($shot2) {
            foreach ($mk in @('A','B','C','D')) {
                if (-not $qd.opts.ContainsKey($mk)) { continue }
                $my = [int]$qd.opts[$mk].cy
                $col = [Probe2]::OptColor($shot2, $my - 55, $my + 55)
                if ($col -eq 'RED') { $wrongK = $mk }
                if ($col -eq 'GREEN') { $rightK = $mk }
            }
        }
        # 关键判定：绿勾在哪，哪就是正确答案。绿勾不在我点的位置 -> 一定答错了
        # 若同一屏同时检出绿和红，以绿勾位置为准（绿为实心块，比红叉稳定）
        if ($rightK) {
            if ($rightK -ne $ans) { $wrongK = $ans } else { $wrongK = $null }
        } elseif ($wrongK -and -not $rightK) {
            # 只检出红叉没有绿勾：可能截图偏早，标记不可信 -> 当作未判定，不误杀
            $wrongK = $null
        }
        if ($wrongK) {
            Write-Host ''
            Say '========================================' 'Red'
            Say '  这题答错了，已停止做题' 'Red'
            Say '========================================' 'Red'
            Say ('  题干：' + $qd.stem) 'Yellow'
            foreach ($dk in @('A','B','C','D')) {
                if ($qd.opts.ContainsKey($dk)) {
                    $mark = ''
                    if ($dk -eq $wrongK) { $mark = '   <== 选错了' }
                    if ($dk -eq $rightK) { $mark = '   <== 正确答案' }
                    Say ('    ' + $dk + '. ' + $qd.opts[$dk].text + $mark) 'Yellow'
                }
            }
            Write-Host ''
            return $done
        }
        if ($rightK) {
            # 单词模块：已判定正确，必须上滑才进下一题
            Advance
            Start-Sleep -Milliseconds 1400
            $done++
            $lastStem = $qd.stem
            continue
        }
        # 既没翻页也没有标记 -> 补点一次（页面可能瞬时卡顿），仍不行才停
        Start-Sleep -Milliseconds 1200
        $sc5 = Read-Screen
        $qd5 = $null
        if ($sc5) { $qd5 = Get-QuizData $sc5 }
        if ($qd5 -and $qd5.stem -ne $qd.stem) {
            $done++
            $lastStem = $qd.stem
            continue
        }
        # 补点：换高度再试一次
        $cy2 = [int]$qd.opts[$ans].cy
        foreach ($dy in @(35, -35)) {
            TapPoint ([int]($script:W * 0.4)) ($cy2 + $dy) 200
            Start-Sleep -Milliseconds 3400
            $sc6 = Read-Screen
            if (-not $sc6) { continue }
            $qd6 = Get-QuizData $sc6
            if ($qd6 -and $qd6.stem -ne $qd.stem) {
                $done++
                $lastStem = $qd.stem
                break
            }
            if ($sc6.text -match 'COMPLETE|恭喜你完成') {
                $done++
                $lastStem = $qd.stem
                break
            }
        }
        if ($done -gt 0 -and $lastStem -eq $qd.stem) { continue }
        Write-Host ''
        Say '========================================' 'Red'
        Say '  点了之后既没翻页也没出对错标记，已停止' 'Red'
        Say '========================================' 'Red'
        Say ('  题干：' + $qd.stem + '   想选：' + $ans + '（' + $qd.opts[$ans].text + '）') 'Yellow'
        Say ('  点击坐标：x=' + [int]($script:W * 0.4) + ' y=' + $qd.opts[$ans].cy) 'Yellow'
        Write-Host ''
        return $done
    }
    return $done
}
function Do-Tests {
    if (-not (Do-Home)) { Say '回不到首页，跳过测试' 'Yellow'; return }
    $scr = Read-Screen
    if (-not $scr) { return }
    # 注意：首页卡片上的"已完成 N/N"不可靠（可能只是其中一个测试），
    # 所以不据此跳过，一律点进去看「今日进度 N/50」再决定
    $btn = Find-Line $scr '^测试'
    if (-not $btn) { Say '首页找不到「测试」入口' 'Yellow'; Say ('  页面文本: ' + $scr.text.Substring(0, [Math]::Min(120, $scr.text.Length))) 'DarkGray'; return }
    Say ('点测试入口 @' + $btn.cx + ',' + ($btn.cy + [int]($script:H * 0.04)))
    TapPoint $btn.cx ($btn.cy + [int]($script:H * 0.04)) 2600
    # 验证是否进入测试页
    $inTest = $false
    for ($t = 0; $t -lt 4; $t++) {
        $s2 = Read-Screen
        if ($s2 -and (Get-State2 $s2) -ne 'HOME') { $inTest = $true; break }
        Start-Sleep -Milliseconds 900
    }
    if (-not $inTest) { Say '点了测试入口但页面没变' 'Yellow'; return }
    # 进测试页后通常有"测试的正确率…"公告弹窗，先点掉再找开始按钮
    for ($pz = 0; $pz -lt 3; $pz++) {
        $sp0 = Read-Screen
        if (-not $sp0) { break }
        $pb = @($sp0.lines | Where-Object { $_.text -match '^确认$|^我知道了$|^确定$' -and $_.y -gt ($script:H * 0.3) })
        if ($pb.Count -gt 0) {
            Say ('先关公告弹窗 @' + $pb[0].cx + ',' + $pb[0].cy) 'DarkGray'
            TapPoint $pb[0].cx $pb[0].cy 1600
            continue
        }
        break
    }
    $entered = $false
    for ($w = 0; $w -lt 5; $w++) {
        $s0 = Read-Screen
        if ($s0) {
            $stT = Get-State2 $s0
            if ($stT -ne 'HOME' -and $stT -ne 'NONE') { $entered = $true; break }
        }
        Start-Sleep -Milliseconds 900
    }
    if (-not $entered) { Say '点了「测试」但没进去，退出测试模块' 'Yellow'; return }

    for ($round = 0; $round -lt 6; $round++) {
        $scr = Read-Screen
        if (-not $scr) { return }
        $st = Get-State2 $scr
        Say ('  [测试轮' + $round + '] 状态=' + $st) 'DarkGray'
        if ($st -eq 'HOME') {
            $btnH = Find-Line $scr '^测试'
            if ($btnH) {
                Say '回到首页，重新进入测试'
                TapPoint $btnH.cx ($btnH.cy + [int]($script:H * 0.04)) 2600
                continue
            }
        }
        if ($st -eq 'QUIZ') { [void](Run-Quiz 220); continue }
        if (Handle-Popup $scr) { continue }
        if ($st -eq 'READY' -or $st -eq 'DIALOG' -or $st -eq 'STRENGTH') { continue }

        $startBtn = Find-Line $scr '^(开始|继续|接着做)$'
        if ($startBtn) {
            Say ('点「' + $startBtn.text + '」 @' + $startBtn.cx + ',' + $startBtn.cy)
            TapPoint $startBtn.cx $startBtn.cy 2600
            # 确认真的进了答题页，再开始做题（否则第一轮会读到中间态，白跑一趟）
            $inQuiz = $false
            for ($cq = 0; $cq -lt 6; $cq++) {
                $sq = Read-Screen
                if ($sq) {
                    $stq = Get-State2 $sq
                    if ($stq -eq 'QUIZ') { $inQuiz = $true; break }
                    if ($stq -eq 'DIALOG' -or $stq -eq 'READY') { [void](Handle-Popup $sq); continue }
                }
                Start-Sleep -Milliseconds 900
            }
            if (-not $inQuiz) { Say '  点了「开始」但没进入答题页' 'Yellow'; Start-Sleep -Milliseconds 1200; continue }
            $n = Run-Quiz 220
            Say ('本轮答题 ' + $n + ' 道')
            [void](Do-Home)
            continue
        }
        if ($scr.text -match '随堂测试|系统测试') {
            Say '  检测到测试页文字' 'DarkGray'
            $rows2 = @($scr.lines | Where-Object { $_.text -match '(\d+)\s*/\s*(\d+)' })
            $pending = $false
            foreach ($r2 in $rows2) {
                if ($r2.text -match '(\d+)\s*/\s*(\d+)') {
                    $cur2 = [int]$Matches[1]; $tot2 = [int]$Matches[2]
                    if ($tot2 -gt 0 -and $cur2 -lt $tot2) { $pending = $true; break }
                }
            }
            if ($pending) { Say '有未完成的测试但找不到「开始」按钮，再试一次' 'Yellow'; Start-Sleep -Milliseconds 800; continue }
            if ($rows2.Count -gt 0) { Say '测试: 全部进度已满，完成' 'Green'; return }
            Say '测试页没有可点的「开始」，退出测试模块' 'Yellow'
            return
        }
        return
    }
}

# ==================== 模块：单词 ====================
function Do-Words {
    $scr = Read-Screen
    if (-not $scr) { return }
        # 不依据首页卡片判断，一律进列表逐个卡包看
    $stNow = Get-State2 $scr
    # 已经在单词相关页面就直接做，不强行回首页（回去要按返回键，容易误退出小程序）
    $alreadyIn = ($stNow -eq 'LEARN' -or $stNow -eq 'QUIZ' -or $scr.text -match '卡包|词书')
    if (-not $alreadyIn) {
        if (-not (Do-Home)) { Say '回不到首页，跳过单词' 'Yellow'; return }
        $scr = Read-Screen
        if (-not $scr) { return }
        $btn = Find-Line $scr '单词'
        if (-not $btn) { Say '首页找不到「单词」入口' 'Yellow'; return }
        Say ('点单词入口 @' + $btn.cx + ',' + ($btn.cy + [int]($script:H * 0.04)))
        TapPoint $btn.cx ($btn.cy + [int]($script:H * 0.04)) 2600
        $inWords = $false
        for ($t = 0; $t -lt 4; $t++) {
            $s2 = Read-Screen
            if ($s2 -and (Get-State2 $s2) -ne 'HOME') { $inWords = $true; break }
            Start-Sleep -Milliseconds 900
        }
        if (-not $inWords) { Say '点了单词入口但页面没变' 'Yellow'; return }
    } else {
        Say ('已在单词页面(' + $stNow + ')，直接开始') 'Green'
    }

    # 在卡包列表里循环：找一个未完成的卡包做掉，再回来找下一个
    $packDone = 0
    for ($round = 0; $round -lt 8; $round++) {
        $scr = Read-Screen
        if (-not $scr) { break }
        $st = Get-State2 $scr

        if ($st -eq 'DIALOG' -or $st -eq 'STRENGTH' -or $st -eq 'READY') {
            $b2 = Find-Button $scr 'confirm'
            if ($b2) { Say ('弹窗 -> 点「' + $b2.text + '」') 'DarkGray'; TapPoint $b2.cx $b2.cy 1300; continue }
        }

        if ($st -eq 'LEARN' -or $st -eq 'QUIZ') {
            $n = Run-Quiz 60
            if ($n -gt 0) { Say ('本屏答题 ' + $n + ' 道') 'Green' }
            else { Say '本屏没答到题，退出单词模块' 'Yellow'; break }
            continue
        }

        # 卡包列表：先找「开始 / 继续」按钮；没有就点卡包卡片本身
        $go = Find-Line $scr '^(开始|继续|接着做)$'
        if ($go) {
            Say ('进入卡包 @' + $go.cx + ',' + $go.cy) 'Cyan'
            TapPoint $go.cx $go.cy 2600
            continue
        }

        if ($scr.text -match '卡包' -or $st -eq 'PACKLIST') {
            $packs = @($scr.lines | Where-Object { $_.text -match '^卡包\s*\d+$' } | Sort-Object x)
            if ($packs.Count -eq 0) { Say '列表里找不到卡包' 'Yellow'; break }
            $entered = $false
            foreach ($pk in $packs) {
                # 已完成的卡包右上角有斜标，卡片整体也偏灰；先试当前这个
                Say ('尝试进入 ' + $pk.text) 'Cyan'
                TapPoint $pk.cx ([int]($pk.cy) + 110) 2600
                $s3 = Read-Screen
                if ($s3) {
                    $st3 = Get-State2 $s3
                    if ($st3 -eq 'LEARN' -or $st3 -eq 'QUIZ' -or $s3.text -match '学习\s*\d+\s*/\s*\d+') {
                        Say ('  进入成功(' + $st3 + ')') 'Green'
                        $entered = $true
                        break
                    }
                }
                # 没进去（可能已完成），回列表继续试下一个
                Say ('  ' + $pk.text + ' 进不去（可能已完成），换下一个') 'DarkGray'
                TapPoint ([int]($script:W * 0.06)) 160 1500
                Start-Sleep -Milliseconds 900
            }
            if ($entered) { continue }
            Say '所有卡包都进不去，结束单词模块' 'Green'
            break
        }
        Say ('单词模块：当前状态 ' + $st + '，退出') 'Yellow'
        break
    }
    Say ('单词模块结束，本次处理 ' + $packDone + ' 轮') 'DarkGray'
}
function Main {
    $script:LiveLog = Join-Path $LogDir 'live.log'
    try { [System.IO.File]::WriteAllText($script:LiveLog, '', (New-Object System.Text.UTF8Encoding($false))) } catch { $script:LiveLog = $null }
    Say '============================================'
    $buildTime = (Get-Item $PSCommandPath -ErrorAction SilentlyContinue).LastWriteTime
    $verTag = 'v2.4'
    if ($buildTime) { $verTag += '  构建 ' + $buildTime.ToString('MM-dd HH:mm') }
    Say (' 翻转外语 今日任务 ' + $verTag) 'Cyan'
    Say '============================================'
    if (-not (Test-Path $Adb)) { Say ('缺少 adb: ' + $Adb) 'Red'; return 2 }
    Load-State
    if ($Mode -eq 'selftest') {
        if (Start-OcrServer) { $script:UseRapid = $true }
        Say ('  诊断 Root=' + $Root)
        Say ('  诊断 UseRapid=' + $script:UseRapid + '  OcrProc=' + $(if ($script:OcrProc) { 'set' } else { 'null' }))
        Say ('  诊断 helper=' + (Test-Path (Join-Path $Root 'ocr_helper.py')))
        Say ('  诊断 Image=' + (Test-Path $Image) + ' ' + $Image)
        $ls = @()
        if ($script:UseRapid) {
            $ls = @(Ocr-Rapid $Image)
            Say ('  诊断 Rapid 返回 ' + $ls.Count + ' 行')
        }
        if ($ls.Count -lt 3) {
            $ls = @(Ocr-Raw $Image)
            Say ('  诊断 Windows 返回 ' + $ls.Count + ' 行')
        }
        $scr = [pscustomobject]@{ path = $Image; lines = $ls; text = (($ls | ForEach-Object { $_.text }) -join ' ') }
        Say ('状态: ' + (Get-State2 $scr))
        $qd = Get-QuizData $scr
        if (-not $qd) {
            Say ("诊断: 行数=" + $aa.Count) "Yellow"
            for ($j = 1; $j -lt $aa.Count; $j++) {
                $g = $aa[$j].y - $aa[$j-1].y
                if ($g -gt $mg -and $aa[$j].y -gt ($script:H * 0.30)) { $mg = $g; $spY = $aa[$j].y }
            }
            $oz = @($aa | Where-Object { $_.y -ge ($spY - 15) })
            $cl0 = @(Group-Lines $oz)
            foreach ($c0 in $cl0) { Say ("    簇 y=" + (($c0 | Measure-Object y -Minimum).Minimum) + " : " + (($c0 | ForEach-Object { $_.text }) -join " / ")) "DarkGray" }
        }
        if ($qd) {
            Say ('题干: ' + $qd.stem) 'Cyan'
            foreach ($k in @('A', 'B', 'C', 'D')) { if ($qd.opts.ContainsKey($k)) { Say ('  ' + $k + '. ' + $qd.opts[$k].text) } }
            try { $r = Decide $qd.stem $qd.opts } catch {
                Say ('判定异常: ' + $_.Exception.Message) 'Red'
                Say ([string]$_.ScriptStackTrace) 'DarkRed'
                return 0
            }
            Say ('判定: ' + [string]$r[0] + '  依据: ' + [string]$r[1]) 'Green'
        }
        return 0
    }
    if (Start-OcrServer) {
        $script:UseRapid = $true
        Say 'OCR: RapidOCR（高精度）已就绪' 'Green'
    } else {
        $script:UseRapid = $false
        Say 'OCR: 使用 Windows 内置（大字号英文可能识别不出）' 'Yellow'
    }
    if ($script:Cfg.api_key) { Say ('AI 判题已启用: ' + $script:Cfg.model) 'Green' } else { Say '未配置 AI key，使用本地词典判题（正确率略低）' 'Yellow' }



    $dev = Get-Device
    if (-not $dev) {
        Say '等待手机接入（最多 30 秒）...' 'Yellow'
        for ($i = 0; $i -lt 30; $i++) { Start-Sleep -Milliseconds 1000; $dev = Get-Device; if ($dev) { break } }
    }
    if (-not $dev) { Say '手机没有连上' 'Red'; return 2 }
    Say ('设备: ' + $dev) 'Green'

    $sizeTxt = Invoke-Adb @('shell', 'wm', 'size')
    $m = [regex]::Match($sizeTxt, '(\d+)\s*x\s*(\d+)')
    if ($m.Success) { $script:W = [int]$m.Groups[1].Value; $script:H = [int]$m.Groups[2].Value }
    Say ("屏幕: $($script:W)x$($script:H)")

    if ($Mode -eq 'check') {
        $scr = Read-Screen
        if ($scr) { Say ('状态: ' + (Get-State2 $scr)); Say ('文本: ' + $scr.text.Substring(0, [Math]::Min(160, $scr.text.Length))) }
        return 0
    }

    [void](Invoke-Adb @('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'))
    Start-Sleep -Milliseconds 300

    if ($Mode -eq 'once') { [void](Run-Quiz 60); return 0 }

    $t0 = Get-Date
    $scr0 = Read-Screen
    $st0 = 'NONE'
    if ($scr0) { $st0 = Get-State2 $scr0 }
    if ($st0 -eq 'QUIZ' -or $st0 -eq 'LEARN') {
        Say ('当前已在答题页(' + $st0 + ')，直接作答') 'Green'
        $ans0 = Run-Quiz 260
        Say ('本屏答题 ' + $ans0 + ' 道')
        $st1 = Get-State2 (Read-Screen)
        if ($st1 -eq 'QUIZ' -or $st1 -eq 'LEARN') { return 0 }   # 还在答题，不强行回首页
        # 卡包列表/词书页也不按返回（会弹"退出小程序"）
        $scr1 = Read-Screen
        if ($scr1 -and $scr1.text -match '卡包|词书') { Say '仍在卡包列表，直接继续' 'Green' }
    }
    [void](Do-Home)
    Say '--- 1/2 测试 ---'
    Do-Tests
    [void](Do-Home)
    Say '--- 2/2 单词 ---'
    Do-Words
    [void](Do-Home)
    $cost = ((Get-Date) - $t0).TotalSeconds
    Say ('=== 完成，用时 ' + [Math]::Round($cost) + ' 秒 ===') 'Green'
    $logName = Join-Path $LogDir ((Get-Date -Format 'yyyyMMdd_HHmmss') + '.log')
    [System.IO.File]::WriteAllLines($logName, $script:LogBuf, (New-Object System.Text.UTF8Encoding($false)))
    return 0
}

try { exit (Main) }
catch {
    Say ('运行出错: ' + $_.Exception.Message) 'Red'
    $logName = Join-Path $LogDir ((Get-Date -Format 'yyyyMMdd_HHmmss') + '_err.log')
    [System.IO.File]::WriteAllLines($logName, $script:LogBuf, (New-Object System.Text.UTF8Encoding($false)))
    exit 1
}
