<div align="center">

# open-typora

**Write in Markdown. Stay in the flow.**

An open-source Markdown editor built around your files, a native Mac shell, and a shared Rust core.

[![Version](https://img.shields.io/badge/v0.0.1-Beta-ef9f43)](https://github.com/yruichen/open-typora/releases/tag/v0.0.1)
[![Platform](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-555555)](https://github.com/yruichen/open-typora/releases/tag/v0.0.1)
[![License: MIT](https://img.shields.io/badge/License-MIT-3b82f6)](LICENSE)

[**Download for macOS**](https://github.com/yruichen/open-typora/releases/tag/v0.0.1) · [Report an issue](https://github.com/yruichen/open-typora/issues) · [简体中文](README.zh-CN.md)

</div>

## A familiar place for your words

Inspired by Typora’s writing experience, open-typora is working toward a focused, lightweight editor that feels at home on macOS.

- **Your files stay Markdown.** Open a `.md` file, write, and save it back to disk. No proprietary document format.
- **The Mac handles the window.** AppKit provides the windows, menus, toolbar and file dialogs. CodeMirror 6 handles editing inside the system’s WKWebView.
- **Rust handles the shared core.** Document models, file operations and application services live behind explicit platform boundaries. macOS comes first; Windows and Linux hosts are future work.

Lightweight operation is a design goal. We have not yet published performance benchmarks.

## What you can do today

| Write | Navigate | Keep your work |
| --- | --- | --- |
| Source and visual editing modes | Find and replace within a document | Open and save UTF-8 Markdown |
| Shared undo and redo history | Jump to a line | Local recovery copies |
| Basic Markdown formatting and editable tables | Native menus and keyboard shortcuts | Optional autosave for named files |
| English and Simplified Chinese interface | Switch modes with **⌘/** | External-change detection |

> **v0.0.1 is an early Beta.** This is not yet a complete Typora alternative. Full Markdown presentation, images, math, diagrams and advanced export remain unfinished. Native interaction, accessibility and platform compatibility need broader validation.

## Try the Beta

1. [Download the macOS release](https://github.com/yruichen/open-typora/releases/tag/v0.0.1) for **Apple Silicon, macOS 14 or later**.
2. Unzip the archive and move **OpenTypora.app** to **Applications**.
3. Open a Markdown file and start writing.

The Beta is ad-hoc signed and **not notarized**; macOS may require an explicit security approval before opening it.

| Action | Shortcut |
| --- | --- |
| Open a file | ⌘O |
| Save / Save As | ⌘S / ⇧⌘S |
| Switch editing modes | ⌘/ |

Change the interface language in **Open Typora → Settings… → General → Language**.

Current file support covers ordinary UTF-8 files up to 64 MiB, preserving BOM and mixed line endings. Recovery opens an unsaved copy; input that was never persisted cannot be recovered.

## Build it yourself

Requirements: an Apple Silicon Mac with macOS 14 or later, Xcode with Swift 6, Rust/Cargo, and Node.js 24.11 or later with npm.

```bash
git clone https://github.com/yruichen/open-typora.git
cd open-typora
npm ci
npm run app:build
open .local/build/OpenTypora.app
```

The build generates the Swift bindings and bundles the editor into the app. The built app needs neither Node.js nor a development server. Quit the app before rebuilding; successful builds replace the previous app at the same path.

## Inside the project

| Path | Responsibility |
| --- | --- |
| `apps/macos/` | AppKit windows, menus, dialogs and WebView host |
| `packages/editor/` | Editing, selection, history and Markdown presentation |
| `packages/protocol/` | Editor–host protocol client and transports |
| `crates/` | Rust document model, use cases, I/O, runtime and Swift bindings |
| `tests/` | Shared test fixtures and integration checks |
| `tools/` | Build tools, code generation and checks |

Try the Beta, [share a reproducible bug](https://github.com/yruichen/open-typora/issues), or contribute a focused fix. Include your macOS version and a small sample document when reporting editing problems. If this is an editor you’d like to see grow, a star helps others discover it.

## License and acknowledgements

Original work is licensed under [MIT](LICENSE). This project is independent of Typora and its developers; see [NOTICE.md](NOTICE.md) for attribution and licensing scope.

Thanks to [REA — Reverse Engineer Anything](https://github.com/morluto/rea) for its application analysis tools and workflows.
