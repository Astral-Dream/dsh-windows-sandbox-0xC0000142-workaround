# DSH Windows Sandbox Fix (0xC0000142)

> **⚠️ 免责声明：本仓库非官方项目。我们不对修复代码的最终效果负责。如果在使用本脚本时遇到任何报错或异常，请将本仓库的《交接文档》以及全部修复资产文件提供给 DeepSeek Harness（dsh），让它尝试进行自我修复。**

## 🌟 项目背景

本项目源于一次“AI 修 AI”的奇妙旅程。在 Windows 环境下使用 DeepSeek Harness 桌面版时，如果在 `workspace-write`（沙箱内）模式下执行命令，会遭遇 `0xC0000142` (`STATUS_DLL_INIT_FAILED`) 错误，导致所有 shell 命令静默失败。

**在这个过程中，我全程使用 DeepSeek 来排查和修复 DeepSeek Harness 本身。** 经历数小时的反复、排查、走弯路以及 1.5 元的真金白银花费后，dsh 成功找到了根因并写出了修复补丁。

为了让遇到相同问题的朋友不再重复造轮子，我将排查过程中产出的《交接文档》、诊断脚本和一键重打补丁脚本整理开源。

## 🐛 问题现象与根因

- **现象**：Windows 下，沙箱模式 (`workspace-write`) 任何命令退出码均为 `3221225794` (`0xC0000142`)。完全权限下一切正常。
- **根因**：DSH 在 Windows 上用受限制令牌实现沙箱。当宿主是 `Electron-as-node` (即 DSH 主进程) 时，受限制子进程会在 DLL 初始化阶段死亡。普通 Node 宿主则完全正常。
- **修复原理**：在 asar 内的沙箱启动程序处加入判断。如果检测到 Electron 宿主，则用 DSH 自带的普通 Node 运行时，从真实文件系统副本重新执行自己。**这没有绕过沙箱，底层 ACL 与完整性标签均未改动。**

> 详细排查过程与技术细节，请参阅 `docs/DSH-Windows沙箱修复-交接文档.md`。

## 🚀 如何使用本仓库（修复步骤）

### 前置条件
1. 确保你有管理员权限。
2. **完全退出** DeepSeek Harness 应用（包括系统托盘图标）。
3. **务必在“完全权限（danger-full-access）”模式或系统 PowerShell 中操作**（因为脚本要写入沙箱之外）。

### 操作步骤
1. 克隆或下载本仓库到本地。
2. 将 `scripts/` 目录下的三个文件（`runner-pristine.js`、`dsh-install-fix2.mjs`、`DSH-沙箱修复-一键重打补丁.ps1`）放到**同一个文件夹**中。
3. 以管理员身份打开 PowerShell。
4. 执行一键脚本：
   ```powershell
   powershell -ExecutionPolicy Bypass -File "你的路径\scripts\DSH-沙箱修复-一键重打补丁.ps1"
   ```
5. 等待脚本执行完毕，看到 `OK: fix installed in place` 即可。
6. 启动 DSH，切换到沙箱模式（workspace-write），执行 `echo hello`，若返回 `hello` 则说明修复成功！

### 验证沙箱是否依然有效（重要！）
修复后，务必在沙箱内尝试越界写入，确保安全拦截依然生效：
```powershell
# 应在沙箱内被拒绝访问
Set-Content -Path 'D:\sandbox-escape.txt' -Value x
```
如果越界写入成功，请**立即停止使用本修复**，并回滚。

## 📦 文件清单说明

- `docs/DSH-Windows沙箱修复-交接文档.md`：完整的背景、根因分析、修改细节及排障过程。
- `scripts/runner-pristine.js`：原始未修改的 runner 文件（补丁的输入）。
- `scripts/dsh-install-fix2.mjs`：实际执行打补丁的程序。
- `scripts/DSH-沙箱修复-一键重打补丁.ps1`：一键自动化重打补丁脚本（应用更新后重新运行这个即可）。

## 🔄 更新与回滚
- **应用自动更新**：DSH 一旦更新，`app.asar` 会被替换，修复失效。重新运行 `DSH-沙箱修复-一键重打补丁.ps1` 即可。
- **彻底回滚**：使用 `app.asar.backup-gitfix` 还原，并删除 `C:\Users\<你的用户名>\.dsh\sandbox-support` 目录。

## 💬 相关 Issue
GitHub Issue 讨论：[deepseek-ai/deepseek-harness#8170](https://github.com/deepseek-ai/deepseek-harness/issues/8170)
