# AI Markdown upstream baseline: v2.10.0

Date: 2026-10-30.

## Provenance and integration

- Previous upstream baseline: `fab34c2b1b3fa9dd10aded00863a11b1258abcb1`, after v2.9.1.
- New upstream baseline: [v2.10.0](https://github.com/2389-research/MermaidKit/releases/tag/v2.10.0), commit `18e56748e9246a6b647985c4c54ea3b56e646d89`.
- Previous published fork: `21f5a89b747a297d3ffae88c668889cc70b67000`.
- Integration uses a merge on `ai-markdown`, preserving published fork history and all existing maintenance patches. The upstream `main` branch remains an unmodified upstream mirror.

The upstream delta improves flowchart fan routing, layer-gap track ordering, edge-end clearance, and caption placement. It adds hooked-end and own-edge caption lint checks. Earlier subgraph spanning, C4 cycle fixes, and the v2.9.1 caption-placement acceleration were already included in our previous baseline.

`DiagramScene+State.swift` is the only source file changed by both sides. The merge keeps upstream choice-node `isDecision` metadata and our note nodes and labels. All other existing fork source changes remain intact. The combined `testStateScenePreservesChoicesAndNotesTogether` regression checks this interaction. The fork's parser diagnostics, CRLF handling, checked autonumber arithmetic, large-image limits/errors, and Gantt/ER/Cynefin/state-note fixes remain in place.

No products, deployment targets, package traits, dependency declarations, or licenses changed. `LinuxRaster` remains disabled by default.

## Validation

Environment: Xcode 27.1 (27A9275), Swift 6.4, arm64 macOS; iPhone 18 Pro simulator on iOS 27.0 (`1E8C60A4-BF81-4F7A-9554-A839C7A14F89`).

- `swift test`: passed, 64 render tests, 553 layout tests, 16 C ABI tests; four opt-in tests skipped. The additional combined state regression passed separately in Debug.
- iOS simulator: MermaidRenderTests, DroppedContentTests, and LayoutLintTests passed (57 tests, two opt-in skips); the newly added combined regression also passed separately.
- `bash scripts/check-conformance.sh`: passed with the upstream v2.10.0 signature `b26cce4b4a877478`. This checks the host against the cross-platform reference; it does not mean other platforms were run locally.

- `swift test -c release` could not compile the existing `DrawSceneConformanceTests`, `TextScaleTests`, and `GanttRenderTests`: they reference `textCaptureHook` / `lineCaptureHook`, which `DiagramRenderer+Primitives.swift` defines only under `#if DEBUG`. Those files and guards are unchanged from the previous fork. This is a pre-existing test-configuration limitation, not a passing Release test result. Release product compilation and the parent package's Release renderer integration tests are checked separately.

- `swift build -c release`: passed with normal Release flags (no DEBUG override).
- `bash scripts/check-determinism.sh`: passed; all fixture raster signatures match across two fresh processes.
- `bash scripts/check-mermaid-oracle.sh`: passed against the existing divergence baseline; 1,588 charts, 1,330 agreements (150 retaining tag-like text), 239 lenient cases, zero rejected cases, and 19 recorded differences. No divergence baseline was changed.

This upgrade does not establish interactive host-app layout, VoiceOver, device performance, or Linux/Android/Windows/WASM validation. Existing unsupported syntax and rendering limitations remain documented in the fork's contributor guidelines and the parent package's Mermaid component documentation.
