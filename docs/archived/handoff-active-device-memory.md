# Device-selection redesign — an "active device" pin for the scripts

**Status:** design agreed; the fail-fast gate + `-destination-timeout`
groundwork is **committed** (`7a4935c`); the pin + shared-resolver redesign is
**not yet implemented**. Paused 2026-05-29 for discussion.
**Branch:** `flutter-monorepo-restructure` (worktree under
`.../eva-swift-stitch/.claude/worktrees/flutter-monorepo-restructure`).

## Why

Two test iPads are usually connected. The scripts each resolve the device
*fresh* on every run (xcodebuild `-showdestinations | head -1`, or a devicectl
"first reachable paired iPad" scan), which is non-deterministic and can target
the wrong iPad. During the post-merge verification, the chosen iPad also
auto-locked **mid-run** and wedged `xcodebuild` for a long stretch.

Goal: the scripts should **remember a pinned "active device"** (e.g.
"Shreeyak's iPad") and reuse it deterministically, with a **command to change**
it — and fail fast (never silently switch) when the pinned device is
locked or absent.

## Current state of the scripts (device selection today)

There are two UDID families (CLAUDE.md §8): xcodebuild uses the **xctrace ECID
UDID**; devicectl uses the **CoreDevice UDID**.

| Script | Tooling / UDID | How it picks the device today |
|--------|----------------|-------------------------------|
| `build-summary.sh` | xcodebuild / xctrace | `-showdestinations` → first iPad line (`head -1`). **Readiness gate** (committed `7a4935c`): aborts if that line carries an `error:` annotation (locked); Mac "Designed for iPad" fallback; `-destination-timeout 15`. Respects an explicit `--destination`. |
| `test-summary.sh` | xcodebuild / xctrace | Same selection + gate + timeout as build-summary. Default scheme `ios_example_app`; adds `--filter`/`--scheme`. |
| `build-launch.sh` | devicectl / CoreDevice | Inline `jq` scan of `devicectl list devices` → first reachable **paired** iPad (connected ranked first); errors if none. PROJECT/SCHEME = `ios_example_app`. |
| `device-log-live.sh` | devicectl / CoreDevice | `detect_ipad()` — same first-reachable-paired scan. `BUNDLE=com.cambrian.ios-example-app`. |

Notes on the current code:
- The fail-fast **readiness gate now lives inline in both xcodebuild wrappers**
  (committed in `7a4935c`) — duplicated between the two. The redesign will
  **extract it into the shared resolver** (de-dup), not re-add it.
- `build-summary.sh` / `test-summary.sh` still contain near-identical
  device-auto-detect blocks — prime candidates for the shared resolver.
- None of the four scripts remembers a device between runs; there is no pin.

## Confirmed decisions (this session)

1. **Offline behavior — ERROR, never switch.** If the pinned device isn't
   connected, the script stops with a clear message ("active device <name> not
   connected — reconnect it or run `scripts/device.sh use`"). No silent
   fallback to another iPad. (Honors the rule: "we don't switch the working
   ipad suddenly.")
2. **Scope — all four device scripts** honor the pin.

## Redesign — proposed design (3 pieces)

### 1. State file `.active-device` (repo root, gitignored)
Host-specific, like `buildServer.json`. Sourceable `KEY=value`, storing **both**
UDID schemes:
```
NAME="Shreeyak's iPad"
XCTRACE_UDID=00008027-000539EA0184402E              # xcodebuild -destination
DEVICECTL_UDID=DAD37FD5-685B-50E0-911E-F9BC40BBDBE5 # devicectl
```

### 2. `scripts/device.sh` — the manager command
- `status` (default) — show the active device (or "unpinned").
- `list` — connected iPads with **both** UDIDs.
- `use [<name|udid>]` — pin a device; numbered picker if no arg. Correlates
  `xcrun xctrace list devices` (name + xctrace UDID) with `xcrun devicectl list
  devices` (name + CoreDevice UDID) **by name** to capture both, then writes
  `.active-device`.
- `clear` — remove the pin (back to auto-detect).

### 3. `scripts/lib/active-device.sh` — shared resolver (sourced)
De-duplicates the auto-detect blocks and **absorbs the committed readiness
gate**:
- `load_active_device` → `AD_NAME` / `AD_XCTRACE_UDID` / `AD_DEVICECTL_UDID`
  (empty if unpinned).
- `resolve_ios_destination <project> <scheme>` → echoes the `-destination`
  string on **stdout** (for `DESTINATION=$(...)`); human `DEST:`/error lines on
  **stderr**. Pinned & present & unlocked → use it; pinned & absent → error;
  pinned & locked (`error:`) → error; unpinned → today's `head -1` + lock gate
  + Mac fallback.
- `resolve_devicectl_udid` → echoes the CoreDevice UDID. Pinned & reachable →
  use it; pinned & unreachable → error; unpinned → first reachable paired iPad.

## Implementation plan (ordered)

1. `scripts/lib/active-device.sh` — `load_active_device`,
   `resolve_ios_destination`, `resolve_devicectl_udid`.
2. `scripts/device.sh` — `status` / `list` / `use` / `clear`.
3. `build-summary.sh` + `test-summary.sh`: source the lib; **replace the inline
   auto-detect + gate** (committed in `7a4935c`) with
   `DESTINATION=$(resolve_ios_destination ios_example_app/ios_example_app.xcodeproj "$SCHEME") || exit 1`.
   Keep `-destination-timeout 15`.
4. `build-launch.sh` + `device-log-live.sh`: source the lib; replace their
   inline devicectl scans with `resolve_devicectl_udid`.
5. Add `.active-device` to `.gitignore`.
6. Update `scripts/CLAUDE.md` (add a `device.sh` row; note the pin behavior);
   one-line pointer from the main `CLAUDE.md` §8 device note.
7. Verify: `bash -n` all; `device.sh list` / `use "Shreeyak"` / `status` /
   `clear`; dry-run the resolver; a real `build-summary.sh` on the pinned
   device; confirm the offline path errors (pin a bogus UDID).

## Implementation notes & gotchas

- **stdout vs stderr in the resolver is load-bearing:** callers do
  `DESTINATION=$(resolve_ios_destination ...)`, so only the destination goes to
  stdout; all human/error lines go to stderr; error paths emit nothing to
  stdout and `return 1`.
- **The readiness gate is already committed** (`7a4935c`) inline in the two
  xcodebuild wrappers. The redesign **moves** that logic into the shared
  resolver and deletes the inline copies — a refactor/de-dup, behavior-
  preserving.
- **devicectl can hang** when the device channel is wedged (observed). Current
  scripts don't bound it; leave as-is unless it bites.
- **Known iPads:** Shreeyak's iPad Pro 11" (2nd gen, iPad8,9) — xctrace
  `00008027-000539EA0184402E`, devicectl
  `DAD37FD5-685B-50E0-911E-F9BC40BBDBE5`. Second iPad (iPad A16, iPad15,7) —
  xctrace `00008120-000C1D063C380032` (CoreDevice id not yet recorded). Always
  re-derive via the two `list devices` commands; don't hardcode long-term.
- **Auto-Lock=Never** on the test iPad is the real fix for mid-run locks; the
  pin + gate just make a locked device fail fast. See memory
  `feedback_ipad_lock_and_device_selection`.

## Open questions to settle first

1. **Per-worktree vs shared pin.** `.active-device` via
   `git rev-parse --show-toplevel` lands in each *worktree's* root, so worktrees
   pin independently. Wanted, or should the pin be shared across worktrees
   (common `.git` dir, or `$HOME`)?
2. **`device.sh use` default** — interactive numbered picker, or require an
   explicit name/UDID argument?
3. **File name / location** — `.active-device` at root vs under `.build-logs/`
   vs a different name.
4. **XcodeBuildMCP** bypasses the wrappers (own `session_set_defaults
   deviceId`). Should `device.sh use` also update the MCP session default, or is
   that out of scope?

## Repo state (as of this pause)

- main → branch **merge committed**: `de4d1ed`. Verified on iPad (CameraKit
  suite green, 55/55 Dart tests, clean+warm builds).
- fail-fast gate + `-destination-timeout 15` **committed**: `7a4935c`.
- **Working tree clean** — nothing uncommitted; the redesign starts from a
  clean base.
- `scripts/lib/` exists but is **empty** (git ignores empty dirs; will be filled
  by step 1).
- Branch is ~56 commits + the merge ahead of `origin/main`, **unpushed**.
