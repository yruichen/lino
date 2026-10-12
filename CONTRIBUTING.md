# Contributing

Contributions should make a specific claim easier to verify.

Include the sample version, platform, architecture, and relevant SHA-256. Cite a file and byte offset, a native method and address, or a controlled runtime scenario. Distinguish direct observations, static inferences, and unknowns.

A different version is a different sample. Do not carry forward module ordinals, minified names or addresses without checking identity. An unmatched endpoint is an unresolved observation, not evidence that functionality is absent.

Keep target applications, full bundled code, full disassembly, private documents, keys and raw machine diagnostics out of contributions. The factual indices and original prose are the public layer; local evidence belongs in ignored `.local/` output.

## Editing the report

The source is `docs/report.zh-CN.md`. Edit it, then run:

```bash
npm ci
npm run build
npm run check
```

Commit the regenerated `docs/index.html` with the source. CI checks data counts, module dependencies, local links, private-path patterns and deterministic report rendering.

Translation, official-sample corroboration, bounded behavior tests and interface corrections are useful starting points. Use the finding issue template to provide enough evidence for another person to reproduce your result.
