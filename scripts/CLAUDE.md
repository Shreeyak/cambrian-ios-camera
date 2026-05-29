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
| `sync-test-target.sh` | Wire new `CameraKit/Tests/CameraKitTests/*.swift` files into the app-hosted Xcode test target (dual-membership, ../CLAUDE.md §8). Idempotent; run after adding a test file. |
| `dump-interface.sh` | Emit CameraKit's compiler-validated `.swiftinterface` — the authority on isolation (`@MainActor`/`nonisolated`), Sendable, and `@available`. |
| `lsp-symbol.sh` | One-shot sourcekit-lsp client (`outline`/`hover`/`workspace`). Fallback for the `LSP` MCP tool; reliable on leaf files only. |
| `device-log-live.sh` | Poll `camerakit.log` off an auto-detected iPad over WiFi (`start`/`stop`/`tail`/`grep`). Backend for the `ipad-logs` skill. |

Conventions: each script does one job, assumes repo root as CWD, and exits
non-zero on failure.

For the full tool **decision tree** and per-script "what / when / why" (plus the
MCP tools and host setup), see [`../docs/tooling.md`](../docs/tooling.md).
