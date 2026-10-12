# Methodology and evidence boundaries

The public dataset describes one installed macOS sample. It preserves identities and locations so another investigator can check a claim against the same bytes or explicitly record a different sample.

## Evidence levels

| Level | What it establishes |
| --- | --- |
| Artifact identity | File name, size, SHA-256, architecture and declared metadata |
| Static observation | A parsed registration, a literal argument, a method record or an instruction at a recorded location |
| Static correlation | Candidate relationships inferred from matching endpoints, selectors, and surrounding code |
| Runtime observation | A declared scenario with recorded inputs and outcomes; not included in the current dataset |

Static registration does not establish runtime reachability. An Objective-C selector does not always identify one receiver. Missing output from a bounded index is not proof that a feature is absent.

## JavaScript

The main bundle was parsed as inert text with Babel. Its 83 System registrations and declared dependencies were enumerated. Component identities use retained root import aliases where possible; inferred names keep their confidence and basis.

`data/modules.json` and `data/editor-findings.json` use JavaScript UTF-16 code-unit positions. `data/integration-findings.json` uses Python Unicode code-point positions. Both include UTF-8 byte offsets. Prefer byte offsets when comparing the two systems.

Exports recorded through assignments are a lower bound: mutation and dynamic assignment can produce other interfaces. AST extraction is not a complete call or data-flow graph.

## Native code

The registry comes from `otool -arch arm64 -ov` and `nm`. Classes are counted from class definitions, not class references; protocol declarations are not counted as implementations.

Assembly observations use `otool -arch arm64 -tvV`. Conservative literal recovery decodes Mach-O file-backed addresses and resets symbolic register state at branches and call clobbers. Labels include methods, C functions, blocks and cold paths; label boundaries are not verified complete function-body ranges.

Addresses are static virtual addresses in the arm64 slice, not ASLR-adjusted runtime addresses. Only architecture-level metadata was recovered for x86_64.

## Sample identity and known limits

See [sample.json](../data/sample.json). The sample failed signature verification. No official distribution comparison or attribution of modifications has been established.

The REA JavaScript semantic pass reached memory limits; a separate AST pass recovered bounded structural evidence. The Hopper bridge did not become ready, so native pseudocode was not obtained. No Typora business code, user documents, file operations or network behavior were executed for the published analysis.

## Public data versus local evidence

The public JSON is a curated derivative, not a replayable original REA bundle. Code excerpts, assembly bodies, raw process diagnostics and machine-specific paths are removed. Recorded hashes and offsets remain useful for local verification with a separately obtained target.

The MIT license covers original research and tooling authored for this project. It does not relicense target software or third-party components; see [NOTICE.md](../NOTICE.md).
