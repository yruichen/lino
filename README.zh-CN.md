<p align="center"><img src="docs/assets/overview.svg" alt="open-typora 编辑器架构概览" width="960"></p>

# open-typora

**从敲下一个字符，到保存一份 Markdown，中间发生了什么？**

这个仓库把 Typora 的编辑器拆成可以查证的结构：文档节点、实时渲染、选区、撤销、源码模式，以及 JavaScript 和 Mac 原生层之间的通信。每个结论尽量附上模块、位置、方法地址和仍未知的部分。

**[在线阅读报告 →](https://yruichen.github.io/open-typora/)** · [English](README.md) · [证据索引](data/) · [本地复现](docs/reproduce.md)

## 最值得看的五个发现

1. **可视化编辑依赖文档树。** Markdown、DOM、光标和撤销围绕节点模型协作，实时渲染只是其中一环。
2. **这份 Mac 样本使用 Cocoa 和 WebKit。** 共享代码里的 Node/Electron 分支，不能直接当作 Mac 实现。
3. **快速打开和全文搜索走不同系统。** 前者使用 `NSMetadataQuery`，后者启动包内 `rg` 并处理输出。
4. **导出接口的名字不能说明通信方向。** `export.exportToNative` 是原生调用 JavaScript 的处理器；Pandoc、HTML、PDF 和打印各有路径。
5. **切换源码模式会切换编辑机制。** 源码模式读取 CodeMirror，可视化模式序列化节点树，撤销也分别处理。

## 已经画出的地图

| 静态索引范围 | 数量 |
| --- | ---: |
| 主编辑器 System 模块 | **83** |
| 原生定义类 | **98** |
| 原生方法实现记录 | **2,017** |
| JavaScript 字面量桥接位置 | **193** |
| 找到原生相反方向端点的 JS 位置 | **182** |
| 安装包普通文件清单 | **693** |

这些数字表示索引范围，不表示全部功能已运行验证。字面量端点配对也不证明实际执行。

## 怎么读

- 想了解整体：先打开[交互式报告](https://yruichen.github.io/open-typora/)。
- 想定位代码：[模块表](data/modules.json)和[桥接配对](data/bridges.json)。
- 想研究编辑器：[编辑器发现](data/editor-findings.json)。
- 想研究系统集成：[原生发现](data/native-findings.json)与[方法表](data/native-methods.json)。
- 想验证结论：[研究方法](docs/methodology.md)与[复现指南](docs/reproduce.md)。

阅读报告不需要安装 Typora：

```bash
git clone https://github.com/yruichen/open-typora.git
cd open-typora
python3 -m http.server 8765 --bind 127.0.0.1
```

浏览器打开 **http://127.0.0.1:8765/docs/**。报告是静态文件，筛选在本地运行，没有统计追踪。

修改报告后，用 Node.js 24.11 或更新版本构建与核对：

```bash
npm ci
npm run build
npm run check
```

## 样本和边界

当前样本是 **Typora 1.9.4，build 7260，macOS**，原生方法体分析聚焦 **arm64**。该样本代码签名验证失败，未建立与官方发布包的对应关系；结论绑定记录中的哈希。

83 个主 bundle 注册模块已完成静态索引。原生结论来自元数据、汇编和字面量关联。Hopper 桥接启动阻塞了深度反编译，运行行为等价仍未验证。报告保留了这些缺口。

仓库公开原创分析、复现工具和经整理的事实索引。原应用、完整打包源码、整份反汇编、激活材料和个人文档不随仓库发布。项目独立于 Typora 官方；[NOTICE.md](NOTICE.md)说明许可范围。

## 一起补全地图

欢迎对照官方样本、补充受控行为测试、解析未匹配接口、比较新版本或翻译报告。请附上样本哈希、准确位置以及观察与推断的区分，详见[贡献指南](CONTRIBUTING.md)。

## Acknowledgements

本次调查使用了 **[REA — Reverse Engineer Anything](https://github.com/morluto/rea)** 的本地应用分析、Mach-O 检查和结构化证据工作流。感谢 REA 的贡献者，让借助 agent 的逆向研究更容易检查与复现。
