<div align="center">

<img src="assets/brand/lino.png" alt="Lino folded-paper L logo" width="96">

# Lino

**A quiet place for your words.**

An open-source Markdown editor with a native Mac shell and a shared Rust core. Write a note, explain an idea, or bring code, equations and diagrams into the same document.

[![Version](https://img.shields.io/badge/v0.0.3-Beta-ef9f43)](https://github.com/yruichen/lino/releases/tag/v0.0.3)
[![Platform](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-555555)](https://github.com/yruichen/lino/releases)
[![License: MIT](https://img.shields.io/badge/License-MIT-3b82f6)](LICENSE)

[**Download for macOS**](https://github.com/yruichen/lino/releases/tag/v0.0.3) · [Build from source](#build-it-yourself) · [简体中文](README.zh-CN.md)

</div>

<p align="center">
  <img src="assets/screenshots/writing.png" alt="Lino on macOS showing an English writing sample and a local illustration" width="48%">
  <img src="assets/screenshots/code-and-math.png" alt="Rust syntax highlighting, inline mathematics and a rendered equation in Lino" width="48%">
</p>

## Make room for the thought

Start with a sentence, then give the idea room to grow. Lino keeps your writing in ordinary Markdown files, with a focused editing surface and the windows, menus and shortcuts you expect on a Mac.

- **Keep the file yours.** Open a `.md` file, write, and save it back to disk. Your work stays portable.
- **Stay with the paragraph.** Visual editing, readable code blocks, editable tables and rendered mathematics sit alongside your words. **⌘/** brings up the original source with the same undo history.
- **Feel at home on macOS.** Native window tabs, menus, file dialogs and search controls surround an editor that uses the WebKit engine supplied by macOS.

Try the [English showcase document](examples/showcase/Lino-Showcase.md) with its accompanying image folder. It contains original writing, a Rust example, a table, equations and a Mermaid diagram.

## In v0.0.3

New in this release: a native file/outline sidebar, Quick Open with **⌘P**, categorized settings with twelve theme appearances and custom themes, and image insertion that links to the original file by default.

| For your words | For your ideas | For your files |
| --- | --- | --- |
| Visual and source editing with shared undo | Syntax-highlighted code with language selection | Open, save and Save As |
| Headings, lists, tasks and editable tables | Local images and reference links | Native document windows and tabs |
| Find and replace, including regular expressions | Inline and block equations with KaTeX | Optional autosave and local recovery copies |
| Outline, focus mode and reading statistics | Mermaid diagrams and standalone HTML export | External-change detection and read-only handling |

The interface is available in **English and Simplified Chinese**. macOS PDF and printing are also available for testing.

**v0.0.3 is a usable Markdown foundation, still in Beta.** Broader Markdown compatibility, accessibility, native interaction and print layout need more testing. Responsiveness and a small runtime are design priorities; performance comparisons have not yet been published. Windows, Linux and broader document formats are future work.

## Get Lino

1. [Download Lino v0.0.3](https://github.com/yruichen/lino/releases/download/v0.0.3/Lino-v0.0.3-macos-arm64.zip) for **Apple Silicon and macOS 14 or later**.
2. Unzip the archive and move **Lino.app** to **Applications**.
3. Open a Markdown file and start writing.

Checksums and release notes are on the [v0.0.3 release page](https://github.com/yruichen/lino/releases/tag/v0.0.3). Lino was previously named Open Typora; existing recovery data keeps its original location.

The Beta is ad-hoc signed and **not notarized**; macOS may require an explicit security approval before opening it.

| Action | Shortcut |
| --- | --- |
| Open a file | ⌘O |
| Save / Save As | ⌘S / ⇧⌘S |
| Find / Find next | ⌘F / ⌘G |
| Switch editing modes | ⌘/ |
| Zoom in / out / reset | ⌘+ / ⌘− / ⌘0 |

Change the interface language in **Lino → Settings… → General → Language** (**⌘,**).

Current file support covers ordinary UTF-8 files up to 64 MiB, preserving BOM and mixed line endings. Recovery opens an unsaved copy; input that was never persisted cannot be recovered.

## Build it yourself

Requirements: an Apple Silicon Mac with macOS 14 or later, Xcode with Swift 6, Rust/Cargo, and Node.js 24.11 or later with npm.

```bash
git clone https://github.com/yruichen/lino.git
cd lino
npm ci
npm run app:build
open .local/build/Lino.app
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
| `assets/` | Shared brand artwork and product screenshots |

Try the Beta, [share a reproducible bug](https://github.com/yruichen/lino/issues), or contribute a focused fix. Include your macOS version and a small sample document when reporting editing problems. If this is an editor you’d like to see grow, a star helps others discover it.

## License and acknowledgements

Original work is licensed under [MIT](LICENSE). This project is independent of Typora and its developers; see [NOTICE.md](NOTICE.md) for attribution and licensing scope.

Thanks to [REA — Reverse Engineer Anything](https://github.com/morluto/rea) for its application analysis tools and workflows.
