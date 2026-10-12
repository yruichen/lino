# Typora 1.9.4 逆向分析报告

分析对象：本机安装样本。日期：2026 年 10 月 12 日。状态：全面静态调查，原生反编译和运行验证仍有缺口。

## 结论与样本范围

这份样本的 Mac 端由 Cocoa 和 NSDocument 原生层、WebKit 页面以及 JavaScript 编辑器组成。编辑器并非只有一个 Markdown 转 HTML 函数，而是节点模型、解析器、DOM 渲染、选区、撤销、异步刷队列和平台桥接共同工作。

目标是本机 `$APP`，版本 1.9.4，build 7260。报告覆盖打包资源、主编辑器全部 83 个 System 注册模块的静态清单、主要功能链路、主程序 arm64 的 Objective-C 元数据和汇编，以及 libTypora.dylib 的静态头部与代码。

这是对安装产物的全面静态分析报告，不是原始源码工程恢复，也不是全功能运行验证。Hopper 的 REA 桥接未就绪，未取得可信的原生反编译伪代码；原生结论来自 REA Mach-O 检查、Objective-C 元数据、原始字节与带地址汇编。

本机 codesign --verify --deep --strict 返回 invalid signature (code or signature have been modified)，arm64 签名无效。签名显示 Info.plist=not bound、TeamIdentifier=not set。无法确认修改来源；以下结论只绑定这份样本的哈希，不代表官方原版全部行为。

## 覆盖情况

| 范围 | 结果 | 仍未建立 |
| --- | --- | --- |
| 应用文件清单 | 693 个普通文件，11 个符号链接；逐文件 SHA-256 | 未与官方同版本发布包对照 |
| 主编辑器模块 | 83 个 System 注册模块完整静态清单 | 运行时完整调用图、每个接口行为等价 |
| REA JavaScript 扫描 | 199 个相关文件，31 个 JavaScript 文件；保留 Evidence | 1 GB 和 2 GB 分析中 main.js 语义堆耗尽；REA 关系图部分覆盖 |
| 主编辑器桥接 | 193 个字面量调用位置，另列动态表达式 | 动态名称和实际注册可达性 |
| 主程序原生元数据 | 98 个定义类，2017 个不同实现记录 | 协议声明与方法实现分开；不能从接口存在推断已执行 |
| 主程序 arm64 汇编 | 130498 条指令，2608 个标签；225 处保守字面量桥接位置 | 标签并非经验证完整函数体；Objective-C 接收者并非全部唯一 |
| JavaScript 与原生配对 | 182/193 个 JS 字面量位置找到相反方向原生端点 | 未匹配不等于功能不存在；同步调用和动态构造另走分派 |
| 原生 x86_64 | 架构与加载信息清单 | 未做该架构方法体分析 |
| 运行验证 | 未执行 Typora 业务代码，未访问个人笔记 | IME 时序、光标、边界 Markdown、实际磁盘与网络效果 |

## 应用目录与入口

| 路径 | 职责与证据 |
| --- | --- |
| Contents/MacOS/Typora | 双架构 Mach-O 主程序；arm64 可见 Document、TyWindowController、CommandBridge 等类 |
| Contents/Resources/TypeMark/index.html | 主编辑器 HTML，初始化 WebKit 桥接和主题 CSS，加载 appsrc/main.js |
| Contents/Resources/TypeMark/appsrc/main.js | 约 1.63 MB 主 bundle，83 个 System 模块，系统适配与编辑器业务共存 |
| Contents/Resources/TypeMark/appsrc/finder-worker.js | Node 平台文件查询 worker；存在于包中，不证明本 Mac 分支使用 |
| Contents/Resources/TypeMark/page-dist | 偏好、欢迎、许可证与本地设置辅助页面和 Webpack chunk |
| Contents/Resources/TypeMark/lib | MathJax、CodeMirror modes、Mermaid、ZenUML，以及 arm/x64 ripgrep |
| Contents/Resources/TypeMark/style | 基础编辑器样式、Mac 适配、图标和内置主题资源 |
| Contents/Resources/Base.lproj 与语言目录 | 原生编译界面、菜单和本地化；Web 本地化有 39 个目录（包含 Base） |
| Contents/Frameworks | Sentry、SentryPrivate、Sparkle 与 libTypora.dylib；名称不能证明来源或所有运行用途 |

## 整体数据流

打开文档的原生入口是 NSDocument 体系。WebKit 接收文件内容后，由 File 和 Editor 协调解析；MarkParser 产生结构，NodeDef 与 NodeMap 保存父子关系和节点身份；Node2HTML 生成带 cid、mdtype 和 contenteditable 的 DOM。

可视化编辑将输入映射回节点，UndoManager 保存可逆操作，Brush 队列协调后续刷新。保存时 Editor.getMarkdown 从 NodeMap.toMark 生成 Markdown；源码模式则直接读取 CodeMirror。原生 Document 收取内容、转换为 NSData，再由文档保存体系写出。

系统菜单、文件操作、搜索进程、图片处理、导出和系统拼写跨越 JavaScript 与原生层；主编辑器使用 _bridge，偏好页面另外使用 _setting。

## 核心模块定位

模块 ID 与范围来自 inert Babel AST，只解析打包文本，没有运行 System bootstrap。根模块中的未压缩导入别名提供高可信的组件身份；其余名称按接口推断，modules.json 为每个名称保留依据与置信级别。完整 83 模块表见附录和 modules.csv。

| 模块 ID | 恢复身份 | 主要位置与证据 |
| --- | --- | --- |
| 3c | File lifecycle/controller | main.js 字符 269056–294228；根导入别名 File |
| 5c | Editor composition/root controller | main.js 字符 1550596–1619222；根导入别名 无 |
| 19 | Markdown block parser | main.js 字符 865354–913511；根导入别名 MarkParser |
| 13 | Node/NodeMap document model | main.js 字符 1188563–1204054；根导入别名 NodeDef |
| 12 | Node to Markdown serializer | main.js 字符 24866–35617；根导入别名 Node2Mark |
| 14 | Node to HTML renderer | main.js 字符 35618–43304；根导入别名 Node2HTML |
| 30 | inline HTML decoration | main.js 字符 766219–790831；根导入别名 无 |
| 2a | asynchronous Brush parsing/reconciliation queue | main.js 字符 116354–131304；根导入别名 Brush |
| 31 | selection/cursor controller | main.js 字符 515401–569313；根导入别名 Selection |
| 1b | undo command/snapshot manager | main.js 字符 1121412–1140103；根导入别名 UndoManager |
| 48 | source Markdown CodeMirror view | main.js 字符 394472–407632；根导入别名 SourceView |
| 18 | fenced code CodeMirror controller | main.js 字符 77236–110248；根导入别名 Fences |
| 1c | math block editing/render | main.js 字符 1094169–1111999；根导入别名 MathBlock |
| 27 | inline math rendering | main.js 字符 110249–116353；根导入别名 MathInline |
| 15 | diagram controller | main.js 字符 1112000–1121411；根导入别名 无 |
| 55 | table controller | main.js 字符 720207–752558；根导入别名 TableEdit |
| 3f | document search and replace | main.js 字符 301217–322012；根导入别名 SearchPanel |
| 3e | HTML-to-Markdown model parsing/reconciliation | main.js 字符 1163184–1180270；根导入别名 无 |
| 29 | media/clipboard/export helpers | main.js 字符 1180271–1188562；根导入别名 MediaOp |
| 45 | export orchestrator | main.js 字符 361444–392587；根导入别名 Export |
| 4a | quick-open | main.js 字符 413618–424924；根导入别名 QuickOpenPanel |

## 解析与实时编辑

19 号模块包含块级解析和 InlineLexer。13 号模块保存可变节点树；14 号模块输出 HTML，12 号模块输出 Markdown，30 号模块处理行内 HTML 装饰。这种双向转换使可视化页面与文本保存保持相互关联。

5c Editor.simpleParse 对 paragraph/raw_edit 等条件进行局部解析：暂停 Brush，保存撤销状态，调用 Node.parseFrom，返回新节点与 HTML，再恢复队列。不能把这个局部路径概括成每次输入都重绘整篇文档。

2a Brush 初始化 200 ms 刷队列，在 IME 输入或鼠标按压期间抑制执行；输入与 composition 事件控制位于根 Editor 模块。静态分支表明代码中存在这条路径，未建立实际输入法事件顺序或最大延迟。

3e 中有 DOM 与模型协调、验证和修复操作。其存在不能证明所有 Markdown 方言或剪贴板输入都能无损往返。证据索引：editor-findings.json 中 model、markdown-output、parser、brush、simple-parse、reconcile 等条目。

## 选区撤销和源码模式

31 Selection 管理光标与 range。1b UndoManager 保存 commandStack 与当前 index，执行操作特定的恢复逻辑；撤销后同步节点、刷新统计、恢复焦点并调整滚动。进入源码模式后 undo/redo 转交 CodeMirror。

48 SourceView 在显示时设置 CodeMirror 文本，并缓存可视化状态。退出已修改的源码模式时调用 File.reloadContent(cm.getValue(...))；未发生修改时可以复用缓存 HTML。

Editor.getMarkdown 明确区分源码模式的 cm.getValue 与可视化模式的 nodeMap.toMark，并处理最终换行。源模式和可视化模式的历史并非同一个简单文本栈。

跨窗口同步由 document.syncChangeIfNeeded 承接序列化改动；回调条件可安排 500 ms 后全量同步。接收端 editor.applyChange/applyFullContent 复用 undo 命令机制，并且包含窗口活跃状态判断。

## 表格代码公式图表与大纲

| 子系统 | 静态实现 |
| --- | --- |
| 表格 | 55 TableEdit 对行列增删、移动和单元格操作修改节点；12 序列化对齐分隔行 |
| 代码块 | 18 Fences 将 CodeMirror.getValue 同步到节点 text；语言模式与扩展按需加载 |
| 数学公式 | 27 行内数学调用 MathJax.tex2svgPromise；1c 管理块级数学源码、标签、缓存和重渲染 |
| 图表 | 15 按需加载 diagram、Mermaid 和 ZenUML；updateDiagram 依源码与选项分派渲染 |
| HTML 块 | 17 管理源码编辑、DOM 刷新与消息；实际资源加载效果未执行验证 |
| 大纲 | nodeMap.toc.headers 提供标题层级与 cid；getHeaderMatrix 供大纲和 PDF 标题结构使用 |
| 字数和阅读时间 | 遍历写作区节点并特殊处理 CodeMirror 内容；requestIdleCallback 延迟统计，阅读时间依 wordsPerMinute |
| 拼写 | word.getSpellSuggestionInContext、word.getTextReplacement 将系统服务调用交原生 |

## 文档读写快照与恢复

主程序定义 Document 与 DocumentCommands。Document.readFromData:ofType:error: 调用 stringFromData:；dataOfType:error: 调用 dataUsingEncoding:；writeToURL:ofType:error: 调用 NSDocument 的父类实现。因此保存写出依赖 Cocoa 文档体系，不能只凭这个短 wrapper 声称自定义原子保存算法。

Document.syncToSelf 的汇编调用 File.getContent 桥接并有运行循环等待逻辑，随后可执行 File.markSaved。JavaScript 的 File.getContent 验证保存内容并同步状态；原生磁盘刷新和多个窗口内容协调是独立步骤。

readFromURL 包含按文件扩展名检查 Pandoc 导入格式的路径，验证安装后调用 importFile:toDocument:。普通 Markdown 与其他导入格式不能混成同一条读取链。

快照保存 nodeMap、undoRedo、cursorPos、scrollOffset、content、bundle 和换行状态，源码模式还保存 srcHist。原生有 DocumentSnap、requestBuildSnap 和 buildDocumentSnap 接口。所有恢复条件、磁盘备份生命周期和异常路径尚未形成完整行为证明。

## 文件库与两种搜索

快速打开的 JS 4a 模块发送 quickOpen.query。QuickOpenCommands.setup 在 0x100004470 注册同名字面量；query: 在 0x100004dbc 调用 buildPredicateQueryFrom:、calcSearchingScopeFromURL、setSearchScopes:、setPredicate: 和 startQuery。setup 创建 NSMetadataQuery。结果通过 quickOpen.updateResult 和 initFileCache 等接口返回。

这条链支持 Mac 使用系统元数据查询与缓存的静态解释；listAllFileByEnum 和 cacheRecentFiles 是另外可见分支。排序细节、索引一致性和每个条件的实际触发未运行验证。包内 finder-worker 属于 Node 分支，不能用它解释 Mac 的全部快速打开行为。

文件夹全文搜索由前端 searchByMac/buildRpArgs 组织选项，经 library.search 交原生。LibraryCommands.setup 在 0x100050f30 注册该入口。TyWindowController(Search).prepTask: 根据 isARMCPU 选择 TypeMark/lib/bin/arm/rg 或 x64/rg，构造参数并调用任务 launch:；结果回调使用 globalSearch.onSearchUpdate。

前端参数含 -F、--json、--no-multiline、-n、-m 21、--max-filesize 2M、-g !.* 和 --no-messages，大小写、整词和正则选项调整参数。这些是可见默认构造，不能从此推断所有配置下参数相同。

文件树、列表和目录操作通过 library.listDocsUnder、fetchAllDocs、newFile、newFolder、renameFile、moveFile、trashItem 等桥接；原生的根目录变化和文件变化事件回到 JS 刷新列表。删除与改名代码仅静态读取，没有执行。

## 导出打印与外部转换

export.exportToNative 是 JS 注册的处理器，方向为原生到 JavaScript。TyWindowController(Export) 的 Pandoc 回调在 0x100072b38 调用同名桥接，从节点模型取得中间格式，再由原生执行转换。此前若把名字理解成 JS 调用原生导出入口，会把链路方向写反。

PandocBridge.prepPandocTask 设置 launchPath、arguments、标准输出和错误管道；原生有检测 Pandoc 路径、版本、导入和任务完成处理。HTML/PDF 导出还有独立入口，不应全部归为 Pandoc。

HTML 路径调用 export.exportToHTML；PDF/打印路径调用 export.dataForExport，生成 HTML、标题、页眉页脚和相关选项后交给 WebKit 与打印/PDF 代码。主程序可见 PDFKit 依赖、TyPDFEngine、YPDocument 与多种 PDF 路径，具体路径选择依系统版本和选项。

自定义导出通过 export.exportWithCommand 取得展开变量后的 args、cwd、output 和 option；Mac 原生再承担外部命令执行。JS Node 分支直接执行的代码不等于 Mac 的执行方式。没有实际生成或导出任何用户文件。

## 图片偏好主题与系统集成

images.copyImage 和 images.upload 将本地复制或上传描述交原生，完成后更新图片节点地址；批量上传还有 prepareUploadAllImagesOnMac 和 allImageUploadCallback。原生有 ImageCommands、IPicBridge、iPicUploader 及任务处理，静态网络 API 不证明用户配置启用或已经发送图片。

主编辑器主题加载由注入的 _options 提供 currentThemeFolder 与当前主题；index.html 设置 theme_css、base.user.css 和主题 user.css，main.js 处理动态切换、字体大小与颜色方案。未读取用户主题目录。

偏好页面是独立 React Webpack 页面。它通过 webkit.messageHandlers._setting.postMessage({name,data,id}) 发送请求，以 id 对应回调；不是主编辑器的 _bridge 协议。原生 Setting/WKPreferenceController 承担持久化和窗口集成。

clipboard 桥接涉及 HTML、RTF、WebArchive、文本与图片；菜单和 Touch Bar 由原生控制器接收当前编辑状态。系统格式优先级、拖放时序和异常恢复没有运行验证。

projectSetting 与 fileSetting 的代码存在，但 localSettingBridge.loadFromProject 是空函数，本地设置 iframe 指向 localhost:3000 的开发地址且 os=win。不能把这些残留当作本 Mac 已启用 .editorConfig/.typoraConfig 的证明。

## 原生桥接机制

index.html 的异步主通道把 handlerName、data 和 callbackId 传给 WebKit 的 _bridge。JavaScript registerHandler 定义接收原生消息的函数，callHandler 向原生发起请求，callbackId 用于响应配对。

同步接口把 name、method、data 编码成 JSON，使用 _bridge.callSync 或 prompt("__bridge__",...)。原生 CommandBridge.callSync: 解析 JSON、选择 groupForString:、执行 callMethod:data: 并返回 JSON；runJavaScriptTextInputPanel 的实现识别 __bridge__。

groupForString 可见 document、setting、touchbar、menu、controller、contextMenu、library、path、clipboard、images。CommandsBase.callMethod:data: 经 selectorForWebScriptName: 和 performSelector:withObject: 分派。这个动态 Objective-C 边界使静态函数调用图不能唯一解析全部接收者。

保守配对索引对 193 个 JS 字面量位置逐个搜索原生相反方向的同名端点，其中 182 个位置有匹配候选。配对结果保留方法体地址、汇编行号和 JS 字符/字节偏移。同步分派、动态名称和未恢复的原生位置单独保留为未知，而不是判定缺失功能。

## 第三方组件与平台边界

| 组件 | 依据与范围 |
| --- | --- |
| CodeMirror | 主编辑器直接调用，模式资源在 lib/codemirror；不猜测未证实版本 |
| MathJax 3 | 打包目录与 tex2svgPromise 调用 |
| Mermaid 和 ZenUML | 加载路径、注册外部图表和调用代码 |
| React 和 ReactDOM 16.13.1 | page-dist 打包 LICENSE 头；主要用于辅助页面 |
| hotkeys-js 3.8.1 | 打包 LICENSE 头 |
| ripgrep | 两个架构的包内可执行文件；主程序 prepTask 明确选择路径 |
| Sparkle | 框架与 SUFeedURL/SUEnableAutomaticChecks 声明；没有观察更新网络活动 |
| Sentry | 框架存在，Podfile 声明 8.4.0；声明不等于完整二进制版本鉴定或实际遥测开启 |
| libTypora.dylib | 可见 Objective-C runtime 方法查找/替换依赖，符号大量剥离；来源和官方归属未建立 |

## 原生功能证据补充

native-findings.json 对文件监听、搜索进程、Pandoc、PDF、设置和图片处理保留方法/块级证据。原生表只计定义类；classrefs 中引用的 NSMetadataQuery 等系统类不能误计为 Typora 自己定义的类。

98 个定义类包含 UI 控件、文档和桥接类，也包含 PDF、图片与第三方适配代码。2017 个方法实现记录来自 Objective-C imp 字段去重；不把协议方法要求当作实现。2608 个汇编标签包括 Objective-C 方法、C 函数、block 与冷路径，不能理解成 2608 个完整业务功能。

| 子系统 | 可见原生实现 | 证据函数 |
| --- | --- | --- |
| 全文搜索 | CPU 选择 rg；SpawnTask 使用 posix_spawnp、pipe、NSFileHandle 读通知和 waitpid | TyWindowController(Search).prepTask/search，SpawnTask.launch |
| 文件监听 | Notifier 创建 FSEvents 流，挂到 runloop；start/stop 和 FileChanges 聚合 | bindFolderMonitor，Notifier.initWithCallback:path:andInfo: |
| 目录枚举 | NSFileManager 目录枚举、深度控制、别名与过滤分支 | LibraryCommands.listDocsUnder:maxLevel:addTo: |
| 偏好持久化 | 内存字典和 standardUserDefaults 读写 | Setting.get/put 与 WKPreferenceController |
| Pandoc | NSTask 设置可执行路径、参数、stdin/stdout/stderr；可见 -f native 参数 | PandocBridge.prepPandocTask/runTask |
| PDF | NSPrintOperation 和 WebKit createPDF 路径，TyPDFEngine 后处理 | TyWindowController(Export)，TyPDFEngine |
| 图片上传 | iPic、本地 PicGo/PicList HTTP 服务和自定义任务代码 | IPicBridge，ImageCommands |
| 快速打开 | NSMetadataQuery 和 kMDItemDisplayName LIKE[cd] 通配查询，加文本类型筛选 | QuickOpenCommands.setup/buildPredicateQueryFrom:/query: |

## 未恢复内容与后续验证

Hopper 桥接启动超时，深度反编译与原生运行行为仍是覆盖缺口。

| 问题 | 当前状态 | 需要的证据 |
| --- | --- | --- |
| 原生反编译伪代码 | 未取得；REA 等待 Hopper bridge readiness 超时 | 恢复桥接后逐函数 dossier，保留身体范围与间接调用未知 |
| 完整运行调用图 | 未取得 | 测试文档的输入、保存、搜索、导出受控运行记录 |
| Markdown 方言和往返一致性 | 主要解析和序列化路径已定位 | 按语法种类及错误输入建立行为样例，验证文本和DOM转换 |
| 输入法光标及撤销细节 | 分支和队列已定位 | 真实 IME/选区/跨块撤销事件序列 |
| 磁盘错误与恢复完整性 | 保存与快照结构已定位 | 受控测试文件的中断保存、外部改动、多窗口冲突记录 |
| 图片与网络行为 | 桥接和 API 可见 | 用户明确选定测试资源与目标后观察，不使用个人图片 |
| 原始构建工程 | 安装包没有提供足够证据 | 源代码、项目文件、构建配置和符号侧车；不能由反编译保证补齐 |
| 官方原版对应关系 | 当前样本签名无效 | 同版本官方安装包的独立哈希和内容对照 |

## 公开证据索引与复现

本仓库发布原创分析、模块和桥接索引及静态分析工具。原应用二进制、完整打包源代码、整份反汇编、临时诊断和机器个人路径不随仓库发布。位置与样本哈希用于在自行获取的安装包上核对。

| 文件 | 用途 |
| --- | --- |
| [sample.json](../data/sample.json) | 样本身份、哈希、签名与覆盖限制 |
| [modules.json](../data/modules.json) | 83 个模块的身份、依赖和位置 |
| [bridges.json](../data/bridges.json) | 193 处桥接调用及原生端点候选 |
| [native-methods.json](../data/native-methods.json) | 98 个定义类、2017 个方法实现记录 |
| [editor-findings.json](../data/editor-findings.json) | 编辑器功能结论与位置，原代码片段不公开 |
| [integration-findings.json](../data/integration-findings.json) | 13 个外围功能子系统与页面清单 |
| [native-findings.json](../data/native-findings.json) | 原生搜索、监听、导出和偏好的关联证据 |
| [package-manifest.json](../data/package-manifest.json) | 包内文件名、大小、哈希与符号链接 |
| [复现指南](reproduce.md) | 在自行获取的样本上重建本地分析输出 |

模块 AST 的字符偏移使用 JavaScript UTF-16 code units；外围分析的字符偏移使用 Python Unicode code points。双方另列 UTF-8 byte offset，跨文件核对应优先使用 byte offset。原生地址属于样本 arm64 切片的静态虚拟地址，不是运行时 ASLR 地址。

本地 REA 扫描记录：JavaScript ev_ac99e71ff73c90e826f8e1534e402ce18058b9346d690d0adf89f3fa8ae98112；Mach-O ev_e72c62640f8d0103c752533b6ef207456e45bbb2ff002a538769f3c6bfd159af。这些 ID 对应本地原始记录，不是可公开查询的下载地址。公开 JSON 是经整理的派生索引，与原始 REA Evidence 分开标记。

## 全部主编辑器模块

| ID | 身份 | 依赖 | 字符范围 | 身份依据 |
| --- | --- | --- | --- | --- |
| b | external fastdom adapter |  | 6209–6301 | medium |
| c | external adapter |  | 6797–6889 | medium |
| d | language detection | e | 6959–9694 | medium |
| f | Bootstrap UI/modal | e | 9695–20343 | medium |
| 10 | native JSBridge adapter | 11 | 20344–24865 | medium |
| 12 | Node to Markdown serializer | 13 11 | 24866–35617 | high |
| 14 | Node to HTML renderer | 13 11 15 16 17 18 19 | 35618–43304 | high |
| 1a | node splitting/merging transformations | 13 11 1b 15 1c 1d 1e | 43305–63832 | high |
| 1f | CodeMirror marked selection addon | 20 | 63833–65515 | medium |
| 21 | CodeMirror auto-close brackets addon | 20 | 65516–68862 | medium |
| 22 | CodeMirror auto-close tags addon | 20 | 68863–71987 | medium |
| 23 | CodeMirror overlay-mode addon | 20 | 71988–73251 | medium |
| 24 | CodeMirror lint addon | 20 | 73252–77235 | medium |
| 18 | fenced code CodeMirror controller | 20 11 e 25 13 26 1b 15 1c 1f 21 22 23 24 | 77236–110248 | high |
| 27 | inline math rendering | e 13 1b 26 28 29 11 1d | 110249–116353 | high |
| 2a | asynchronous Brush parsing/reconciliation queue | 2b 11 19 13 2c 1b 29 1d | 116354–131304 | high |
| 25 | autosuggestion UI | 20 11 e 1b 28 1d | 131305–137754 | high |
| 2d | image scale bridge helper | 11 | 137755–139241 | medium |
| 2e | images/media | e 13 2f 30 31 1b 28 11 32 2d 33 29 34 17 | 139242–187522 | high |
| 35 | File options/theme/environment setup | e 11 1b 2b 28 32 36 37 34 | 187523–203643 | medium |
| 38 | Node-platform save/save-as/move | e 11 2b 28 32 33 39 34 3a 37 | 203644–211713 | medium |
| 39 | TextPack ZIP load/save | 33 11 34 | 211714–214881 | medium |
| 3a | Node-platform filesystem write/fsync |  | 214882–216478 | medium |
| 3b | external reporter adapter |  | 257237–257311 | medium |
| 37 | Reporter and Analytics instrumentation | 3b | 257312–269055 | medium |
| 3c | File lifecycle/controller | e 11 1b 13 2b 28 32 35 3d 38 33 39 36 34 3e 3a 37 | 269056–294228 | high |
| 3d | FileAction commands | e 11 1b 13 2b 28 2f 29 3e | 294229–301216 | high |
| 3f | document search and replace | 11 1d 26 20 19 13 30 28 | 301217–322012 | high |
| 40 | word/character/read-time counters | 11 e 13 | 322013–329555 | high |
| 41 | native search adapter |  | 329556–329981 | high |
| 42 | native/Pandoc export conversion | 13 11 1c 15 19 17 32 29 28 | 329982–343284 | medium |
| 43 | PDF/print/image export helper | 28 11 32 | 343285–352940 | medium |
| 44 | Pandoc/child-process import/export | 11 28 32 34 | 352941–361443 | medium |
| 45 | export orchestrator | 13 11 19 30 42 28 17 15 1c 32 29 e 43 44 2b | 361444–392587 | high |
| 46 | CodeMirror active-line addon | 20 | 392588–393800 | medium |
| 47 | CodeMirror visible-space addon | 20 | 393801–394471 | medium |
| 48 | source Markdown CodeMirror view | 20 46 47 e 13 11 19 1b | 394472–407632 | high |
| 49 | document/project options | 32 11 | 407633–413617 | high |
| 4a | quick-open | e 11 26 32 | 413618–424924 | high |
| 4b | context menu | 26 13 2c 2f 29 11 1b | 424925–455853 | high |
| 4c | spellchecking | 2b e 32 26 | 455854–474507 | high |
| 4d | DOM tree patch helper |  | 474508–478734 | medium |
| 4e | folder tree view | 11 13 32 34 28 e 4d | 478735–496334 | medium |
| 4f | file list view | 11 13 32 34 26 28 e | 496335–515400 | medium |
| 31 | selection/cursor controller | 11 e 1d 20 13 26 | 515401–569313 | high |
| 50 | references/footnotes/metadata | 11 13 e 19 31 32 1b 34 30 | 569314–581566 | high |
| 51 | outline controller | 11 e 1d 26 28 13 50 | 581567–594685 | medium |
| 2c | format/style commands | 2b 11 13 1b 1d 19 36 | 594686–625508 | high |
| 52 | structural edit helper | 11 13 1b 1d | 625509–636606 | medium |
| 53 | structural edit helper | 11 13 1b 1d 1e | 636607–642285 | medium |
| 54 | editing user operations | 11 13 1b 55 2c 52 53 | 642286–660813 | medium |
| 56 | paste/copy/drop conversion | 11 13 1b 1d 19 55 3e 2c 57 17 32 54 29 | 660814–688986 | medium |
| 2f | user-operation facade | 11 13 1b 1d 19 55 32 3e 54 52 53 1e 56 | 688987–692362 | high |
| 58 | IntersectionObserver polyfill |  | 692363–699351 | medium |
| 2b | browser compatibility polyfills | e 58 | 699352–710451 | high |
| 36 | menu state/refresh/controller | 1b 13 2b | 710452–720206 | medium |
| 55 | table controller | e 13 1b 2b 36 26 | 720207–752558 | high |
| 34 | filesystem/watch adapter | 11 32 28 | 752559–761529 | high |
| 33 | TextBundle/TextPack support | 11 32 34 | 761530–766218 | medium |
| 30 | inline HTML decoration | 11 13 28 32 33 16 17 29 | 766219–790831 | medium |
| 57 | emoji completion | e | 790832–816387 | high |
| 1d | Rangy DOM range implementation |  | 816388–862042 | medium |
| 1e | smart punctuation handling | 11 13 1b 1d | 862043–865353 | medium |
| 19 | Markdown block parser | 11 13 30 1b 57 17 1e | 865354–913511 | high |
| 16 | external factory adapter |  | 929287–929367 | medium |
| 20 | CodeMirror bundled library |  | 929368–1094168 | medium |
| 1c | math block editing/render | 20 e 13 1b 11 29 26 | 1094169–1111999 | high |
| 15 | diagram controller | 20 11 e 13 26 1c | 1112000–1121411 | medium |
| 1b | undo command/snapshot manager | 11 13 | 1121412–1140103 | high |
| 17 | HTML/raw block controller | 20 11 e 16 13 26 15 1b | 1140104–1163183 | high |
| 3e | HTML-to-Markdown model parsing/reconciliation | 11 13 55 19 17 e | 1163184–1180270 | medium |
| 29 | media/clipboard/export helpers | e 13 11 33 34 2f 3e 26 | 1180271–1188562 | high |
| 13 | Node/NodeMap document model | 11 | 1188563–1204054 | high |
| 59 | Unicode normalization library |  | 1204055–1341405 | medium |
| 11 | shared utilities | 59 | 1341406–1367074 | high |
| 28 | UI/dialog/path utilities | e 13 11 | 1367075–1382225 | high |
| 32 | file state/change counts | 11 33 29 28 | 1382226–1395511 | high |
| 26 | keyboard mapping |  | 1395512–1399127 | high |
| 5a | folder search | 11 e 32 26 | 1399128–1415484 | medium |
| e | external jQuery adapter |  | 1501783–1501875 | high |
| 5b | sidebar/file navigation | 11 13 28 32 34 33 26 4e 4f 51 5a e | 1502014–1550595 | high |
| 5c | Editor composition/root controller | 2b e 11 13 19 12 14 1a 18 1c 27 2a 25 31 28 17 55 2e 1b 26 2f 29 34 3c 3d 50 2c 3f 57 40 41 45 48 32 49 4a 4b 4c 5b | 1550596–1619222 | medium |
| a | application bootstrap | e b c d f 10 3c 5c | 1619223–1620784 | medium |
