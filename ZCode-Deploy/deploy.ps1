#Requires -Version 5.1
# ============================================
# ZCode 一键人格部署工具  v2.0
# 适配 ZCode 2026-09-19 之后重新打包的 zcode.cjs
#
# v2 相比 v1 的变化：
#   1. 锚点不再依赖压缩后的变量名（Djo/Eut/fre/...），改为按语义字面量定位，
#      ZCode 每次更新重命名变量也不会失效
#   2. 6 个补丁全部失败即中止，不再"静默无效果"
#   3. 写入前用 node --check 做语法校验，校验不通过绝不落盘
#   4. 备份策略修复：ZCode 更新后自动把 .bak 刷新为新版原版，
#      避免 restore 把应用降级回旧版本
#   5. 路径检测支持 D:\app\zcode 等真实安装位置，并缓存检测结果
#
# 使用: powershell -ExecutionPolicy Bypass -File deploy.ps1 install
# ============================================
param(
    [Parameter(Position=0)]
    [ValidateSet("install","restore","status","diag","help")]
    [string]$Action = "status",
    [switch]$AllowPartial,
    [switch]$NoRestart
)

$ErrorActionPreference = "Stop"

$ToolVersion  = "2.0.0"

$ScriptDir   = Split-Path -Parent $MyInvocation.MyCommand.Path
$PromptFile  = Join-Path $ScriptDir "人格.txt"
$BackupDir   = Join-Path $ScriptDir "backups"
$DirCache    = Join-Path $ScriptDir "zcode-dir.txt"

$Marker       = "ZP:PERSONA"
$IdentityLit  = '"You are ZCode, an interactive coding agent"'
$LitIdentity  = 'name:"Agent Identity",source:"identity"'
$LitDate      = 'name:"Current Date",source:"current_date"'
$LitSkills    = 'name:"Skills",source:"skills"'
$LitUserCtx   = 'name:"Request User Context",source:"request_user_context"'

function Info($m)  { Write-Host $m -ForegroundColor Cyan }
function Good($m)  { Write-Host "  [OK] $m" -ForegroundColor Green }
function Skipd($m) { Write-Host "  [跳过] $m" -ForegroundColor Gray }
function Warn2($m) { Write-Host "  [警告] $m" -ForegroundColor Yellow }
function Bad($m)   { Write-Host "  [失败] $m" -ForegroundColor Red }
function Note($m)  { Write-Host "  $m" -ForegroundColor DarkGray }

# ---------- ZCode 安装目录检测 ----------
function Test-ZCodeDir([string]$dir) {
    if ([string]::IsNullOrWhiteSpace($dir)) { return $false }
    return (Test-Path -LiteralPath (Join-Path $dir "resources\glm\zcode.cjs") -PathType Leaf)
}

function Get-ZCodeDir {
    if ($env:ZCODE_DIR -and (Test-ZCodeDir $env:ZCODE_DIR)) { return $env:ZCODE_DIR }

    foreach ($p in (Get-Process -Name "ZCode" -ErrorAction SilentlyContinue)) {
        try {
            if ($p.Path) {
                $d = Split-Path -Parent $p.Path
                if (Test-ZCodeDir $d) { return $d }
            }
        } catch { }
    }

    if (Test-Path -LiteralPath $DirCache) {
        $d = (Get-Content -LiteralPath $DirCache -Raw -ErrorAction SilentlyContinue)
        if ($d) { $d = $d.Trim() }
        if (Test-ZCodeDir $d) { return $d }
    }

    $cands = @(
        "D:\app\zcode", "C:\app\zcode", "E:\app\zcode", "F:\app\zcode",
        "D:\zcode", "C:\zcode", "E:\zcode", "F:\zcode",
        "$env:LOCALAPPDATA\Programs\zcode",
        "$env:LOCALAPPDATA\Programs\ZCode",
        "$env:LOCALAPPDATA\ZCode",
        "C:\Program Files\zcode", "C:\Program Files\ZCode",
        "C:\Program Files (x86)\zcode"
    )
    foreach ($c in $cands) { if (Test-ZCodeDir $c) { return $c } }

    foreach ($drv in (Get-PSDrive -PSProvider FileSystem)) {
        foreach ($sub in @("", "app\", "Program Files\", "Programs\")) {
            $p = Join-Path $drv.Root ($sub + "zcode")
            if (Test-ZCodeDir $p) { return $p }
        }
    }

    Note "(常规位置未命中，正在扫描磁盘，可能需要几十秒...)"
    foreach ($drv in (Get-PSDrive -PSProvider FileSystem)) {
        $hit = Get-ChildItem -LiteralPath $drv.Root -Directory -Depth 3 -Force -ErrorAction SilentlyContinue |
               Where-Object { $_.Name -eq "zcode" } |
               ForEach-Object { $_.FullName } |
               Where-Object { Test-ZCodeDir $_ } |
               Select-Object -First 1
        if ($hit) { return $hit }
    }
    return $null
}

function Get-NodeExe {
    $cmd = Get-Command node -ErrorAction SilentlyContinue
    if ($cmd -and $cmd.Source) { return $cmd.Source }
    foreach ($p in @("D:\app\nodejs\node.exe", "C:\Program Files\nodejs\node.exe",
                     "$env:LOCALAPPDATA\Programs\nodejs\node.exe",
                     "$env:ProgramFiles\nodejs\node.exe")) {
        if ($p -and (Test-Path -LiteralPath $p)) { return $p }
    }
    return $null
}

# ---------- 通用定位工具 ----------


function Get-EnclosingFunction([string]$Content, [int]$AnchorIndex, [int]$Back = 20000) {
    if ($AnchorIndex -le 0) { return $null }
    $start = [Math]::Max(0, $AnchorIndex - $Back)
    $head  = $Content.Substring($start, $AnchorIndex - $start)
    $rx    = [regex]'function\s+([A-Za-z_$][\w$]*)\s*\(([A-Za-z_$][\w$]*(?:\s*,\s*[A-Za-z_$][\w$]*)*)?\)\s*\{'
    $best  = $null
    foreach ($m in $rx.Matches($head)) {
        $open  = $start + $m.Index + $m.Length - 1
        $depth = 0
        $close = -1
        $i     = $open
        while ($i -lt $Content.Length) {
            $ch = $Content[$i]
            if ($ch -eq '{') { $depth++ }
            elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $close = $i; break } }
            $i++
        }
        if ($close -gt $AnchorIndex) {
            $best = [pscustomobject]@{
                Name    = $m.Groups[1].Value
                Param   = $m.Groups[2].Value
                BraceAt = $open
                CloseAt = $close
            }
        }
    }
    return $best
}

function Test-NullApplied([string]$Content, [string]$Literal) {
    $idx = $Content.IndexOf($Literal, [System.StringComparison]::Ordinal)
    if ($idx -lt 0) { return $false }
    $fn = Get-EnclosingFunction -Content $Content -AnchorIndex $idx
    if (-not $fn) { return $false }
    if ($fn.BraceAt + 1 -ge $Content.Length) { return $false }
    $len = [Math]::Min(12, $Content.Length - $fn.BraceAt - 1)
    return $Content.Substring($fn.BraceAt + 1, $len).StartsWith('return null;')
}

function Get-PersonaExpr {
    $js = ($PromptFile -replace '\\', '/') -replace '"', '\"'
    return '(function(){/*' + $Marker + '*/try{return require("fs").readFileSync("' + $js + '","utf8")}catch(e){return null}})()'
}

# ---------- 六个补丁 ----------
# 补丁 1: 清空 CLI Prefix 里的 "You are ZCode ..." 身份声明
function Patch-CliPrefix([string]$c) {
    if (-not $c.Contains($IdentityLit)) {
        return [pscustomobject]@{ Status='skip'; Content=$c; Name='' }
    }
    $rx = [regex]('([A-Za-z_$][\w$]*)=' + [regex]::Escape($IdentityLit))
    if (-not $rx.IsMatch($c)) {
        return [pscustomobject]@{ Status='missing'; Content=$c; Name='' }
    }
    $m = $rx.Match($c)
    $name = $m.Groups[1].Value
    $new  = $c.Remove($m.Index, $m.Length).Insert($m.Index, $name + '=""')
    return [pscustomobject]@{ Status='ok'; Content=$new; Name=$name }
}

# 补丁 2: customSystemPrompt 改为读外部人格文件（热换人格的唯一入口）
function Patch-CustomPrompt([string]$c, [string]$expr) {
    $rx = [regex]'([A-Za-z_$][\w$]*)=this\.config\.customSystemPrompt\?\.trim\(\),([A-Za-z_$][\w$]*)=!!\1,'
    if (-not $rx.IsMatch($c)) {
        if ($c.Contains($Marker)) { return [pscustomobject]@{ Status='skip'; Content=$c; Name='' } }
        return [pscustomobject]@{ Status='missing'; Content=$c; Name='' }
    }
    $m = $rx.Match($c)
    $v = $m.Groups[1].Value
    $f = $m.Groups[2].Value
    $rep = $v + '=' + $expr + '?.trim(),' + $f + '=!!' + $v + ','
    $new = $c.Remove($m.Index, $m.Length).Insert($m.Index, $rep)
    return [pscustomobject]@{ Status='ok'; Content=$new; Name=$v }
}

# 补丁 3: Agent Identity 片段改读外部人格文件（保留原逻辑作为兜底）
function Patch-AgentIdentity([string]$c, [string]$expr) {
    $idx = $c.IndexOf($LitIdentity, [System.StringComparison]::Ordinal)
    if ($idx -lt 0) { return [pscustomobject]@{ Status='missing'; Content=$c; Name='' } }
    $fn = Get-EnclosingFunction -Content $c -AnchorIndex $idx
    if (-not $fn) { return [pscustomobject]@{ Status='missing'; Content=$c; Name='' } }
    $bodyStart = $fn.BraceAt + 1
    $seg = $c.Substring($bodyStart, $idx - $bodyStart)
    if ($seg.Contains($Marker)) {
        return [pscustomobject]@{ Status='skip'; Content=$c; Name=$fn.Name }
    }
    $rxLet = [regex]'let\s+([A-Za-z_$][\w$]*)\s*=\s*([^;]{1,120});'
    $last = $null
    foreach ($m in $rxLet.Matches($seg)) { $last = $m }
    if (-not $last) { return [pscustomobject]@{ Status='missing'; Content=$c; Name=$fn.Name } }
    $var = $last.Groups[1].Value
    $orig = $last.Groups[2].Value
    if ($orig.Contains($Marker)) {
        return [pscustomobject]@{ Status='skip'; Content=$c; Name=$fn.Name }
    }
    $absStart = $bodyStart + $last.Index
    $rep = 'let ' + $var + ';try{' + $var + '=' + $expr + '}catch(_ze){' + $var + '=' + $orig + '}'
    $new = $c.Remove($absStart, $last.Length).Insert($absStart, $rep)
    return [pscustomobject]@{ Status='ok'; Content=$new; Name=$fn.Name }
}

# 补丁 4/5/6: 直接让产物函数返回 null（日期提醒 / Skills 列表 / User Context）
function Patch-NullSection([string]$c, [string]$literal) {
    $idx = $c.IndexOf($literal, [System.StringComparison]::Ordinal)
    if ($idx -lt 0) { return [pscustomobject]@{ Status='missing'; Content=$c; Name='' } }
    $fn = Get-EnclosingFunction -Content $c -AnchorIndex $idx
    if (-not $fn) { return [pscustomobject]@{ Status='missing'; Content=$c; Name='' } }
    if ($fn.BraceAt + 1 -ge $c.Length) { return [pscustomobject]@{ Status='missing'; Content=$c; Name=$fn.Name } }
    $len = [Math]::Min(12, $c.Length - $fn.BraceAt - 1)
    if ($c.Substring($fn.BraceAt + 1, $len).StartsWith('return null;')) {
        return [pscustomobject]@{ Status='skip'; Content=$c; Name=$fn.Name }
    }
    $new = $c.Insert($fn.BraceAt + 1, 'return null;')
    return [pscustomobject]@{ Status='ok'; Content=$new; Name=$fn.Name }
}

# ---------- 备份 ----------
function Archive-Current([string]$file, [string]$kind) {
    if (-not (Test-Path -LiteralPath $BackupDir)) {
        New-Item -ItemType Directory -Path $BackupDir -Force | Out-Null
    }
    $stamp = Get-Date -Format "yyyyMMdd-HHmmss"
    $dest  = Join-Path $BackupDir ("zcode.cjs." + $kind + "-" + $stamp + ".bak")
    Copy-Item -LiteralPath $file -Destination $dest -Force
    Get-ChildItem -LiteralPath $BackupDir -Filter "*.bak" -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending | Select-Object -Skip 6 |
        Remove-Item -Force -ErrorAction SilentlyContinue
    return $dest
}

function Test-JsSyntax([string]$content, [string]$nodeExe, [ref]$errText) {
    if (-not $nodeExe) { $errText.Value = "(未找到 node，跳过语法校验)"; return $true }
    $tmp = Join-Path $env:TEMP ("zcode-syntax-" + [guid]::NewGuid().ToString("N") + ".cjs")
    try {
        [System.IO.File]::WriteAllText($tmp, $content, (New-Object System.Text.UTF8Encoding($false)))
        $old = $ErrorActionPreference
        $ErrorActionPreference = 'Continue'
        $out = & $nodeExe --check $tmp 2>&1 | Out-String
        $code = $LASTEXITCODE
        $ErrorActionPreference = $old
        if ($code -ne 0) { $errText.Value = $out.Trim(); return $false }
        return $true
    } finally {
        if (Test-Path -LiteralPath $tmp) { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue }
    }
}

function Stop-ZCode {
    Get-Process -Name "ZCode" -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 3
}

function Start-ZCodeProc([string]$exe) {
    if (-not (Test-Path -LiteralPath $exe)) { Warn2 "未找到 $exe，请手动启动 ZCode"; return }
    $cmdline = '"' + $exe + '"'
    Invoke-CimMethod -ClassName Win32_Process -MethodName Create -Arguments @{ CommandLine = $cmdline } | Out-Null
    Start-Sleep -Seconds 5
    $n = (Get-Process -Name "ZCode" -ErrorAction SilentlyContinue).Count
    Good "ZCode 已启动 ($n 个进程)"
}

# ---------- 报告 ----------
function Restart-ZCode([string]$exe) {
    if ($NoRestart) { Note "已跳过 ZCode 重启 (-NoRestart)"; return }
    Stop-ZCode
    Start-ZCodeProc $exe
}

function Get-PatchReport([string]$c) {
    $rows = New-Object System.Collections.ArrayList
    [void]$rows.Add([pscustomobject]@{ Name='CLI Prefix 身份声明'; Ok=(-not $c.Contains($IdentityLit)) })
    [void]$rows.Add([pscustomobject]@{ Name='customSystemPrompt 读人格文件'; Ok=$c.Contains($Marker) })
    [void]$rows.Add([pscustomobject]@{ Name='Agent Identity 读人格文件'; Ok=(Test-NullApplied $c $LitIdentity) -or ($c.Contains($Marker) -and (Test-NullApplied $c $LitDate)) })
    [void]$rows.Add([pscustomobject]@{ Name='日期提醒已移除'; Ok=(Test-NullApplied $c $LitDate) })
    [void]$rows.Add([pscustomobject]@{ Name='Skills 列表已移除'; Ok=(Test-NullApplied $c $LitSkills) })
    [void]$rows.Add([pscustomobject]@{ Name='User Context 已移除'; Ok=(Test-NullApplied $c $LitUserCtx) })
    return $rows
}

function Show-Sections([string]$c) {
    $rx = [regex]'name:"([^"]{1,48})",source:"([^"]{1,48})",injectionTarget:"([^"]{1,24})"'
    $i = 0
    foreach ($m in $rx.Matches($c)) {
        $i++
        $fn = Get-EnclosingFunction -Content $c -AnchorIndex $m.Index
        $fnName = if ($fn) { $fn.Name } else { '?' }
        Note ("{0,2}. {1,-30} source={2,-26} target={3,-12} fn={4}" -f $i, $m.Groups[1].Value, $m.Groups[2].Value, $m.Groups[3].Value, $fnName)
    }
    if ($i -eq 0) { Note "(未识别到任何注入片段)" }
}

function Get-BundleInfo([string]$zdir) {
    $meta = Join-Path $zdir "resources\glm\.node-bundle-meta.json"
    if (Test-Path -LiteralPath $meta) {
        try { return ((Get-Content -LiteralPath $meta -Raw) -replace '\s+', ' ').Trim() } catch { return '' }
    }
    return ''
}

# ============================================
# 主流程
# ============================================
$ZcodeDir = Get-ZCodeDir
if (-not $ZcodeDir) {
    Bad "未找到 ZCode 安装目录"
    Note "可用环境变量 ZCODE_DIR 手动指定，例如： set ZCODE_DIR=D:\app\zcode"
    exit 1
}

$ZcodeCjs    = Join-Path $ZcodeDir "resources\glm\zcode.cjs"
$ZcodeBackup = "$ZcodeCjs.bak"
$ZcodeExe    = Join-Path $ZcodeDir "ZCode.exe"
$PromptFileJS = $PromptFile -replace '\\', '/'
$nodeExe     = Get-NodeExe

try { Set-Content -LiteralPath $DirCache -Value $ZcodeDir -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }

Info "ZCode 目录:  $ZcodeDir"
Info "目标文件:    $ZcodeCjs"
Info "人格文件:    $PromptFile"
Write-Host ""

switch ($Action) {

    "help" {
        Info "ZCode-Deploy v$ToolVersion"
        Write-Host ""
        Note "用法: powershell -ExecutionPolicy Bypass -File deploy.ps1 <动作> [选项]"
        Write-Host ""
        Note "动作:"
        Note "  install         部署（备份原版 -> 打补丁 -> 语法校验 -> 重启 ZCode）"
        Note "  restore         还原原版（保留人格文件）"
        Note "  status          查看部署状态与补丁校验"
        Note "  diag            列出全部注入片段及其产物函数（排查用）"
        Note "  help            显示本帮助"
        Write-Host ""
        Note "选项:"
        Note "  -AllowPartial   有补丁未命中时也强行部署（默认中止，不写入）"
        Note "  -NoRestart      部署/还原后不重启 ZCode"
        Write-Host ""
        Note "人格文件: $PromptFile"
        Note "安装目录: 可用环境变量 ZCODE_DIR 手工指定"
    }
    "status" {
        Info "=== ZCode 部署状态 ==="
        Note ("工具版本:   v" + $ToolVersion)
        Write-Host ""
        $exists = Test-Path -LiteralPath $ZcodeCjs
        if (-not $exists) { Bad "目标文件不存在: $ZcodeCjs"; exit 1 }
        $fi = Get-Item -LiteralPath $ZcodeCjs
        $content = [System.IO.File]::ReadAllText($ZcodeCjs)
        $patched = $content.Contains($Marker)

        Note ("文件大小:   {0} bytes" -f $fi.Length)
        Note ("修改时间:   {0}" -f $fi.LastWriteTime)
        $bundle = Get-BundleInfo $ZcodeDir
        if ($bundle) { Note ("bundle:     $bundle") }
        $hasPrompt = Test-Path -LiteralPath $PromptFile
        Note ("人格文件:   " + $(if ($hasPrompt) { "{0} bytes" -f (Get-Item -LiteralPath $PromptFile).Length } else { "缺失" }))
        Note ("原版备份:   " + $(if (Test-Path -LiteralPath $ZcodeBackup) { "{0} bytes / {1}" -f (Get-Item -LiteralPath $ZcodeBackup).Length, (Get-Item -LiteralPath $ZcodeBackup).LastWriteTime } else { "无" }))
        Note ("语法校验:   " + $(if ($nodeExe) { $nodeExe } else { "未找到 node" }))
        Write-Host ""
        if ($patched) { Write-Host "模式: 自定义人格 (已部署)" -ForegroundColor Yellow }
        else          { Write-Host "模式: ZCode 原版 (未部署)" -ForegroundColor Green }
        Write-Host ""
        Info "--- 补丁校验 ---"
        foreach ($r in (Get-PatchReport $content)) {
            if ($r.Ok) { Good $r.Name } else { Warn2 $r.Name }
        }
        if (Test-Path -LiteralPath $ZcodeBackup) {
            $bakLen = (Get-Item -LiteralPath $ZcodeBackup).Length
            if (-not $patched -and $bakLen -ne $fi.Length) {
                Write-Host ""
                Warn2 "备份与当前版本大小不一致 —— 说明 ZCode 更新过。重跑 install 会自动刷新 .bak。"
            }
        }
    }

    "diag" {
        Info "=== 注入片段定位 (诊断) ==="
        Write-Host ""
        $content = [System.IO.File]::ReadAllText($ZcodeCjs)
        Note ("文件: {0}  ({1} bytes)" -f $ZcodeCjs, $content.Length)
        Note ("已部署: {0}" -f $content.Contains($Marker))
        Write-Host ""
        Show-Sections $content
    }

    "install" {
        Info "[1/6] 检查人格文件..."
        if (-not (Test-Path -LiteralPath $PromptFile)) {
            Bad "未找到 $PromptFile"
            exit 1
        }
        Good ("{0} ({1} bytes)" -f $PromptFile, (Get-Item -LiteralPath $PromptFile).Length)

        Info "[2/6] 读取并备份目标文件..."
        $content = [System.IO.File]::ReadAllText($ZcodeCjs)
        $alreadyPatched = $content.Contains($Marker)
        if ($alreadyPatched) {
            $arch = Archive-Current $ZcodeCjs "patched"
            Note "已归档当前已破解版本 -> $arch"
        } else {
            $arch = Archive-Current $ZcodeCjs "stock"
            Note "已归档当前原版 -> $arch"
        }
        if (-not $alreadyPatched) {
            if ((Test-Path -LiteralPath $ZcodeBackup) -and ((Get-Item -LiteralPath $ZcodeBackup).Length -eq (Get-Item -LiteralPath $ZcodeCjs).Length)) {
                Skipd "zcode.cjs.bak 已是最新原版"
            } else {
                Copy-Item -LiteralPath $ZcodeCjs -Destination $ZcodeBackup -Force
                Good "已刷新 zcode.cjs.bak (新版原版，restore 不再降级)"
            }
        } elseif (-not (Test-Path -LiteralPath $ZcodeBackup)) {
            Warn2 "缺少原版备份 .bak，restore 将不可用"
        }

        Info "[3/6] 应用补丁..."
        $expr = Get-PersonaExpr
        $results = New-Object System.Collections.ArrayList

        $r = Patch-CliPrefix $content;                     $content = $r.Content; [void]$results.Add([pscustomobject]@{ Id=1; Label='CLI Prefix 身份声明置空'; Status=$r.Status; Fn=$r.Name })
        $r = Patch-CustomPrompt $content $expr;            $content = $r.Content; [void]$results.Add([pscustomobject]@{ Id=2; Label='customSystemPrompt 读人格文件'; Status=$r.Status; Fn=$r.Name })
        $r = Patch-AgentIdentity $content $expr;           $content = $r.Content; [void]$results.Add([pscustomobject]@{ Id=3; Label='Agent Identity 读人格文件'; Status=$r.Status; Fn=$r.Name })
        $r = Patch-NullSection $content $LitDate;          $content = $r.Content; [void]$results.Add([pscustomobject]@{ Id=4; Label='日期提醒移除'; Status=$r.Status; Fn=$r.Name })
        $r = Patch-NullSection $content $LitSkills;        $content = $r.Content; [void]$results.Add([pscustomobject]@{ Id=5; Label='Skills 列表移除'; Status=$r.Status; Fn=$r.Name })
        $r = Patch-NullSection $content $LitUserCtx;       $content = $r.Content; [void]$results.Add([pscustomobject]@{ Id=6; Label='User Context 移除'; Status=$r.Status; Fn=$r.Name })

        foreach ($x in $results) {
            $tag = if ($x.Fn) { " ($($x.Fn))" } else { "" }
            switch ($x.Status) {
                'ok'      { Good ("[{0}] {1}{2}" -f $x.Id, $x.Label, $tag) }
                'skip'    { Skipd ("[{0}] {1}{2}" -f $x.Id, $x.Label, $tag) }
                default   { Bad ("[{0}] {1}{2} — 未找到目标" -f $x.Id, $x.Label, $tag) }
            }
        }

        $missing = @($results | Where-Object { $_.Status -eq 'missing' })
        if ($missing.Count -gt 0 -and -not $AllowPartial) {
            Write-Host ""
            Bad "有 $($missing.Count) 个补丁未命中，ZCode 版本可能又变了。未做任何修改。"
            Note "请把下面这段诊断结果发给维护者："
            Write-Host ""
            Show-Sections ([System.IO.File]::ReadAllText($ZcodeCjs))
            Write-Host ""
            Note "如确认可以接受不完整结果，可加 -AllowPartial 强制部署。"
            exit 1
        }

        Info "[4/6] 语法校验 (node --check)..."
        $errText = ''
        $syntaxOk = Test-JsSyntax -content $content -nodeExe $nodeExe -errText ([ref]$errText)
        if (-not $syntaxOk) {
            Bad "补丁后语法校验失败，已放弃写入，原文件未被修改"
            Note $errText
            exit 1
        }
        if ($nodeExe) { Good "语法校验通过" } else { Warn2 $errText }

        Info "[5/6] 写入 zcode.cjs..."
        $bytes  = [System.IO.File]::ReadAllBytes($ZcodeCjs)
        $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
        [System.IO.File]::WriteAllText($ZcodeCjs, $content, (New-Object System.Text.UTF8Encoding($hasBom)))
        Good ("已写入 ({0} bytes, BOM={1})" -f (Get-Item -LiteralPath $ZcodeCjs).Length, $hasBom)

        Write-Host ""
        Info "--- 写入后自检 ---"
        foreach ($r2 in (Get-PatchReport $content)) {
            if ($r2.Ok) { Good $r2.Name } else { Warn2 $r2.Name }
        }
        Note "人格文件路径(已写入 cjs): $PromptFileJS"

        Info "[6/6] 重启 ZCode..."
        Restart-ZCode $ZcodeExe

        Write-Host ""
        Write-Host "=== 部署完成 ===" -ForegroundColor Green
        Note "人格文件: $PromptFile   (改这个文件即可热换人格，开新对话生效)"
        Note "注意: 本文件夹被移动后需要重跑 install（路径已写入 zcode.cjs）"
    }

    "restore" {
        Info "[1/4] 检查备份..."
        if (-not (Test-Path -LiteralPath $ZcodeBackup)) {
            Bad "备份不存在: $ZcodeBackup"
            if (Test-Path -LiteralPath $BackupDir) {
                Note "备份目录中可用档案:"
                Get-ChildItem -LiteralPath $BackupDir -Filter "*.bak" | Sort-Object LastWriteTime -Descending | Select-Object -First 10 |
                    ForEach-Object { Note ("  {0}  ({1} bytes, {2})" -f $_.Name, $_.Length, $_.LastWriteTime) }
            }
            exit 1
        }
        $bakLen = (Get-Item -LiteralPath $ZcodeBackup).Length
        Good ("备份: {0} ({1} bytes)" -f $ZcodeBackup, $bakLen)

        Info "[2/4] 校验备份并归档当前版本..."
        $bakContent = [System.IO.File]::ReadAllText($ZcodeBackup)
        $errText = ''
        if (-not (Test-JsSyntax -content $bakContent -nodeExe $nodeExe -errText ([ref]$errText))) {
            Bad "备份文件语法校验失败，已中止还原"
            Note $errText
            exit 1
        }
        $cur = [System.IO.File]::ReadAllText($ZcodeCjs)
        if ($cur.Contains($Marker)) {
            $arch = Archive-Current $ZcodeCjs "patched"
            Note "已归档当前已破解版本 -> $arch"
        }

        Info "[3/4] 还原代码..."
        [System.IO.File]::WriteAllText($ZcodeCjs, $bakContent, (New-Object System.Text.UTF8Encoding($false)))
        Good "已还原为原版"

        if (Test-Path -LiteralPath $PromptFile) { Skipd "人格文件保留: $PromptFile" }

        Info "[4/4] 重启 ZCode..."
        Restart-ZCode $ZcodeExe

        Write-Host ""
        Write-Host "=== 恢复完成 ===" -ForegroundColor Green
    }
}
