<div align="center">

# open-typora

**专注落笔，让 Markdown 回归写作。**

一个围绕本地文件打造的开源 Markdown 编辑器：macOS 原生外壳，Rust 共享核心。

[![Version](https://img.shields.io/badge/v0.0.1-Beta-ef9f43)](https://github.com/yruichen/open-typora/releases/tag/v0.0.1)
[![Platform](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-555555)](https://github.com/yruichen/open-typora/releases/tag/v0.0.1)
[![License: MIT](https://img.shields.io/badge/License-MIT-3b82f6)](LICENSE)

[**下载 macOS 版本**](https://github.com/yruichen/open-typora/releases/tag/v0.0.1) · [反馈问题](https://github.com/yruichen/open-typora/issues) · [English](README.md)

</div>

## 给文字一个熟悉的落脚点

open-typora 受 Typora 的写作体验启发，希望做一个专注、轻量、融入 macOS 的 Markdown 编辑器。

- **文件始终是 Markdown。** 打开 `.md`，写作，保存回磁盘，不引入专有文档格式。
- **窗口交给 Mac。** AppKit 提供窗口、菜单、工具栏和文件对话框；CodeMirror 6 在系统 WKWebView 中负责编辑。
- **共同能力交给 Rust。** 文档模型、文件操作与应用服务按明确的平台边界组织。macOS 优先交付，Windows 和 Linux 宿主留待后续实现。

轻量化是设计目标，目前尚未发布性能基准。

## 现在可以做什么

| 写作 | 导航 | 留住你的工作 |
| --- | --- | --- |
| 源码与视觉编辑模式 | 文档内查找替换 | 打开与保存 UTF-8 Markdown |
| 两种模式共用撤销与重做历史 | 跳转到指定行 | 本地恢复副本 |
| 基础 Markdown 格式操作与表格编辑 | 原生菜单与键盘快捷键 | 可选的已命名文件自动保存 |
| 英语与简体中文界面 | **⌘/** 切换编辑模式 | 外部修改检测 |

> **v0.0.1 是早期 Beta。** 目前尚不能完整替代 Typora。完整 Markdown 呈现、图片、公式、图表与高级导出仍未完成；原生交互、无障碍和平台兼容性也需要更广泛的验证。

## 试用 Beta

1. [下载 macOS 版本](https://github.com/yruichen/open-typora/releases/tag/v0.0.1)，需要 **Apple Silicon 芯片与 macOS 14 或更新版本**。
2. 解压，将 **OpenTypora.app** 移到**应用程序**目录。
3. 打开一个 Markdown 文件，开始写作。

当前 Beta 采用临时签名，**尚未经过 Apple 公证**；macOS 可能要求明确的安全许可才能打开。

| 操作 | 快捷键 |
| --- | --- |
| 打开文件 | ⌘O |
| 保存 / 另存为 | ⌘S / ⇧⌘S |
| 切换编辑模式 | ⌘/ |

界面语言位于 **Open Typora → 设置… → 通用 → 语言**。

当前支持不超过 64 MiB 的普通 UTF-8 文件，保留 BOM 和混合换行。恢复副本以未保存文档打开，无法恢复尚未持久化的输入。

## 从源码构建

依赖：运行 macOS 14 或更新版本的 Apple Silicon Mac、包含 Swift 6 的 Xcode、Rust/Cargo，以及 Node.js 24.11 或更新版本和 npm。

```bash
git clone https://github.com/yruichen/open-typora.git
cd open-typora
npm ci
npm run app:build
open .local/build/OpenTypora.app
```

构建会生成 Swift 绑定并将编辑器打包进应用。构建后的应用无需 Node.js 或开发服务器。重新构建前请退出应用；构建成功后会在同一路径替换上一份应用。

## 项目内部

| 目录 | 职责 |
| --- | --- |
| `apps/macos/` | AppKit 窗口、菜单、对话框与 WebView 宿主 |
| `packages/editor/` | 编辑、选区、历史与 Markdown 呈现 |
| `packages/protocol/` | 编辑器与宿主之间的协议客户端和传输 |
| `crates/` | Rust 文档模型、用例、I/O、运行时与 Swift 绑定 |
| `tests/` | 共享测试夹具与集成检查 |
| `tools/` | 构建工具、代码生成与检查 |

欢迎试用 Beta、[提交可复现的问题](https://github.com/yruichen/open-typora/issues)，或贡献一个聚焦的修复。反馈编辑问题时，请附上 macOS 版本与最小示例文档。如果你也期待这样的编辑器，点一颗 Star，让更多人发现它。

## 许可与致谢

原创成果采用 [MIT](LICENSE) 许可。本项目独立于 Typora 及其开发者，署名与许可范围见 [NOTICE.md](NOTICE.md)。

感谢 [REA — Reverse Engineer Anything](https://github.com/morluto/rea) 提供应用分析工具与工作流。
