#Requires -Version 5.1
# ============================================
# ZCode-Deploy 发布打包脚本
#
# 用法: powershell -ExecutionPolicy Bypass -File build-release.ps1
#       powershell -ExecutionPolicy Bypass -File build-release.ps1 -Version 2.0.1
#
# 产物: dist\ZCode-Deploy-v<版本>.zip
#       dist\ZCode-Deploy-v<版本>.zip.sha256
#
# 打包内容是**白名单**：只有下面 $Payload 里列出的文件会进包，
# 机器本地产物（backups\、zcode-dir.txt 等）永远不会被打进去。
#
# 本脚本自身必须保存为 UTF-8 with BOM（见下方预检）。
# ============================================
param(
    [string]$Version = ""
)

$ErrorActionPreference = "Stop"

$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$DistDir   = Join-Path $ScriptDir "dist"
$StageRoot = Join-Path $DistDir "_stage"

# ---- 版本号：默认从 deploy.ps1 的 $ToolVersion 读取 ----
if (-not $Version) {
    $deployText = [System.IO.File]::ReadAllText((Join-Path $ScriptDir "deploy.ps1"))
    $m = [regex]::Match($deployText, '\$ToolVersion\s*=\s*"([0-9][^"]*)"')
    if (-not $m.Success) {
        Write-Host "[失败] 无法从 deploy.ps1 读取版本号，请用 -Version 指定" -ForegroundColor Red
        exit 1
    }
    $Version = $m.Groups[1].Value
}

$ReleaseName = "ZCode-Deploy-v$Version"
$Stage       = Join-Path $StageRoot $ReleaseName
$ZipPath     = Join-Path $DistDir ($ReleaseName + ".zip")
$ShaPath     = $ZipPath + ".sha256"

Write-Host "=== ZCode-Deploy 发布打包 ===" -ForegroundColor Cyan
Write-Host "版本:   $Version"
Write-Host "产物:   $ZipPath"
Write-Host ""

# ---- 发布白名单 ----
$Payload = @(
    "deploy.ps1",
    "verify-patch.cjs",
    "build-release.ps1",
    "部署.bat",
    "恢复.bat",
    "查看状态.bat",
    "验证.bat",
    "人格.txt",
    "README.md",
    "修改记录.md",
    "CHANGELOG.md",
    "LICENSE",
    ".gitignore"
)

Write-Host "[1/5] 校验白名单文件..." -ForegroundColor Cyan
$missing = @()
foreach ($f in $Payload) {
    $src = Join-Path $ScriptDir $f
    if (Test-Path -LiteralPath $src -PathType Leaf) {
        Write-Host ("  [OK] {0} ({1} bytes)" -f $f, (Get-Item -LiteralPath $src).Length) -ForegroundColor Green
    } else {
        Write-Host "  [缺失] $f" -ForegroundColor Red
        $missing += $f
    }
}
if ($missing.Count -gt 0) {
    Write-Host ""
    Write-Host "[失败] 缺少 $($missing.Count) 个发布文件，已中止" -ForegroundColor Red
    exit 1
}

# ---- 预检：.ps1 必须带 UTF-8 BOM ----
# PowerShell 5.1 对无 BOM 的脚本按系统 ANSI（GBK）解码，
# 会吃掉中文字节并报大量假语法错。发出去之前必须拦住。
Write-Host "  预检 .ps1 编码..." -ForegroundColor Gray
$noBom = @()
foreach ($f in $Payload) {
    if ($f -like "*.ps1") {
        $bytes = [System.IO.File]::ReadAllBytes((Join-Path $ScriptDir $f))
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        if ($hasBom) {
            Write-Host "  [OK] $f  UTF-8 with BOM" -ForegroundColor Green
        } else {
            Write-Host "  [失败] $f  缺少 UTF-8 BOM（PS 5.1 会按 GBK 解码中文并报语法错）" -ForegroundColor Red
            $noBom += $f
        }
    }
}
if ($noBom.Count -gt 0) {
    Write-Host ""
    Write-Host "[失败] 有 $($noBom.Count) 个脚本编码不合格，已中止" -ForegroundColor Red
    exit 1
}

Write-Host "[2/5] 准备暂存目录..." -ForegroundColor Cyan
if (Test-Path -LiteralPath $StageRoot) { Remove-Item -LiteralPath $StageRoot -Recurse -Force }
New-Item -ItemType Directory -Path $Stage -Force | Out-Null

Write-Host "[3/5] 复制文件并生成清单..." -ForegroundColor Cyan
foreach ($f in $Payload) {
    Copy-Item -LiteralPath (Join-Path $ScriptDir $f) -Destination (Join-Path $Stage $f) -Force
}

$manifest = New-Object System.Collections.ArrayList
[void]$manifest.Add("# $ReleaseName")
[void]$manifest.Add("生成时间: " + (Get-Date -Format "yyyy-MM-dd HH:mm:ss"))
[void]$manifest.Add("文件数:   " + $Payload.Count)
[void]$manifest.Add("")
[void]$manifest.Add("SHA256                                                            SIZE  NAME")
[void]$manifest.Add(("-" * 78))
$total = 0
foreach ($f in $Payload) {
    $item = Get-Item -LiteralPath (Join-Path $Stage $f)
    $hash = (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash
    $total += $item.Length
    [void]$manifest.Add(("{0}  {1,8}  {2}" -f $hash, $item.Length, $f))
}
[void]$manifest.Add(("-" * 78))
[void]$manifest.Add(("总计: {0} bytes" -f $total))
[System.IO.File]::WriteAllLines((Join-Path $Stage "MANIFEST.txt"), $manifest, (New-Object System.Text.UTF8Encoding($true)))
Write-Host "  已写入 MANIFEST.txt" -ForegroundColor Green

Write-Host "[4/5] 打包 zip..." -ForegroundColor Cyan
if (-not (Test-Path -LiteralPath $DistDir)) { New-Item -ItemType Directory -Path $DistDir -Force | Out-Null }
if (Test-Path -LiteralPath $ZipPath) { Remove-Item -LiteralPath $ZipPath -Force }
Compress-Archive -Path (Join-Path $Stage "*") -DestinationPath $ZipPath -CompressionLevel Optimal
Write-Host ("  [OK] {0} ({1} bytes)" -f (Split-Path -Leaf $ZipPath), (Get-Item -LiteralPath $ZipPath).Length) -ForegroundColor Green

Write-Host "[5/5] 计算校验和..." -ForegroundColor Cyan
$zipHash = (Get-FileHash -LiteralPath $ZipPath -Algorithm SHA256).Hash
[System.IO.File]::WriteAllText($ShaPath, ($zipHash + "  " + $ReleaseName + ".zip" + [char]10), (New-Object System.Text.UTF8Encoding($false)))
Write-Host "  [OK] $zipHash" -ForegroundColor Green

Remove-Item -LiteralPath $StageRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "=== 打包完成 ===" -ForegroundColor Green
Write-Host "  $ZipPath"
Write-Host "  $ShaPath"
