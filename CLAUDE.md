# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Overview

RedQuits3 is a native macOS menu-bar utility (Swift/AppKit, arm64, macOS 13+). When you click a window's red close button, it sends that app a normal quit request, the same as ⌘Q, unless the app has a child window open. There is no Xcode project, SwiftPM package, dependency, linter or CI. `build.sh` calls `swiftc` directly.

## Commands

```sh
./build.sh                                                        # deletes dist/, then compiles, bundles, ad-hoc signs → dist/RedQuits3.app
./dist/RedQuits3.app/Contents/MacOS/RedQuits3 --selftest          # the only automated test; expect "selftest OK", exit 0
Tests/build-fixture.sh                                            # test fixture → dist/WindowFixture.app (after build.sh, which clears dist/)
RQ3_DEBUG=1 /Applications/RedQuits3.app/Contents/MacOS/RedQuits3  # foreground run with per-click logs; quit the menu-bar copy first
swift Scripts/GenerateIcons.swift && iconutil -c icns Assets/RedQuits3.iconset -o Assets/RedQuits3.icns  # regenerate icons
```

- **Source files:** `build.sh` lists them explicitly on the `swiftc` line, so add any new file in `Sources/` there.
- **Info.plist:** `build.sh` generates it from a heredoc (version, bundle ID, `LSUIElement`). Keep `LSMinimumSystemVersion` in step with `-target arm64-apple-macos13.0`.
- **Self-test:** run it from inside the built bundle, because it checks `Bundle.main` for the icons and a bare `swiftc` binary fails that check.
  - It's a list of `check(condition, expectation)` calls in `selfTest()` (`Sources/App.swift`), not a test framework, so you can't run a single check on its own. A failure prints `selftest failed: <expectation>` and exits 1.
  - It covers only logic that needs no Accessibility permission or real windows. Decision logic lives in free functions and structs (`allowedApp`, `PendingClick`, `WindowTraits.isChild`) that it calls directly.
  - Test the click path by hand, with permission granted, against Safari or the window fixture below.
- **Accessibility after rebuilds:** each rebuild changes the ad-hoc signature, so the rebuilt app usually has to be removed and re-added under Privacy & Security → Accessibility.

### Window fixture

`Tests/WindowFixture.swift` is a standalone app, never compiled into the main app. Build it with `Tests/build-fixture.sh`: RedQuits3 ignores apps without a bundle identifier, so a bare `swiftc` build of the fixture is never quit.

```sh
dist/WindowFixture.app/Contents/MacOS/WindowFixture <tmp>/fixture.json [--child-window] [--refuse-quit]   # output path must come first
```

- **Output:** it writes `{pid, x, y, windows}`, plus `childX`/`childY` with `--child-window`. These are close-button centers in global top-left-origin coordinates (the space `CGEvent` and AX use); `x`/`y` belongs to the second regular window.
- **Close vs. quit:** it keeps running after its windows close, so a quit can be told apart from a close. On quit it logs `FIXTURE: quit accepted; visible windows remaining=N`.
- **`--child-window`:** adds a Settings-style window (no minimize button), so RedQuits3 should quit nothing.
- **`--refuse-quit`:** it declines termination instead, as if the user cancelled a save prompt.
- **Checking without clicks:** compile `Sources/App.swift` with a scratch `main.swift` that launches the fixture and calls `closeButtonTarget(at:)` at its coordinates. That runs the real AX hit-test and child-window rule without synthesizing input. It needs Accessibility permission for the terminal.

## Architecture

`Sources/main.swift` handles `--selftest` before `NSApplication` starts, then runs `AppDelegate`. Everything else is in `Sources/App.swift`.

**Click detection** (`AppDelegate.handleMouse`) uses a global `NSEvent` monitor on left mouse-down/up. A global monitor can only observe events, so the target app still closes its own window. RedQuits3 just adds a quit request.
- **Mouse-down:** `closeButtonTarget(at:)` hit-tests through AX and takes the hit element's window.
  - Only that window's own `kAXCloseButtonAttribute` button counts, and only if it's enabled and contains the point. Other elements that report the close-button subrole don't count.
  - It then applies the child-window rule and returns the app and the button frame.
  - This has to happen on mouse-down, because the window may be gone by mouse-up.
- **Mouse-up:** calls `NSRunningApplication.terminate()` only if the release lands inside that frame.
- **Coordinates:** points come from `event.cgEvent?.location`, which uses a top-left origin like AX frames. `NSEvent.mouseLocation` uses a bottom-left origin, so don't swap it in.

**Child windows** (`WindowTraits.isChild`, read by `windowTraits(_:)`): if the clicked window or any window in the app's `kAXWindowsAttribute` is a child window, the app isn't quit. The rule rests on what AX reported for probe windows on macOS 27:
- NSPanel windows (dialogs, alerts, About) report `AXDialog`, utility panels `AXFloatingWindow`, and HUD panels `AXSystemFloatingWindow`.
- Settings windows, AppKit and SwiftUI alike, are `AXStandardWindow` with a disabled minimize button; regular windows have it enabled. Full-screen windows have it disabled too, hence the `AXFullScreen` exception.
- A sheet isn't listed in `kAXWindowsAttribute` (it's an `AXSheet` child of its window). It does disable its parent's close button, which is how it's detected.
- Panels hide while their app is inactive (`hidesOnDeactivate`), so a background app's palettes aren't listed and don't block.
- Native tab close buttons have no subrole. Windows attached with `addChildWindow` look like ordinary windows and can't be detected.
- Windows without a close button (borderless popups, overlays) are ignored unless modal. A window whose subrole can't be read, or an app whose window list can't be read, blocks the quit.

**Eligibility** (`eligible` and `allowedApp`) is checked on both mouse-down and mouse-up. It allows only `.regular` activation-policy apps with a bundle identifier. It never allows RedQuits3 itself, anything under `/System/Library/`, or anything in `excludedApps`. The prefix is deliberately `/System/Library/` and not `/System/`: Safari lives under `/System/Cryptexes/…` and must stay quittable, which the self-test asserts.

**Permission:** a 1-second timer (`updatePermission`) polls `AXIsProcessTrusted()` and installs or removes the monitor as trust changes.

**Timeouts:** at launch, a 0.5 s messaging timeout set on the system-wide element applies to every AX call (the default is 6 s). A hung app therefore can't stall the main thread for long; a timed-out hit-test just means no quit.

**Single instance:** a `flock` on `~/.redquits3.lock` makes any second copy log `another instance is running` and exit. That includes a debug run started while the installed app is running.

**Config:** `Store` loads `~/Library/Application Support/RedQuits3/config.json` once, so edits need a relaunch. Only the menu's Enabled toggle saves it.
- `Config.init(from:)` gives missing keys their defaults, so a new field must be decoded there with `decodeIfPresent`. It lives in an extension so the memberwise initializer survives. A mistyped value still makes the file invalid.
- If the file can't be decoded, auto-quit is disabled and `Store.save()` refuses to overwrite it (`loadFailed`). The toggle then shows an alert instead of wiping the user's exclusions.

**Bundle ID:** `com.wzygadlo.RedQuits3` is hard-coded in `build.sh`, `allowedApp()` and `selfTest()`. Change all three together. The fixture uses `com.wzygadlo.RedQuits3.WindowFixture`.

**Logging:** all log lines are `NSLog` calls prefixed `RQ3:`. `RQ3_DEBUG` (`debugLogging`) adds per-click reasons. `log show` displays them as `<private>`, so read them by running the binary in a terminal.

## Behavior to preserve

From the README:
- Quit only with a normal quit request (`terminate()`): never `forceTerminate()`, and no timed retries. The target app keeps control of its save prompts, so cancelling one cancels the quit.
- ⌘W, minimizing, and releasing outside the close button must not trigger a quit.
- While an app has a child window open, including the one being closed, don't quit it.
- No network code or telemetry.
- `--selftest` must not alter user settings, so keep it away from `Store`. That includes `eligible` and `closeButtonTarget`, which read it.
- The code and icons are original. Nothing from the classic RedQuits is included.

## Assets and commits

- **Icons:** `Scripts/GenerateIcons.swift` draws them with AppKit alone. Its PNG and `.icns` output in `Assets/` is committed, and `build.sh` copies it without regenerating. `Assets/RedQuits3.iconset/` is a gitignored intermediate.
- **Before committing:** run `./build.sh` and `--selftest`. Never commit `dist/` or user `config.json` settings.
