# Integration tests — manual prerequisites

These tests run on a physical iPad (no simulators on this project). Three setup
steps must be done *before* running:

## 1. Pre-grant camera permission

iOS asks for camera permission on first use and the prompt blocks the
integration test runner. Trigger it once manually:

1. Build + run the example app on the iPad.
2. Tap "Grant" when the permission gate appears.
3. Verify the preview lane shows live frames.
4. Background the app (home button) and close it.

Future test runs inherit the granted permission. (Photos-add permission is
likewise prompted on the first capture — grant it once the same way if you want
Test 1's capture to also publish to Photos; the test itself only asserts the
on-disk file, so this is optional.)

## 2. Disable auto-lock

```
Settings → Display & Brightness → Auto-Lock → Never
```

The Recording test holds the camera open for 2+ seconds while frames are
written; an auto-lock during that window faults the AVCaptureSession.

## 3. Manual home-button press for Test 2

Test 2 (Lifecycle transitions) emits a `print()` line:

```
INTEGRATION_PROMPT: press the home button now, then bring the app back
```

When you see that, **physically press the home button** on the iPad, wait
2 seconds, then re-open the app from the home screen. The test resumes once
`stateStream` reports `.streaming` again.

This is a v1 limitation — v1.1 will automate the press via `XCUIDevice`.

## Running

Tests 1 (Smoke) and 3 (Recording) run unattended. Test 2 (Lifecycle) needs the
manual press above, so run it on its own when you can attend the device.

```bash
cd flutter/example

# Unattended (Smoke + Recording):
flutter test integration_test/plugin_test.dart \
  --device-id=<xctrace UDID> \
  --plain-name "Smoke"
flutter test integration_test/plugin_test.dart \
  --device-id=<xctrace UDID> \
  --plain-name "Recording"

# Attended (Lifecycle — watch for INTEGRATION_PROMPT):
flutter test integration_test/plugin_test.dart \
  --device-id=<xctrace UDID> \
  --plain-name "Lifecycle"
```

`<xctrace UDID>` is the build/test identifier from `xcrun xctrace list devices`
(not the devicectl UUID). Integration tests run with the flutter tool attached,
so the debug engine initializes normally (unlike app-hosted `RunnerTests`, which
need the SceneDelegate XCTest guard).
