# ============================================================================
#  DSH Windows 沙箱修复 —— 一键重打补丁工具
# ============================================================================
#  用途：DeepSeek Harness 自动更新后，app.asar 会被替换成原版，
#        受限（沙箱内）shell 会重新变成 0xC0000142 而无法使用。
#        运行本脚本即可重新打上修复。
#
#  用法（三条路径全部手动输入，脚本内不再写死任何绝对路径）：
#    1. 完全退出 DeepSeek Harness（窗口 + 托盘图标 + 任务管理器确认）
#    2. 右键本文件 -> 使用 PowerShell 运行
#       或在 PowerShell 里执行：
#       powershell -ExecutionPolicy Bypass -File "本文件路径"
#    3. 按提示逐项输入路径；直接回车 = 采用方括号里自动探测到的默认值。
#
#  非交互用法（三条路径都作为参数传入时不会提问）：
#      powershell -ExecutionPolicy Bypass -File "本文件路径" `
#          -InstallDir "D:\deepseek harness" `
#          -SupportTree "C:\Users\你的用户名\.dsh\sandbox-support" `
#          -PlainNode "D:\deepseek harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe" `
#          -Yes
#
#  安全性：本脚本只做两件事——把 app.asar 内一个文件替换为修复版
#          （字节数不变），以及确保支撑树存在。不改动沙箱逻辑。
# ============================================================================

[CmdletBinding()]
param(
    [string]$InstallDir  = '',   # DSH 安装目录（含 resources\app.asar）
    [string]$SupportTree = '',   # 支撑树目录（必须在工作区之外）
    [string]$PlainNode   = '',   # DSH 自带的普通 node.exe
    [switch]$Yes                 # 跳过最后确认，直接开始打补丁（非交互）
)

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------- 固定位置
$ScriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$Patcher   = Join-Path $ScriptDir 'dsh-install-fix2.mjs'
$PristineR = Join-Path $ScriptDir 'runner-pristine.js'

function Say($m) { Write-Host $m }
function Fail($m) { Write-Host ""; Write-Host "错误：$m" -ForegroundColor Red; Write-Host ""; exit 1 }

# 去掉粘贴时可能带上的引号、首尾空白与结尾反斜杠
function Norm([string]$p) {
    if ([string]::IsNullOrWhiteSpace($p)) { return '' }
    $p = $p.Trim()
    $p = $p -replace '^["'']', ''
    $p = $p -replace '["'']$', ''
    return $p.Trim().TrimEnd('\')
}

# ----------------------------------------------------------------- 校验器
# 返回错误说明（字符串）表示不合格；返回 $null 表示合格。
function Test-InstallDir([string]$dir) {
    if (-not $dir) { return '路径不能为空' }
    if (-not (Test-Path -LiteralPath $dir)) { return "目录不存在：$dir" }
    if (-not (Test-Path -LiteralPath (Join-Path $dir 'resources\app.asar'))) {
        return "该目录下找不到 resources\app.asar，似乎不是 DSH 安装目录：$dir"
    }
    return $null
}
function Test-NodeExe([string]$exe) {
    if (-not $exe) { return '路径不能为空' }
    if (-not (Test-Path -LiteralPath $exe)) { return "文件不存在：$exe" }
    if ((Split-Path -Leaf $exe) -ne 'node.exe') { return "这不是 node.exe：$exe" }
    return $null
}

# ----------------------------------------------------------------- 自动探测
function Find-InstallDir {
    $cands = @()
    $p = Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue |
         Where-Object { $_.Path } | Select-Object -First 1
    if ($p) { $cands += (Split-Path -Parent $p.Path) }
    $cands += 'D:\deepseek harness'
    if ($env:LOCALAPPDATA) { $cands += (Join-Path $env:LOCALAPPDATA 'Programs\deepseek-harness') }
    if ($env:ProgramFiles) { $cands += (Join-Path $env:ProgramFiles 'DeepSeek Harness') }
    foreach ($c in $cands) {
        if ($c -and -not (Test-InstallDir (Norm $c))) { return (Norm $c) }
    }
    return ''
}
function Find-PlainNode([string]$installDir) {
    if (-not $installDir) { return '' }
    $rt = Join-Path $installDir 'resources\runtime'
    if (-not (Test-Path -LiteralPath $rt)) { return '' }
    $found = Get-ChildItem -LiteralPath $rt -Filter 'node.exe' -Recurse -ErrorAction SilentlyContinue |
             Where-Object { $_.FullName -match '\\dependencies\\node\\bin\\node\.exe$' } |
             Select-Object -First 1
    if ($found) { return $found.FullName }
    return ''
}

# ----------------------------------------------------------------- 手动输入
# 交互式询问一个路径：直接回车 = 使用默认值（如果有）；校验不过会重新问。
function Ask([string]$Title, [string]$Default, [scriptblock]$Validator) {
    $tries = 0
    while ($true) {
        $tries++
        if ($tries -gt 5) {
            Fail "「$Title」连续 5 次都没有输入有效值。`n       可改用参数方式非交互运行，见本文件顶部说明。"
        }
        try {
            if ($Default) { $line = Read-Host "请输入 $Title`n   （直接回车使用默认值：$Default）" }
            else          { $line = Read-Host "请输入 $Title`n   （没有默认值，必须填写）" }
        } catch {
            Fail "无法从控制台读取输入（当前似乎不是交互式环境）。`n       请改用参数方式：-InstallDir / -SupportTree / -PlainNode，见本文件顶部说明。"
        }
        $v = Norm $line
        if (-not $v) { $v = Norm $Default }
        if (-not $v) { Write-Host "  × 不能为空，请重新输入。" -ForegroundColor Yellow; continue }
        if ($Validator) {
            $why = & $Validator $v
            if ($why) { Write-Host "  × $why" -ForegroundColor Yellow; continue }
        }
        return $v
    }
}
# 由参数提供的路径同样要过一遍校验
function Use-Param([string]$Value, [string]$Title, [scriptblock]$Validator) {
    $v = Norm $Value
    if ($Validator) {
        $why = & $Validator $v
        if ($why) { Fail "$Title 参数无效：$why" }
    }
    return $v
}

Say ""
Say "============================================================"
Say "  DSH Windows 沙箱修复 —— 一键重打补丁"
Say "============================================================"
Say ""
Say "本脚本不写死任何绝对路径，接下来需要你手动输入（回车 = 用默认值）。"
Say ""

# ----------------------------------------------------------------- 0. 收集路径
if ($InstallDir) { $InstallDir = Use-Param $InstallDir 'DSH 安装目录' { param($v) Test-InstallDir $v } }
else             { $InstallDir = Ask 'DSH 安装目录' (Find-InstallDir) { param($v) Test-InstallDir $v } }
$Asar = Join-Path $InstallDir 'resources\app.asar'

if ($SupportTree) { $SupportTree = Norm $SupportTree }
else {
    $SupportTree = Ask '支撑树目录（必须在工作区之外，专用于存放沙箱程序的磁盘副本）' `
                       (Join-Path $env:USERPROFILE '.dsh\sandbox-support') $null
}

if ($PlainNode) { $PlainNode = Use-Param $PlainNode '普通 node 运行时' { param($v) Test-NodeExe $v } }
else            { $PlainNode = Ask '普通 node 运行时（DSH 自带的 node.exe 全路径）' (Find-PlainNode $InstallDir) { param($v) Test-NodeExe $v } }

# ----------------------------------------------------------------- 1. 前置检查
if (-not (Test-Path -LiteralPath $Asar))      { Fail "找不到 app.asar：$Asar" }
if (-not (Test-Path -LiteralPath $Patcher))   { Fail "找不到打补丁脚本：$Patcher（请与脚本放在同一目录）" }
if (-not (Test-Path -LiteralPath $PristineR)) { Fail "找不到原始 runner 文件：$PristineR（请与脚本放在同一目录）" }

Say ""
Say "即将使用以下路径："
Say "  DSH 安装目录 : $InstallDir"
Say "  app.asar     : $Asar"
Say "  支撑树       : $SupportTree"
Say "  普通 node    : $PlainNode"
Say "  打补丁程序   : $Patcher"
Say "  原始 runner  : $PristineR"
Say ""

if ($SupportTree.StartsWith($InstallDir, 'OrdinalIgnoreCase')) {
    Say "⚠ 提示：支撑树位于 DSH 安装目录内，应用更新时可能被一并清掉，"
    Say "        建议改到别处，例如 C:\Users\你的用户名\.dsh\sandbox-support。"
    Say ""
}

if (-not $Yes) {
    try { $ok = Read-Host "确认以上路径无误请输入 Y 回车继续（其它任意键取消）" }
    catch { Fail "无法读取确认输入（非交互式环境）。加 -Yes 参数可跳过确认。" }
    if ($ok -notmatch '^[Yy]') { Say "已取消，未做任何修改。"; exit 0 }
    Say ""
}

# ----------------------------------------------------------------- 2. 应用是否关闭
$procs = Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue
if ($procs) {
    Fail "DeepSeek Harness 仍在运行（$($procs.Count) 个进程）。`n       请完全退出：关闭所有窗口 -> 托盘图标右键退出 -> 任务管理器确认。"
}
# 二次确认：能否独占打开 app.asar
try {
    $fs = [System.IO.File]::Open($Asar, 'Open', 'ReadWrite', 'None')
    $fs.Close()
} catch {
    Fail "app.asar 仍被占用（文件锁）。请确认应用已完全退出，包括托盘图标和后台进程。"
}
Say "[1/5] 应用已确认关闭，app.asar 可写"

# ----------------------------------------------------------------- 3. 版本留痕
$stampFile = Join-Path $SupportTree 'applied-version.txt'
$currentHash = (Get-FileHash $Asar -Algorithm SHA256).Hash
Say "[2/5] 当前 app.asar SHA256：$currentHash"

# ----------------------------------------------------------------- 4. 打补丁
Say "[3/5] 正在应用修复（解包支撑树 + 原地替换 runner）..."
$plainNodeForPatcher = $PlainNode
& $plainNodeForPatcher $Patcher $Asar $SupportTree $PlainNodeForPatcher '' $PristineR
if ($LASTEXITCODE -ne 0) { Fail "打补丁脚本返回失败（退出码 $LASTEXITCODE）。app.asar 未被修改或已回滚，请把上方输出发给我。" }

# ----------------------------------------------------------------- 5. 校验
$newHash = (Get-FileHash $Asar -Algorithm SHA256).Hash
$runner = Join-Path $SupportTree 'dsh\node_modules\@deepseek-ai\dsh-sandbox-windows-acl\lib\runner.js'
$koffi  = Join-Path $SupportTree 'dsh\node_modules\@koromix\koffi-win32-x64\win32_x64\koffi.node'

if (-not (Test-Path -LiteralPath $runner)) { Fail "支撑树缺少 runner：$runner" }
if (-not (Test-Path -LiteralPath $koffi))  { Fail "支撑树缺少原生模块：$koffi" }
$mz = [System.IO.File]::ReadAllBytes($koffi)[0..1]
if (-not ($mz[0] -eq 0x4D -and $mz[1] -eq 0x5A)) { Fail "原生模块 koffi.node 不是有效的 Windows 二进制（MZ 头缺失）。" }

Say "[4/5] 校验通过：runner 与原生模块就位"
Say "[5/5] app.asar 已更新"
Say ""
Say "------------------------------------------------------------"
Say "  完成。"
Say ""
Say "  修复前 SHA256：$currentHash"
Say "  修复后 SHA256：$newHash"
Say ""
Say "  下一步：启动 DeepSeek Harness，"
Say "  切到 workspace-write（沙箱内）权限，执行 echo hello 验证。"
Say "  应返回 hello，且写入工作区外的文件仍被拒绝。"
Say "------------------------------------------------------------"
Say ""

# ----------------------------------------------------------------- 版本留痕
try {
    New-Item -ItemType Directory -Force -Path $SupportTree | Out-Null
    @(
        "applied-at      : $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')"
        "app.asar        : $Asar"
        "asar-sha256-after: $newHash"
        "plain-node      : $PlainNode"
        "support-tree    : $SupportTree"
    ) | Set-Content -Path $stampFile -Encoding UTF8
    Say "留痕已写入：$stampFile"
} catch { Say "（留痕写入失败，不影响修复）" }
