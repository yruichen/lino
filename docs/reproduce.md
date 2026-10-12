# Reproduce a local investigation

Report building and target analysis are separate operations. `npm run build` reads only the public report and indices. The analyzers below read an app you supply and write ignored local output.

## Requirements

- Node.js 24.11 or newer for the repository's tools.
- Python 3 for native indexing.
- macOS Command Line Tools providing `otool` and `nm` for native collection.
- A separately obtained Typora installation that you can examine.

Install the repository dependencies:

```bash
npm ci
```

## Index the main editor

```bash
npm run analyze:editor -- "/Applications/Typora.app"
```

Outputs are written to `.local/generated/`. The extractor was developed against the recorded 1.9.4 sample. Feature anchors can fail on a different version; treat that failure as a sample mismatch, not an invitation to silently reuse old offsets.

The script parses JavaScript as text. It does not import, require, or evaluate the target bundle.

## Collect and index native code

```bash
python3 tools/collect-native.py --app "/Applications/Typora.app"
python3 tools/index-native.py --app "/Applications/Typora.app"
```

Outputs are written to `.local/native/`. A missing optional `libTypora.dylib` is skipped during collection and indexing; this file is part of the analyzed sample and is not asserted to be part of every official installation.

This runs native inspection utilities against file bytes, not Typora. No Hopper process is launched by these two scripts. They currently inspect arm64 bodies.

## Use REA independently

For a local JavaScript artifact:

```bash
npx -y rea-agents@6.4.0 analyze-javascript-application \
  "/Applications/Typora.app/Contents/Resources/TypeMark" \
  --format json > .local/rea-javascript.json
```

Native header inspection without Hopper:

```bash
npx -y rea-agents@6.4.0 inspect-macho \
  "/Applications/Typora.app/Contents/MacOS/Typora" \
  --format json > .local/rea-macho.json
```

These commands download the pinned REA package if it is not cached. Check the returned coverage and limitations. The original investigation encountered semantic memory limits and Hopper bridge startup failure; a successful command exit is not a complete-recovery claim.

For deeper native analysis, configure a supported engine using REA's own documentation. Engine initialization and any runtime capture have their own effects; they are not part of the repository's report build or validation.

## Propose a finding

Record the app version, architecture and relevant file hash, then include a bounded claim with a file/byte offset or method/address. Keep local target code and raw disassembly in `.local/`; submit original explanation and factual indices rather than a copy of the application.
