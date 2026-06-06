# scripts/ — developer tooling

One-purpose shell tools for this repo. Run them from the repo root. Anything
that touches a device is **physical-iPad only** — no simulators on this machine
(see ../CLAUDE.md §6); device-targeting scripts auto-detect the connected iPad.

| Script | Purpose |
|--------|---------|
| `build-launch.sh` | Build the app and install + launch it on an auto-detected paired iPad. `--release` → Release, otherwise Debug. |
| `build-summary.sh` | Wrap `xcodebuild build` → concise pass/fail plus structured xcsift JSON + raw log under `.build-logs/`. Fallback for XcodeBuildMCP. |
| `test-summary.sh` | Wrap `xcodebuild test` → pass/fail, failed-case list, xcsift JSON. `--filter`/`--scheme`. Fallback for XcodeBuildMCP. |
| `regen-contracts.sh` | Regenerate `CameraKit/CONTRACTS.md` (compressed public-API snapshot via repomix). Auto-runs on the pre-commit hook; rarely needed by hand. |
| `regen-docs.sh` | Regenerate the **consumer** docs in `Documentation/` (symbol graph → consumer filter + drift guard → reference clusters + `index.md`/`api-index.md` → flatten guides). `--skip-emit` reuses the existing symbol graph to skip the device build. |
| `emit-symbol-graph.sh` | Emit CameraKit's compiler symbol graph to `Documentation/reference/symbol-graph.json` — the canonical machine source for the generated API reference. Mac "Designed for iPad" build. |
| `build-docc.sh` | Build the human-facing DocC archive (`CameraKit.doccarchive`) from the `CameraKit/Sources/CameraKit/CameraKit.docc` catalog via `xcodebuild docbuild`. |
| `sync-test-target.sh` | Wire new `CameraKit/Tests/CameraKitTests/*.swift` files into the app-hosted Xcode test target (dual-membership, ../CLAUDE.md §8). Idempotent; run after adding a test file. |
| `dump-interface.sh` | Emit CameraKit's compiler-validated `.swiftinterface` — the authority on isolation (`@MainActor`/`nonisolated`), Sendable, and `@available`. |
| `lsp-symbol.sh` | One-shot sourcekit-lsp client (`outline`/`hover`/`workspace`). Fallback for the `LSP` MCP tool; reliable on leaf files only. |
| `device-log-live.sh` | Poll `camerakit.log` off an auto-detected iPad over WiFi (`start`/`stop`/`tail`/`grep`). Backend for the `ipad-logs` skill. |

The consumer-docs generators behind `regen-docs.sh` are Python, not shell, and
live in `scripts/docgen/` (`symbolgraph.py` filter + drift guard, the
`render_*.py` generators, `flatten_guides.py`, configs, and `tests/`). Run the
tests with `python3 -m unittest discover -s scripts/docgen/tests -p 'test_*.py'`.

Conventions: each script does one job, assumes repo root as CWD, and exits
non-zero on failure.

For the full tool **decision tree** and per-script "what / when / why" (plus the
MCP tools and host setup), see [`../docs/tooling.md`](../docs/tooling.md).
