<div align="center">

<img src="assets/brand/lino.png" alt="Lino" width="96">

# Lino

**An open-source Markdown editor for macOS.**

Visual editing. Native Mac windows and tabs. Your own Markdown files.

[![Version](https://img.shields.io/badge/v0.1.1-Stable-28584b)](https://github.com/yruichen/lino/releases/tag/v0.1.1)
[![macOS](https://img.shields.io/badge/macOS-14%2B%20%C2%B7%20Apple%20Silicon-555555)](https://github.com/yruichen/lino/releases/tag/v0.1.1)
[![License: MIT](https://img.shields.io/badge/License-MIT-3b82f6)](LICENSE)

[**Download**](https://github.com/yruichen/lino/releases/download/v0.1.1/Lino-v0.1.1-macos-arm64.zip) · [Homebrew](#homebrew) · [Features](#features) · [Build](#build-from-source) · [Report an issue](https://github.com/yruichen/lino/issues) · [简体中文](README.zh-CN.md)

</div>

![Lino’s light appearance, showing an illustrated Markdown document and the native outline sidebar](assets/screenshots/writing.png)

Lino combines visual Markdown editing with a native Mac workspace. Write notes, documentation and technical articles with code, tables, equations and diagrams in one editor. Browse your folders, navigate the outline, and switch between documents in native tabs.

## Features

- **Visual and source editing** — Read formatted Markdown as you edit. Switch to source with **⌘/**; both modes share the same undo history.
- **Code, math and diagrams** — Syntax-highlighted code blocks, editable tables, KaTeX equations, Mermaid diagrams and image previews.
- **File navigation** — A native file tree and outline sidebar, **⌘P** Quick Open, folder content search, and find and replace with regular expressions.
- **Writing tools** — Focus and typewriter modes, word and selection counts, adjustable fonts, line spacing and reading width.
- **Light and dark themes** — Six paired themes, custom theme import, and background image options.
- **Local Markdown files** — Open and save ordinary `.md` files, with optional autosave, local recovery copies and external-change detection.
- **Export and print** — Standalone HTML, PDF export and macOS printing.

The interface supports **English and Simplified Chinese**.

![Lino’s dark appearance, showing syntax-highlighted Rust code and rendered equations](assets/screenshots/code-and-math.png)


## Download

Requires **macOS 14 or later on Apple Silicon**.

### Homebrew

```bash
brew install --cask yruichen/tap/lino
```

### Direct download

**[Download Lino v0.1.1 for macOS →](https://github.com/yruichen/lino/releases/download/v0.1.1/Lino-v0.1.1-macos-arm64.zip)**

Unzip the download and move **Lino.app** to **Applications**. Release notes and checksums are on the [release page](https://github.com/yruichen/lino/releases/tag/v0.1.1).

The welcome window offers New Document and Open File; reopen it from **Lino → Welcome to Lino…**. Downloaded copies also offer Install and Open Lino, without moving files manually. Optional Markdown file associations are in **Settings → General**. Installing Lino does not take over existing associations. You can also select a `.md` file in Finder, choose **Get Info → Open with → Lino → Change All**.

Use **⌘O** for a file or **⇧⌘O** for a folder. macOS may request access to protected locations when you open them. If you previously denied access, review **System Settings → Privacy & Security → Files and Folders**, then reopen the location. Lino does not require an account, Accessibility access or Full Disk Access.

The macOS build is ad-hoc signed and **not notarized**. If macOS blocks the first launch, use **System Settings → Privacy & Security → Open Anyway** to approve the app.

Lino is under active development. Markdown compatibility, accessibility and print layout still need testing. Windows and Linux builds are not yet available.

## Getting started

Open a Markdown file with **⌘O**, or create one with **⌘N**. The [showcase document](examples/showcase/Lino-Showcase.md) includes writing, images, code, tables, equations and a diagram; keep its image folder alongside it.

| Action | Shortcut |
| --- | --- |
| Quick Open | ⌘P |
| Save / Save As | ⌘S / ⇧⌘S |
| Find / Find next | ⌘F / ⌘G |
| Switch visual / source mode | ⌘/ |
| Settings | ⌘, |

Change the interface language in **Lino → Settings… → General → Language**.

<details>
<summary>File and recovery support</summary>

Lino currently supports ordinary UTF-8 files up to 64 MiB, preserving BOM and mixed line endings. Recovery opens an unsaved copy; input that was never persisted cannot be recovered. Lino was previously named Open Typora, and existing recovery data keeps its original location.

</details>

## Build from source

Requires an Apple Silicon Mac with macOS 14 or later, Xcode with Swift 6, Rust/Cargo, and Node.js 24.11 or later with npm.

```bash
git clone https://github.com/yruichen/lino.git
cd lino
npm ci
npm run app:build
open .local/build/Lino.app
```

Lino uses AppKit for its native interface, the system WebKit engine for the editor, and Rust for shared document services. The built app requires neither Node.js nor a development server. Quit Lino before rebuilding.

## Contributing

Bug reports, feature suggestions and pull requests are welcome. [Open an issue](https://github.com/yruichen/lino/issues) with your macOS version, steps to reproduce and a small sample document when relevant.

## License

[MIT](LICENSE). Lino is independent of Typora and its developers. See [NOTICE.md](NOTICE.md) for attribution and licensing scope.

Thanks to [REA — Reverse Engineer Anything](https://github.com/morluto/rea) for its application analysis tools and workflows.
