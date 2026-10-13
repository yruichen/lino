<div align="center">

<img src="assets/brand/lino.png" alt="Lino 折纸 L 标志" width="96">

# Lino

**给文字一个安静的落脚点。**

macOS 原生外壳、Rust 共享核心的开源 Markdown 编辑器。写一篇笔记，讲清一个想法，让代码、公式和图表与文字放在同一份文档里。

[![Version](https://img.shields.io/badge/v0.0.2-Beta-ef9f43)](https://github.com/yruichen/lino/releases/tag/v0.0.2)
[![Platform](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-555555)](https://github.com/yruichen/lino/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-3b82f6)](LICENSE)

[**下载 macOS 版本**](https://github.com/yruichen/lino/releases/tag/v0.0.2) · [从源码构建](#从源码构建) · [English](README.md)

</div>

<p align="center">
  <img src="assets/screenshots/writing.png" alt="Lino 在 macOS 中展示英文文案与本地插图" width="48%">
  <img src="assets/screenshots/code-and-math.png" alt="Lino 的 Rust 代码高亮、行内公式与块公式预览" width="48%">
</p>

## 给想法留一点空间

从一句话开始，让想法慢慢展开。Lino 把你的写作留在普通 Markdown 文件里，提供专注的编辑区，以及熟悉的 Mac 窗口、菜单与快捷键。

- **文件属于你。** 打开 `.md`，写作，再保存回磁盘；内容可以自由带走。
- **思路留在段落里。** 视觉编辑、清晰的代码块、可编辑表格和公式预览与正文相伴。用 **⌘/** 查看原始标记，两种模式共用撤销历史。
- **融入 Mac 的日常。** 原生窗口标签页、菜单、文件对话框与搜索控件围绕编辑区，编辑区使用 macOS 提供的 WebKit 引擎。

可以打开[英文展示样稿](examples/showcase/Lino-Showcase.md)，并保留旁边的图片目录，体验原创文案、Rust 示例、表格、公式与 Mermaid 图表。

## v0.0.2 可以做什么

| 写下文字 | 表达想法 | 留住文件 |
| --- | --- | --- |
| 视觉与源码编辑，共用撤销历史 | 代码高亮与语言选择 | 打开、保存与另存为 |
| 标题、列表、任务清单与表格编辑 | 本地图片与引用链接 | 原生文档窗口与标签页 |
| 查找替换，支持正则表达式 | KaTeX 行内与块公式 | 可选自动保存与本地恢复副本 |
| 大纲、专注模式与阅读统计 | Mermaid 图表与独立 HTML 导出 | 外部修改检测与只读处理 |

界面支持**英语和简体中文**，macOS PDF 与打印也已提供测试入口。

**v0.0.2 是基础可用的 Markdown 编辑器，仍处于 Beta。** 更广泛的 Markdown 兼容、无障碍、原生交互与打印排版需要继续验证。响应速度和较小的运行时是设计目标，目前尚未发布性能对比；Windows、Linux 与更多文档格式留待后续实现。

## 获取 Lino

1. [下载 Lino v0.0.2](https://github.com/yruichen/lino/releases/download/v0.0.2/Lino-v0.0.2-macos-arm64.zip)，需要 **Apple Silicon 芯片与 macOS 14 或更新版本**。
2. 解压，将 **Lino.app** 移到**应用程序**目录。
3. 打开一个 Markdown 文件，开始写作。

校验值与发行说明见 [v0.0.2 发布页](https://github.com/yruichen/lino/releases/tag/v0.0.2)。Lino 原名 Open Typora，已有恢复数据仍保留原来的存放位置。

当前 Beta 采用临时签名，**尚未经过 Apple 公证**；macOS 可能要求明确的安全许可才能打开。

| 操作 | 快捷键 |
| --- | --- |
| 打开文件 | ⌘O |
| 保存 / 另存为 | ⌘S / ⇧⌘S |
| 查找 / 下一个匹配 | ⌘F / ⌘G |
| 切换编辑模式 | ⌘/ |
| 放大 / 缩小 / 重置 | ⌘+ / ⌘− / ⌘0 |

界面语言位于 **Lino → 设置… → 通用 → 语言**（**⌘,**）。

当前支持不超过 64 MiB 的普通 UTF-8 文件，保留 BOM 和混合换行。恢复副本以未保存文档打开，无法恢复尚未持久化的输入。

## 从源码构建

依赖：运行 macOS 14 或更新版本的 Apple Silicon Mac、包含 Swift 6 的 Xcode、Rust/Cargo，以及 Node.js 24.11 或更新版本和 npm。

```bash
git clone https://github.com/yruichen/lino.git
cd lino
npm ci
npm run app:build
open .local/build/Lino.app
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
| `assets/` | 共用品牌图形与产品截图 |

欢迎试用 Beta、[提交可复现的问题](https://github.com/yruichen/lino/issues)，或贡献一个聚焦的修复。反馈编辑问题时，请附上 macOS 版本与最小示例文档。如果你也期待这样的编辑器，点一颗 Star，让更多人发现它。

## 许可与致谢

原创成果采用 [MIT](LICENSE) 许可。本项目独立于 Typora 及其开发者，署名与许可范围见 [NOTICE.md](NOTICE.md)。

感谢 [REA — Reverse Engineer Anything](https://github.com/morluto/rea) 提供应用分析工具与工作流。
