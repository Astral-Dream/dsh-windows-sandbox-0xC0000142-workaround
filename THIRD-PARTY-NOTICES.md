# 第三方代码与来源声明（Third-Party Notices）

本仓库**自己写的部分**（`README.md`、`docs/`、`scripts/DSH-沙箱修复-一键重打补丁.ps1`、`scripts/dsh-install-fix2.mjs`）按 [LICENSE](LICENSE) 提供 —— **MIT-0，不要求任何署名，你可以随便用、随便改、随便再发布**。

但仓库里**含有一份别人写的原始代码**，它的版权属于原作者，**不会因为本仓库换成 MIT-0 而改变**。这份声明就是为了把这个来源补清楚。

---

## 1. `scripts/runner-pristine.js`

| 项目 | 内容 |
|---|---|
| 来源 | `@deepseek-ai/dsh-sandbox-windows-acl@0.2.0-rc.2` 包内的 `lib/runner.js` |
| 取得方式 | 从 DSH 安装目录的 `app.asar` 中逐字提取 |
| 是否修改 | **未做任何修改**（7807 字节，原样保留） |
| 用途 | 作为打补丁程序的**输入**（补丁需要原始字节才能原地替换且保持归档大小不变） |
| 版权 | **Copyright (c) 2026 DeepSeek** |
| 许可证 | **MIT** |

其许可证原文如下（原样保留）：

```
MIT License

Copyright (c) 2026 DeepSeek

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

---

## 2. 补丁生成物（不会随本仓库分发）

`scripts/dsh-install-fix2.mjs` 在**你自己机器上**读取上面那份原始文件，去掉注释、插入"Electron 宿主下用普通 node 重执行"的逻辑，然后把结果**原地写回你本机的 `app.asar`**（字节数不变）。

- 这属于对**你自己安装的副本**做本地修改，修改结果只存在你的机器上，**本仓库不分发它**；
- 注入的代码里没有引入任何其它第三方代码；
- 沙箱核心文件（受限制令牌、ACL、完整性标签、`CreateProcessAsUserW`）未被改动（见 [docs/DSH-Windows沙箱修复-交接文档.md](docs/DSH-Windows沙箱修复-交接文档.md) 第 10 节）。

---

## 3. 商标与非官方声明

- 本项目是**非官方**的本地修复，与 DeepSeek **没有任何隶属、赞助或背书关系**。
- "DeepSeek Harness" 及相关名称、标识归其权利人所有；本仓库的许可证**不授予任何商标权**。
- 本工具**仅用于对你合法取得的 DSH 副本做本机修复**。修改安装目录内的文件是否违反你所在地区的法律或 DSH 的使用条款，需要**你自行评估**。
