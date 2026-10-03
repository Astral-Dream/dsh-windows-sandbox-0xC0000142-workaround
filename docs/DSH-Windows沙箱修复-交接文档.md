# DSH Windows 沙箱修复 —— 交接文档

> 生成时间：2026-10-02
> 适用：DeepSeek Harness 桌面版（Windows）
> 状态：**已在本机验证通过**

---

## 目录

1. [问题现象](#1-问题现象)
2. [根因](#2-根因)
3. [修复原理](#3-修复原理)
4. [涉及修改的代码片段](#4-涉及修改的代码片段)
5. [更新后如何重打补丁（一键脚本）](#5-更新后如何重打补丁一键脚本)
6. [更新后如何用 app.asar.fixed 直接替换](#6-更新后如何用-appasarfixed-直接替换)
7. [验证修复是否生效](#7-验证修复是否生效)
8. [磁盘支撑树说明与清理](#8-磁盘支撑树说明与清理)
9. [卸载 / 回滚](#9-卸载--回滚)
10. [安全说明](#10-安全说明)
11. [文件清单](#11-文件清单)

---

## 1. 问题现象

在 **workspace-write（沙箱内）** 权限下，任何 shell 命令都失败：

```
[exit code: 3221225794]
```

无任何输出。`3221225794` = `0xC0000142` = `STATUS_DLL_INIT_FAILED`（进程 DLL 初始化失败）。

**关键特征**：切换成 **danger-full-access（完全权限）** 后 shell 完全正常。也就是说，只要开启沙箱就用不了 shell。

---

## 2. 根因

DSH 在 Windows 上用**受限制令牌（restricted token）** 实现进程沙箱：`@deepseek-ai/dsh-sandbox-windows-acl` 包先创建 `WRITE_RESTRICTED` 令牌（带能力 SID 写入白名单、降到 Low 完整性），再用 `CreateProcessAsUserW` 以该令牌创建子进程。

问题出在**托管沙箱程序的那个运行时**：

| 运行沙箱程序的宿主 | 结果 |
|---|---|
| 普通 `node.exe` | **exit 0** ✓ |
| `DeepSeek Harness.exe`（Electron-as-node） | **0xC0000142** ✗ |

其他条件完全相同（同样的 workspace、temp、SID、模式、目标程序、同一台机器）。当宿主是 Electron-as-node 时，它创建的受限制子进程会在 DLL 初始化阶段死亡。

**触发条件**（已用二分法确认）：

- **只在 `workspace-write` 模式触发**；`read-only` 模式（限制列表不同）正常；
- 与目标程序无关 —— `powershell.exe`、`cmd.exe`、`node.exe` 全部崩溃；
- 与 `windowsHide`、控制台、环境变量、fd 布局、`DSH_SUBPROCESS_CONTROL` 通道**均无关**（逐个排除过）。

**与你机器上这些东西无关**：Git 是否安装、代理、杀毒软件、系统环境变量、注册表 —— 排查早期我曾错误怀疑这些，事后证明全部无关。

---

## 3. 修复原理

**只换托管运行时，不动沙箱逻辑。**

在 `app.asar` 内的沙箱启动程序处加一段判断：如果检测到自己跑在 Electron 宿主下，就用 DSH 自带的**普通 node** 运行时，从**真实文件系统的副本**重新执行自己。

```
┌─ DeepSeek Harness (Electron) 启动沙箱程序 ─┐
│  检测到 process.versions.electron           │
│  → 用普通 node.exe 重执行真实文件系统副本   │
└────────────────────────────────────────────┘
                    ↓
   普通 node 托管 → 创建受限制令牌 → 子进程正常启动
```

**为什么需要"真实文件系统副本"**：普通 node **读不了 asar 内部的路径**（asar 支持是 Electron 特有的）。所以必须把沙箱程序及其依赖解包到磁盘上一次（即第 8 节的支撑树）。

**为什么这不算绕过沙箱**：受限制令牌的创建、能力 SID、ACL 授予、Low 完整性标签、写入限制 —— **一行都没改**。见第 7 节的行为验证。

---

## 4. 涉及修改的代码片段

### 4.1 修改的文件

`app.asar` 内仅一个文件：

```
dsh/node_modules/@deepseek-ai/dsh-sandbox-windows-acl/lib/runner.js
```

原始大小 **7807 字节**，修补后**仍为 7807 字节**（不足处用空格补齐，使得归档内偏移量完全不变，无需重新打包 121 MB 的 asar）。

> 沙箱的核心实现位于同目录的 `types-Cl_DXjhk.js`（含 `CreateProcessAsUserW`、`createRestrictedToken`、`buildLowRestrictingSids`、ACL/标签授予等），**该文件完全未被修改**。

### 4.2 修改点一：插入诊断函数（`dg`）

**位置**：`const RUNNER_FAILURE_EXIT = 127;` 之后

```js
const diag = LOGPATH ? `function dg(e,x){try{appendFileSync(<日志路径>,JSON.stringify(Object.assign({ev:e},x))+"\n")}catch(_){}}\n` : `function dg(){}\n`;
```

关闭日志时它展开为 `function dg(){}`（空函数，零开销）。

### 4.3 修改点二：`main()` 开头插入重执行块 ★核心修复

**位置**：`async function main() {` 之后，**任何参数解析之前**

```js
async function main() {
	dg("start",{a:process.argv.slice(2),e:process.execPath});
	if (process.versions.electron !== void 0) {
		const real = "<支撑树>\dsh\node_modules\@deepseek-ai\dsh-sandbox-windows-acl\lib\runner.js";
		const pn = "<DSH 安装目录>\resources\runtime\primary-runtime\dependencies\node\bin\node.exe";
		if (existsSync(real) && existsSync(pn)) {
			dg("reexec",{from:process.execPath,to:pn,real:real});
			const r = (await import("node:child_process")).spawnSync(pn, [real, ...process.argv.slice(2)], { stdio: "inherit" });
			process.exit(r.status === null ? 1 : r.status);
		}
		dg("reexec-skipped",{real:real,pn:pn});
	}
	const parsed = parseArgs(process.argv.slice(2));
	...
```

**逻辑**：仅在 `process.versions.electron` 存在时触发（即宿主是 Electron）。重执行后普通 node 没有该属性 → 不再重执行 → 无递归。

`stdio: "inherit"` 保证 stdout/stderr/控制管道原样传递，退出码原样透传。

### 4.4 修改点三 ~ 五：日志埋点与退出码透传

```js
// spawn 之前
dg("pre",{s:seamManaged,m:parsed.mode,c:parsed.command});

// 原来的一行：
//     return (await child.wait()).exitCode;
// 改为三行（唯一被改写的原始代码行）：
const x=(await child.wait()).exitCode;
dg("exit",{code:x});
return x;

// 顶层失败分支
dg("rej",{m:error instanceof Error?error.message:String(error)});
if (!(error instanceof RunnerFailure)) ...
```

### 4.5 补丁的完整差异摘要

| 项目 | 结果 |
|---|---|
| 原始代码行数 | 140 |
| 修补后代码行数 | 156 |
| **被改写的原始行** | **仅 1 行**（上面的 `return (await child.wait())`） |
| 新增行 | 15（1 个日志函数 + 12 行重执行块 + 若干日志调用） |
| 沙箱核心逻辑 | **0 处改动** |

> 注：注释里的文字与用户数据不会被修改；由于需要腾出 7807 字节的槽位，**原文件的注释会被移除**（约回收 2682 字节），其余代码原样保留。

---

## 5. 更新后如何重打补丁（一键脚本）

### 5.1 前置条件

| 项目 | 要求 |
|---|---|
| 权限 | **管理员** 或能写入 `D:\deepseek harness\resources` 的账户 |
| 沙箱状态 | **必须在完全权限（danger-full-access）下执行**，或直接在系统 PowerShell 里跑 —— 因为脚本要写入工作区**之外**的目录，沙箱内会被拒绝 |
| 应用状态 | **必须完全退出** DeepSeek Harness |

### 5.2 操作步骤

**第 1 步：完全退出应用**

关闭所有窗口 → 右下角**托盘图标**右键退出 → 任务管理器确认无 `DeepSeek Harness` 进程。

```powershell
if (Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue) { '仍在运行' } else { '已关闭' }
```

**第 2 步：运行一键脚本**

打开 PowerShell（管理员），执行：

```powershell
powershell -ExecutionPolicy Bypass -File "D:\Users\deepseek-harness\default-workspace\DSH-Sandbox-Fix-Windows\scripts\DSH-沙箱修复-一键重打补丁.ps1"
```

> **脚本不再写死任何绝对路径**（2026-10 改版）。运行后它会依次询问三条路径 —— DSH 安装目录、支撑树目录、普通 node 运行时 —— 并把自动探测到的值作为默认值显示在提示里，**直接回车即采用默认值**。三项输入完会列出全部路径请你确认（输入 `Y` 开始，其它键取消）。
>
> 也可以完全跳开交互，用参数一次传齐：
>
> ```powershell
> powershell -ExecutionPolicy Bypass -File "…\DSH-沙箱修复-一键重打补丁.ps1" `
>     -InstallDir "D:\deepseek harness" `
>     -SupportTree "C:\Users\Administrator\.dsh\sandbox-support" `
>     -PlainNode "D:\deepseek harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe" `
>     -Yes
> ```
>
> 参数同样会做校验（目录下必须有 `resources\app.asar`、目标必须是 `node.exe`），不合法会直接报错退出而不是开始打补丁。

**第 3 步：确认输出**

期望看到：

```
[1/5] 应用已确认关闭，app.asar 可写
[2/5] 当前 app.asar SHA256：...
[3/5] 正在应用修复（解包支撑树 + 原地替换 runner）...
pristine runner source: ...\runner-pristine.js (explicit)
...
native binary OK: ...\koffi.node
extraction verified
OK: fix installed in place (archive size unchanged: 121348951 bytes)
[4/5] 校验通过：runner 与原生模块就位
[5/5] app.asar 已更新
```

**第 4 步：验证**

启动应用 → 切到 workspace-write → 执行 `echo hello` → 应返回 `hello`。再做一次越界写入测试（见第 7 节）。

### 5.3 脚本会自动做的事

1. 检查应用是否真的关闭（并实际尝试独占打开 `app.asar`，比进程检查更可靠）；
2. 从 `runner-pristine.js`（或 `app.asar.backup-gitfix`）取**原始** runner；
3. 把沙箱支撑树解包/更新到**你输入的支撑树目录**（本机为 `C:\Users\Administrator\.dsh\sandbox-support\`）；
4. 校验原生模块是有效 PE 二进制（`MZ` 头）—— 防止 asar 占位符覆盖真二进制；
5. 原地写入补丁（字节数不变），并保留：
   - `app.asar.backup-gitfix` —— **原始未修复**归档，永不覆盖；
   - `app.asar.pre-fix-<时间戳>` —— 每次更新后的回滚点；
6. 写入 `applied-version.txt` 留痕。

### 5.4 手动操作（脚本不可用时）

如果你更愿意手动，核心就是运行同一个补丁程序（下面这些绝对路径就是交互式提问时你会输入的内容，可按本机实际情况替换）：

```powershell
& "D:\deepseek harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe" `
  "D:\Users\deepseek-harness\default-workspace\DSH-Sandbox-Fix-Windows\scripts\dsh-install-fix2.mjs" `
  "D:\deepseek harness\resources\app.asar" `
  "C:\Users\Administrator\.dsh\sandbox-support" `
  "D:\deepseek harness\resources\runtime\primary-runtime\dependencies\node\bin\node.exe" `
  '""' `
  "D:\Users\deepseek-harness\default-workspace\DSH-Sandbox-Fix-Windows\scripts\runner-pristine.js"
```

参数含义（按顺序）：

| 位置 | 含义 |
|---|---|
| 1 | `app.asar` 路径 |
| 2 | 支撑树目录 |
| 3 | 普通 node 可执行文件路径 |
| 4 | 诊断日志路径（留空 = 关闭日志） |
| 5 | **原始 runner 文件路径**（可选；不传则从 `app.asar.backup-gitfix` 取） |

> 💡 **PowerShell 调用注意**：路径含空格，必须整体加引号；空的日志参数不能省略成裸空串，写 `'""'`（或省略第 4 个参数后多余参数不传）。上一节的一键脚本已经处理好这些细节，**优先用一键脚本**。

---

## 6. 更新后如何用 app.asar.fixed 直接替换

> ✅ **当前状态：`app.asar.fixed` 已创建。**
>
> ```
> D:\deepseek harness\resources\app.asar.fixed     115.7 MB
> SHA256 = CCED8AEBC364AFBF3D2618FAA35ADFC19C2DCD2AE67F64A71014D89FE389922E
> ```
>
> 该文件是**当前已修复的 `app.asar` 的完整副本**，两者 SHA256 一致。
>
> 如需重新生成（完全权限或系统 PowerShell，应用需先关闭）：
>
> ```powershell
> Copy-Item "D:\deepseek harness\resources\app.asar" "D:\deepseek harness\resources\app.asar.fixed" -Force
> ```

### 6.1 如何用 `.fixed` 替换（更新后）

```powershell
# 应用必须完全退出
Copy-Item "D:\deepseek harness\resources\app.asar.fixed" "D:\deepseek harness\resources\app.asar" -Force
```

**优点**：一条命令，几秒完成，不需要支撑树重建。
**缺点**：**版本绑定**。`app.asar.fixed` 只对应某个具体应用版本。更新后资源文件（HTML/JS/包）会变，用旧版 `.fixed` 覆盖新版会让应用**行为不一致甚至无法启动**。

### 6.2 推荐做法：把 `.fixed` 当"应急回滚"，不是常规修复手段

| 场景 | 用什么 |
|---|---|
| 更新后要恢复修复（**常规**） | **一键脚本**（第 5 节）—— 基于新版真实内容重打，永远正确 |
| 更新后应用起不来，想快速回到"能用"状态 | 把 `.fixed` **复制到别的盘**作为应急副本 |
| 想彻底回滚到修复前 | `app.asar.backup-gitfix`（第 9 节） |

### 6.3 强烈建议：把 `.fixed` 备份到其他盘

`D:\deepseek harness\resources\` 会在应用更新时被动到，`.fixed` 有丢失风险。建议：

```powershell
# 备份到别的盘（示例用 E:，按需改）
Copy-Item "D:\deepseek harness\resources\app.asar.fixed" "E:\dsh-backup\app.asar.fixed" -Force

# 同时备份支撑树（几百 MB，但重建要几分钟）
robocopy "C:\Users\Administrator\.dsh\sandbox-support" "E:\dsh-backup\sandbox-support" /MIR
```

**同时请备份这三个小文件**（它们才是真正的修复资产）：

```
D:\Users\deepseek-harness\default-workspace\DSH-Sandbox-Fix-Windows\scripts\runner-pristine.js
D:\Users\deepseek-harness\default-workspace\DSH-Sandbox-Fix-Windows\scripts\dsh-install-fix2.mjs
D:\Users\deepseek-harness\default-workspace\DSH-Sandbox-Fix-Windows\scripts\DSH-沙箱修复-一键重打补丁.ps1
```

有了这三个文件 + DSH 安装目录，**即使支撑树和 `.fixed` 全丢了也能重建修复**（脚本不依赖任何写死路径，换机器也能用）。

---

## 7. 验证修复是否生效

### 7.1 基本验证

切到 **workspace-write（沙箱内）**，执行：

```powershell
echo hello
```

应返回 `hello`。

### 7.2 确认沙箱仍在拦截（**重要**）

```powershell
# 1) 写入工作区外 —— 应被拒绝
try { Set-Content -Path 'D:\sandbox-escape.txt' -Value x -ErrorAction Stop; '越界成功(异常!)' } catch { '越界被拒绝(正常)' }

# 2) 写入工作区内 —— 应成功
Set-Content -Path 'D:\Users\deepseek-harness\default-workspace\probe.txt' -Value x
Test-Path 'D:\Users\deepseek-harness\default-workspace\probe.txt'
```

**期望**：越界被拒绝 + 工作区内成功。若越界写入成功 → 沙箱失效，**立即卸载修复**并回报。

### 7.3 本机已验证的结果（2026-10-02）

| 测试 | 结果 |
|---|---|
| `echo hello` | `hello` ✓ |
| `git --version` | `git version 2.56.0.windows.1` ✓ |
| 写入工作区外 | **拒绝访问** ✓ |
| 写入工作区内 | 成功 ✓ |
| 越界文件是否产生 | 不存在 ✓ |

---

## 8. 磁盘支撑树说明与清理

### 8.1 是什么

```
C:\Users\Administrator\.dsh\sandbox-support\
```

由一键脚本从 `app.asar` + `app.asar.unpacked` 解包出来的**沙箱程序及其依赖的真实文件系统副本**，约 **297 MB**。

**为什么需要它**：普通 node 运行时读不了 asar 内部的路径，而修复正是要让沙箱程序由普通 node 托管，所以必须有一份磁盘上的副本。

### 8.2 ⚠️ 清理注意事项

| 情况 | 能否删除 |
|---|---|
| 修复处于**启用**状态 | **绝对不能删**。删了沙箱内 shell 会立刻变回 `0xC0000142` |
| 已按第 9 节**卸载**修复（app.asar 已还原为原始版） | 可以删，此时它是无主残留 |
| 想重建 | 直接跑一键脚本，会自动重建 |

**删除命令**（仅在确认已卸载修复后）：

```powershell
Remove-Item "C:\Users\Administrator\.dsh\sandbox-support" -Recurse -Force
```

### 8.3 其他注意事项

- **不要把它移进工作区**。它必须留在工作区**之外** —— 沙箱不授予工作区外目录的写入权限，这样沙箱内的进程无法篡改它（若放在工作区内，沙箱内的进程可以改写沙箱自身的组件，等于自毁防线）。这一点是我在制作过程中一度搞错、后来改正的。
- **自动化清理工具**（如磁盘清理、某些"空间释放"软件）可能把它当垃圾删掉。若发现沙箱内 shell 突然失效，先检查这个目录是否还在。
- **路径中的用户名**：本机是 `Administrator`（`%USERPROFILE%\.dsh\sandbox-support`）。换用户配置时**不需要改脚本** —— 脚本没有写死路径，默认值就是当前用户的 `%USERPROFILE%\.dsh\sandbox-support`，也可以在提示里手动输入别的目录（或用 `-SupportTree` 参数）。
- 脚本会在其中写一个 `applied-version.txt` 留痕，记录了每次打补丁的时间与 asar 哈希。

---

## 9. 卸载 / 回滚

### 9.1 完全卸载（回到原始状态）

应用必须**完全退出**，然后：

```powershell
# 1) 还原原始 app.asar
Copy-Item "D:\deepseek harness\resources\app.asar.backup-gitfix" "D:\deepseek harness\resources\app.asar" -Force

# 2) 删除支撑树
Remove-Item "C:\Users\Administrator\.dsh\sandbox-support" -Recurse -Force
```

还原后：
- workspace-write 下 shell 会重新变成 `0xC0000142`（回到原始 bug）；
- danger-full-access 下 shell 正常。

### 9.2 回滚到"更新前的那一版"

如果一键脚本报告创建了 `app.asar.pre-fix-<时间戳>`，可以用它回退到打补丁之前的状态：

```powershell
Get-ChildItem "D:\deepseek harness\resources\app.asar.pre-fix-*" | Select-Object Name,LastWriteTime
Copy-Item "D:\deepseek harness\resources\app.asar.pre-fix-<填时间戳>" "D:\deepseek harness\resources\app.asar" -Force
```

---

## 10. 安全说明

**本修复不绕过沙箱。** 依据有三：

1. **代码层面**：只改了托管运行时，沙箱核心文件 `types-Cl_DXjhk.js`（受限制令牌创建、ACL 授予、Low 完整性标签、`CreateProcessAsUserW` 调用）**零改动**。
2. **行为层面**：修复后实测"写入工作区外"仍被**拒绝**（见 7.2 / 7.3）。
3. **审计层面**：逐行对比确认——原始 140 行中仅 1 行被改写，新增 15 行均为日志与重执行逻辑。

**残留风险（需知晓）**：

- 支撑树位于 `C:\Users\Administrator\.dsh\sandbox-support\`，属于**用户可写**目录。理论上能以该用户权限运行的进程（含未来可能被授予该目录写入权限的沙箱进程）可以篡改它。当前配置下沙箱不授予该路径写入，因此实际不可达。
- `app.asar` 本身是**安装目录内的已修改文件**。应用更新会覆盖它（这也是需要重打补丁的原因）。若有应用完整性校验（本版本未见），可能因此报错。
- 这是**本地临时修复，不是上游根治**。建议把本问题与证据反馈给 DSH 团队。

---

## 11. 文件清单

### 11.1 修复资产（**请备份这三个文件**）

**仓库形式**（三件套已按此结构放置，推荐以仓库为准）：

| 路径 | 说明 |
|---|---|
| `scripts/DSH-沙箱修复-一键重打补丁.ps1` | **一键重打补丁脚本**（更新后运行这个） |
| `scripts/dsh-install-fix2.mjs` | 实际执行打补丁的程序（被上面的 ps1 调用，必须与 ps1 同目录） |
| `scripts/runner-pristine.js` | **原始 runner 文件**（补丁的输入，7807 字节，务必保留） |

**本机实际位置**：

```
D:\Users\deepseek-harness\default-workspace\DSH-Sandbox-Fix-Windows\scripts\
```

> ⚠️ 这三个文件必须放在**同一目录**。脚本默认从自身所在目录查找另外两个文件。如果移动，请一起移动。
>
> 💡 编辑 `DSH-沙箱修复-一键重打补丁.ps1` 时**务必保留 UTF-8 BOM** —— Windows PowerShell 5.1 对无 BOM 的文件按 ANSI 解码，中文注释会解码错乱并导致语法错误无法运行。详见仓库 README 的说明。

### 11.2 运行时产物

| 路径 | 说明 |
|---|---|
| `D:\deepseek harness\resources\app.asar` | 已修复（原地打补丁，大小不变） |
| `D:\deepseek harness\resources\app.asar.backup-gitfix` | **原始**未修复归档（回滚用，勿删） |
| `D:\deepseek harness\resources\app.asar.fixed` | **待创建**（见第 6 节） |
| `C:\Users\Administrator\.dsh\sandbox-support\` | 沙箱支撑树，约 297 MB，**勿删** |

### 11.3 诊断与排查工具（可选保留）

| 路径 | 说明 |
|---|---|
| `fix\audit-patch.mjs` | 逐行对比补丁前后差异（审计用） |
| `fix\verify-fix.mjs` | 沙箱拦截行为验证 |
| `fix\01-extract.mjs` / `asar-extract.mjs` | asar 解包工具 |
| `fix\inspect-asar.mjs` / `show-entry.mjs` | asar 头部/条目查看 |
| `fix\02-inplace.mjs` / `dsh-fix-inplace.mjs` | 早期纯诊断版补丁工具 |
| `repro-*.mjs` | 根因定位时用的复现脚本 |
| `asar-full\` | 复现用的模块树（约 250 MB，**可删**） |

---

## 附：根因定位过程摘要（供上报上游）

1. **现象**：workspace-write 下所有命令 `0xC0000142`；完全权限下正常。
2. **排除**：Git 安装、代理、杀毒、环境变量、控制台、`windowsHide`、fd 布局、`DSH_SUBPROCESS_CONTROL` 通道、ACL/SID 状态、temp 目录 —— 逐个用对照实验排除。
3. **突破**：在 `app.asar` 内的沙箱 runner 植入诊断日志，读取真实 argv 与退出码 → 确认参数正确、失败发生在 `sandbox.spawn()` 之后。
4. **定位**：搭建忠实复现环境（真实 fd 4/5/6/7 + harness 自己的 `spawnCurrentTokenJobProcess` 原语），二分出**唯一变量是托管运行时**：
   - 普通 `node.exe` → exit 0
   - `DeepSeek Harness.exe`（Electron-as-node）→ `0xC0000142`
5. **修复**：让 runner 在 Electron 宿主下改用普通 node 从磁盘副本重执行自己。
6. **验证**：shell 恢复 + 越界写入仍被拒绝。

**给上游的最小复现要点**：在 Electron-as-node 进程内用 `@deepseek-ai/dsh-win32-process` 的 `spawnCurrentTokenJobProcess` 启动 `@deepseek-ai/dsh-sandbox-windows-acl/lib/runner.js`，令其以 `workspace-write` 模式创建受限制子进程 → 子进程 `STATUS_DLL_INIT_FAILED`。同样的调用在普通 node 宿主下正常。
