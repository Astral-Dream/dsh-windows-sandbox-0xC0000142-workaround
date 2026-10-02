# DSH-Sandbox-Fix-Windows

> 修复 DeepSeek Harness 在 Windows 上 **workspace-write（沙箱内）权限下 shell 完全不可用**（`0xC0000142`）的问题。

---

## ⚠️ 免责声明（请先读这段）

**1. 这个修复是我用 DeepSeek 自己排查、自己修自己的产物。**

整个排查和修复过程都是 DeepSeek Harness 的 agent 在会话中自主完成的——定位根因、写复现脚本、改 asar、做验证。我只负责运行它给出的命令、切换权限、把结果贴回去。

**2. 我不对修复效果负责。**

- 我在**我自己这一台机器**上验证通过（见下方"验证"）；**我无法保证它在你的机器上有效**，也无法保证不会引入别的问题。
- 这**不是上游官方修复**，而是直接修改 `app.asar` 的本地补丁。
- 涉及修改 DeepSeek Harness 的安装文件，请自行评估风险、**务必先备份**。

**3. 如果修复出错或无效 —— 把交接文档和所有修复资产交给 DeepSeek Harness，让它尝试自我修复。**

```
docs/DSH-Windows沙箱修复-交接文档.md
scripts/runner-pristine.js
scripts/dsh-install-fix2.mjs
scripts/DSH-沙箱修复-一键重打补丁.ps1
```

在 DSH 会话里说类似这样的话：

> 我在 Windows 上用这份交接文档和修复资产修沙箱问题，但出错了。请读 `docs/DSH-Windows沙箱修复-交接文档.md` 和 `scripts/` 里的文件，自己判断问题在哪并尝试修复。

文档里包含了完整的根因分析、代码差异、验证方法和回滚步骤，足够让 agent 接手。

---

## 症状

在 **workspace-write（沙箱内）** 模式下，任何 shell 命令都失败：

```
[exit code: 3221225794]
```

无任何输出。`3221225794` = `0xC0000142` = `STATUS_DLL_INIT_FAILED`。

**关键鉴别特征**：切换成 **danger-full-access（完全权限）** 后 shell 完全正常。也就是**只有开启沙箱时才用不了 shell**。

---

## 根因

DSH 在 Windows 上用**受限制令牌（restricted token）**实现进程沙箱：`@deepseek-ai/dsh-sandbox-windows-acl` 先创建 `WRITE_RESTRICTED` 令牌（带能力 SID 写入白名单、降到 Low 完整性），再用 `CreateProcessAsUserW` 创建子进程。

**问题出在托管沙箱程序的那个运行时**：

| 运行沙箱程序的宿主 | 结果 |
|---|---|
| 普通 `node.exe` | **exit 0** ✓ |
| `DeepSeek Harness.exe`（Electron-as-node） | **`0xC0000142`** ✗ |

其他条件完全相同（同样的 workspace、temp、SID、模式、目标程序、同一台机器）。当宿主是 Electron-as-node 时，它创建的受限制子进程会在 **DLL 初始化阶段**死亡。

**已用二分法排除的因素**：目标程序类型、`windowsHide`、控制台、环境变量、fd 布局、`DSH_SUBPROCESS_CONTROL` 通道、ACL/SID 状态、temp 目录。并且确认**只在 `workspace-write` 触发**（`read-only` 模式正常）。

> 与 Git 是否安装、代理、杀毒软件、系统环境变量**完全无关**。

---

## 修复原理

**只换托管运行时，不动沙箱逻辑。**

在 `app.asar` 内的沙箱启动程序加一段判断：若检测到自己跑在 Electron 宿主下，就用 DSH 自带的**普通 node** 运行时、从**真实文件系统的副本**重新执行自己。

```
DeepSeek Harness (Electron) 启动沙箱程序
        ↓  检测到 process.versions.electron
普通 node.exe 重执行磁盘副本
        ↓
创建受限制令牌 → 子进程正常启动
```

**为什么需要磁盘副本**：普通 node **读不了 asar 内部的路径**（asar 支持是 Electron 特有的），所以必须把沙箱程序及依赖解包到磁盘（即"支撑树"）。

**为什么这不算绕过沙箱**：受限制令牌创建、能力 SID、ACL 授予、Low 完整性标签、写入限制——**一行都没改**。改动仅为：1 行原始代码被改写（记录退出码）+ 15 行新增（日志与重执行）。沙箱核心文件 `types-Cl_DXjhk.js` **零改动**。

---

## 验证

修复后在本机实测（**workspace-write 沙箱内**）：

| 测试 | 结果 |
|---|---|
| `echo hello` | `hello` ✓ |
| `git --version` | `git version 2.56.0.windows.1` ✓ |
| 写入工作区**外** | **拒绝访问** ✓（沙箱仍生效） |
| 写入工作区**内** | 成功 ✓ |
| 越界文件是否产生 | 不存在 ✓ |

---

## 仓库内容

```
DSH-Sandbox-Fix-Windows/
├── README.md                              ← 本文件
├── LICENSE                                ← MIT
├── docs/
│   └── DSH-Windows沙箱修复-交接文档.md    ← 完整技术文档（根因/代码差异/步骤/回滚）
└── scripts/
    ├── runner-pristine.js                 ← 原始 runner（补丁输入，勿改）
    ├── dsh-install-fix2.mjs               ← 打补丁程序
    └── DSH-沙箱修复-一键重打补丁.ps1      ← 一键脚本
```

**完整技术文档**见 [`docs/DSH-Windows沙箱修复-交接文档.md`](docs/DSH-Windows沙箱修复-交接文档.md)，包含逐段代码片段、手动操作步骤、清理与回滚。

---

## 使用方法

### 前置条件

| 项目 | 要求 |
|---|---|
| 权限 | **管理员**，或能写入 DSH 安装目录的账户 |
| 执行环境 | **系统 PowerShell / 完全权限**（脚本要写入工作区外目录，沙箱内会被拒绝） |
| 应用状态 | **必须完全退出** DeepSeek Harness |

### 第 1 步：完全退出应用

关闭所有窗口 → 右下角**托盘图标**右键退出 → 任务管理器确认：

```powershell
if (Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue) { '仍在运行' } else { '已关闭' }
```

### 第 2 步：确认脚本里的路径

打开 `scripts/DSH-沙箱修复-一键重打补丁.ps1`，检查文件开头的路径配置是否符合你的环境：

```powershell
$InstallDir   = 'D:\deepseek harness'                        # DSH 安装目录
$SupportTree  = 'C:\Users\Administrator\.dsh\sandbox-support' # 支撑树位置（可改）
```

`$SupportTree` 必须**位于工作区之外**（见下方"注意事项"）。用户名不同的话要相应修改。

> 💡 **编辑 `.ps1` 时请保留 UTF-8 BOM**。Windows PowerShell 5.1 对无 BOM 的文件按 ANSI 解码，脚本里的中文会被解码错乱并导致**语法错误无法运行**。用 VS Code 保存时选 "UTF-8 with BOM"，或在 PowerShell 里执行：
> ```powershell
> $p = "路径\DSH-沙箱修复-一键重打补丁.ps1"
> $t = [IO.File]::ReadAllText($p, [Text.UTF8Encoding]::new($false))
> [IO.File]::WriteAllText($p, $t, (New-Object Text.UTF8Encoding($true)))
> ```

### 第 3 步：运行一键脚本

```powershell
powershell -ExecutionPolicy Bypass -File "路径\DSH-沙箱修复-一键重打补丁.ps1"
```

期望输出结尾：

```
[4/5] 校验通过：runner 与原生模块就位
[5/5] app.asar 已更新
```

### 第 4 步：启动应用并验证

启动 DSH → 切到 **workspace-write（沙箱内）** → 执行 `echo hello` → 应返回 `hello`。

然后**务必确认沙箱仍在拦截**：

```powershell
try { Set-Content -Path 'D:\sandbox-escape.txt' -Value x -ErrorAction Stop; '越界成功(异常!)' } catch { '越界被拒绝(正常)' }
```

若越界写入**成功** → 沙箱失效，**立即回滚**（见下）。

---

## ⚠️ 注意事项

### 应用更新会覆盖修复

DSH 自动更新会替换 `app.asar`，修复失效。**更新后重新运行一键脚本即可**。

### 强烈建议备份

- 把 `scripts/` 下三个文件**备份到其他盘**（共约 28 KB）。有它们 + DSH 安装目录，即使支撑树全丢也能重建修复。
- 可另外保存一份已修复的 `app.asar`（重命名为 `app.asar.fixed`）作应急副本。**但它版本绑定**——更新后用旧副本覆盖新版可能让应用起不来。**常规修复请用一键脚本，不要用 `.fixed` 覆盖。**

### 支撑树不能删

脚本会创建 `C:\Users\Administrator\.dsh\sandbox-support\`（约 **297 MB**）——沙箱程序的磁盘副本，修复依赖它。

| 情况 | 能否删 |
|---|---|
| 修复**启用中** | **绝对不能删** |
| 已回滚修复 | 可删（无主残留） |
| 想重建 | 跑一键脚本 |

**其他两点**：

- **不要把它移进工作区**。必须留在工作区外，这样沙箱内进程无法篡改沙箱自身组件。
- 磁盘清理软件可能把它当垃圾删掉。**沙箱内 shell 突然失效时，先查这个目录是否还在。**

### 回滚

应用完全退出后：

```powershell
Copy-Item "D:\deepseek harness\resources\app.asar.backup-gitfix" "D:\deepseek harness\resources\app.asar" -Force
Remove-Item "C:\Users\Administrator\.dsh\sandbox-support" -Recurse -Force
```

脚本会保留：
- `app.asar.backup-gitfix` —— **原始未修复**归档（永不覆盖）
- `app.asar.pre-fix-<时间戳>` —— 每次更新后的回滚点

---

## 已知限制

- **版本绑定**：补丁对应特定 DSH 版本。应用更新后必须重打（一键脚本会自动基于新版内容重新生成，因此仍然可用）。
- **仅针对本症状**：只修复"Electron 宿主导致受限制子进程 DLL 初始化失败"这一条路径。**不修复**沙箱的其它已知边界，例如：
  - 受限孙进程的**管道 stdio 捕获不可用**（`spawn(..., {stdio:'pipe'})` → `EPERM`）
  - 读取被其它 AppContainer 工具打上 package SID 的文件
  - 硬链接绕过写入边界
- **宿主相关**：`0xC0000142` 在 Windows 上还有**其它独立成因**（例如 desktop heap 耗尽、进程创建资源紧张），那些与沙箱无关，本补丁不适用。判断方法：若失败是**间歇性、突发性、且影响非 DSH 启动的进程**，很可能是另一类问题。
- **非官方修复**：直接修改 `app.asar`。若未来版本引入完整性校验，可能因此报错。

---

## 上报上游的建议

这是**本地临时绕过，不是根治**。根因在上游：沙箱不应由 Electron-as-node 托管，或在 Electron 宿主下应改用兼容的进程创建方式。

建议向 DSH 团队反馈，并提供：

1. 唯一变量是宿主运行时（普通 node 成功 / Electron-as-node 崩溃）；`0xC0000142`
2. 最小复现：在 Electron-as-node 进程内用 `@deepseek-ai/dsh-win32-process` 的 `spawnCurrentTokenJobProcess` 启动 `@deepseek-ai/dsh-sandbox-windows-acl/lib/runner.js`，令其以 `workspace-write` 创建受限制子进程 → 子进程 `STATUS_DLL_INIT_FAILED`
3. 对照：同样调用在普通 node 宿主下正常

完整定位过程见交接文档附录。

---

## 致谢与出处

- 修复对象：[DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)
- 排查与修复过程：由 DeepSeek Harness 的 agent 在本机会话中自主完成
- 沙箱实现参考：`@deepseek-ai/dsh-sandbox-windows-acl` 内的 README（其"Boundaries"与"Modes and token lists"章节记录了相关边界）

## 许可

MIT，见 [LICENSE](LICENSE)。
