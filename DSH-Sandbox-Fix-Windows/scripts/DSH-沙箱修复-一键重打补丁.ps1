# ============================================================================
#  DSH Windows 沙箱修复 —— 一键重打补丁工具
# ============================================================================
#  用途：DeepSeek Harness 自动更新后，app.asar 会被替换成原版，
#        受限（沙箱内）shell 会重新变成 0xC0000142 而无法使用。
#        运行本脚本即可重新打上修复。
#
#  用法：
#    1. 完全退出 DeepSeek Harness（窗口 + 托盘图标 + 任务管理器确认）
#    2. 右键本文件 -> 使用 PowerShell 运行
#       或在 PowerShell 里执行：
#       powershell -ExecutionPolicy Bypass -File "本文件路径"
#
#  安全性：本脚本只做两件事——把 app.asar 内一个文件替换为修复版
#          （字节数不变），以及确保支撑树存在。不改动沙箱逻辑。
# ============================================================================

$ErrorActionPreference = 'Stop'

# ----------------------------------------------------------------- 路径配置
$InstallDir   = 'D:\deepseek harness'
$Asar         = Join-Path $InstallDir 'resources\app.asar'
$SupportTree  = 'C:\Users\Administrator\.dsh\sandbox-support'
$PlainNode    = Join-Path $InstallDir 'resources\runtime\primary-runtime\dependencies\node\bin\node.exe'
$ScriptDir    = Split-Path -Parent $MyInvocation.MyCommand.Path
$Patcher      = Join-Path $ScriptDir 'dsh-install-fix2.mjs'
$PristineR    = Join-Path $ScriptDir 'runner-pristine.js'

function Say($m) { Write-Host $m }
function Fail($m) { Write-Host ""; Write-Host "错误：$m" -ForegroundColor Red; Write-Host ""; exit 1 }

Say ""
Say "============================================================"
Say "  DSH Windows 沙箱修复 —— 一键重打补丁"
Say "============================================================"
Say ""

# ----------------------------------------------------------------- 1. 前置检查
if (-not (Test-Path $Asar))        { Fail "找不到 app.asar：$Asar" }
if (-not (Test-Path $PlainNode))   { Fail "找不到普通 node 运行时：$PlainNode" }
if (-not (Test-Path $Patcher))     { Fail "找不到打补丁脚本：$Patcher" }
if (-not (Test-Path $PristineR))   { Fail "找不到原始 runner 文件：$PristineR" }

Say "app.asar  : $Asar"
Say "支撑树    : $SupportTree"
Say "普通 node : $PlainNode"
Say ""

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

if (-not (Test-Path $runner)) { Fail "支撑树缺少 runner：$runner" }
if (-not (Test-Path $koffi))  { Fail "支撑树缺少原生模块：$koffi" }
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
