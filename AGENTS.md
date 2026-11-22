# AGENTS.md

Guidance for coding agents working on Logcatnip, a native macOS (SwiftUI + AppKit) viewer for Android
logcat. Read `README.md` for user-facing features and the filter reference.

## Commands

```sh
swift build                                  # debug build
swift run Logcatnip                          # run from the terminal
swift test                                   # parser, filter and screenshot tests (what CI runs)
LOGCATNIP_DEVICE_TESTS=1 swift test          # also run device tests; needs adb and an online device
LOGCATNIP_SIMULATOR_TESTS=1 swift test       # also run simulator tests; needs Xcode and a booted simulator
LOGCATNIP_RECORD_SNAPSHOTS=1 swift test      # rewrite the screenshot references
scripts/build-app.sh                         # build build/Logcatnip.app (release, ad-hoc signed)
CONFIG=debug scripts/build-app.sh            # debug app bundle
VERSION=1.2.3 scripts/build-app.sh           # set the bundle version (default: newest vX.Y.Z tag, else 0.0.0)
UNIVERSAL=1 scripts/build-app.sh             # arm64 + x86_64, as the release workflow builds it
SIGN_IDENTITY="Developer ID Application: …" scripts/build-app.sh   # Developer ID + hardened runtime, as releases sign
VERSION=1.2.3 SIGN_IDENTITY=… NOTARY_PROFILE=… scripts/package-release.sh   # notarized DMG + zip (SKIP_NOTARIZE=1 to try)
LOGCATNIP_SIGNING_IDENTITY="Developer ID Application: …" swift test   # also test team pinning with a real certificate
scripts/next-version.sh [--bump auto|patch|minor|major]   # the version the next release would get
```

Debug helpers: `LOGCATNIP_DEBUG=1` prints device and session state to stderr every few seconds;
`LOGCATNIP_FILTER='level:WARN'` sets the filter of new sessions; `LOGCATNIP_FIND='text'` opens the find bar
with that query (the debug output then includes `find=... check=ok|MISMATCH`, a recount from scratch);
`LOGCATNIP_OPEN=/path/a.txt:/path/b.txt` opens log files at launch. `LOGCATNIP_PERF_TESTS=1 swift test
--filter FindPerformance` runs the opt-in find timings on 500,000 rows. `LOGCATNIP_WIFI_SHEET=qr|code|ip`,
`LOGCATNIP_WIFI_CONNECT=host:port|discovered` and `LOGCATNIP_WIFI_PAIR="host:port|discovered CODE"` drive the
Connect over Wi-Fi flows without clicking; the debug report has a `wireless:` line.
`LOGCATNIP_UPDATE_CHECK=1` runs Check for Updates… at launch and `LOGCATNIP_UPDATE_INSTALL=1` installs what it finds
without clicking; `LOGCATNIP_UPDATE_FEED=/path/release.json|URL` and `LOGCATNIP_UPDATE_VERSION=0.1.0` point it at a
local feed and fake the running version. With `LOGCATNIP_DEBUG=1` each step logs an `update:` line.

CI (`.github/workflows/ci.yml`, `macos-15`, Xcode 16.4) runs `swift build`, `swift test` and
`scripts/build-app.sh`, and uploads the zipped app as an artifact. Run all three before you call a change done.

Releases (`.github/workflows/release.yml`) run on every push to `main`: `scripts/next-version.sh` picks the bump
from the conventional commits since the last `vX.Y.Z` tag (breaking → major, minor before 1.0; `feat` → minor;
`fix`/`perf`/`refactor`/`revert` → patch; anything else → no release), then the workflow tests, builds with
`VERSION` and the Developer ID from the repository secrets, notarizes with `scripts/package-release.sh`, and
publishes a GitHub release with `Logcatnip-X.Y.Z.dmg`, `Logcatnip-X.Y.Z.zip` and a `.sha256` for each. The updater
only reads the zip. Tags are the only version
record; nothing is committed back. The commit type you choose therefore decides the release, so pick it with care.
A Developer ID build only accepts updates signed by its own team (`UpdateInstaller.signingTeam`), so never publish
an ad-hoc signed release once signed ones exist.

## Requirements

- macOS 14+, Swift 6 toolchain (`swift-tools-version: 6.0`, Swift 6 language mode with strict concurrency).
- `adb` is needed only to run the app or the device tests, not to build or run the unit tests.

## Layout

- `Sources/LogcatKit/`: UI-free library. Keep AppKit and SwiftUI out of it.
  - `ADB.swift`: locating adb, `StreamingProcess` (child processes under an `sh` watchdog so they die
    with the app), device tracking, logcat streaming.
  - `Devices.swift`: `adb track-devices` decoding and device properties.
  - `DeviceIdentity.swift`: device identity (serial number, AVD name, mDNS serial), transport kind, and
    matching sessions to transports.
  - `Simctl.swift`, `Simulators.swift`: finding `simctl` without triggering the Xcode install prompt, polling
    booted simulators, and streaming `log stream` from one.
  - `UnifiedLogParser.swift`: `log stream --style ndjson` parsing into `LogEntry`.
  - `Wireless.swift`: mDNS service parsing and tracking (`adb mdns`), the QR pairing payload, `adb pair`,
    `connect` and `disconnect` output, and matching discovered services to devices.
  - `LogcatParser.swift`, `LogcatTime.swift`: `logcat -v long` and threadtime parsing.
  - `LogFilter.swift`: the Android Studio filter language (tokenizer, parser, compiled predicates).
  - `FilterQueryEditor.swift`: structural edits for the context menu and level picker (a new term ANDs with the
    whole query), and `LogFilter.levelSelection`, the picker's value read from the parsed filter.
  - `ProcessNameResolver.swift`: pid -> process name from `ps` snapshots (and later process start/death
    events), keyed by ingestion order so reused pids and processes that start mid-lookup resolve correctly.
  - `ProcessEvents.swift`: ActivityManager `Start proc` lines, which name a pid before `ps` can.
  - `PackageUIDs.swift`: `pm list packages -U` parsing, uid -> package map and when to refresh it.
  - `LogEntry.swift`, `LogLevel.swift`, `LogClassifier.swift`: the model, levels, crash and stack trace
    detection.
  - `LogSignal.swift`, `CrashSignature.swift`: signal rules (crashes, native crashes, ANRs, out of memory, leaks,
    jank) as data, and the signatures that group identical occurrences.
  - `SignalIndex.swift`: a session's signal occurrences and groups, kept across appends and front trims, with
    native crash and ANR bursts collapsed into one occurrence.
  - `LogFinder.swift`: find-in-results queries (plain, regex, whole word) and the rows they match.
  - `FindResults.swift`: matching row indexes kept across appends, front trims and resets, and the
    next/previous jump targets.
  - `ScrollMarkerLayout.swift`: pixel runs for scroller tick marks (find now, the crash navigator later).
  - `SoftwareUpdate.swift`: `SemanticVersion`, the GitHub Releases feed, and the updater's download, SHA-256 and
    bundle checks, and the shell that swaps the app after it quits.
  - `UpdateController.swift`: the update flow (check, skip, daily schedule, download, install) as a
    `@MainActor @Observable` state machine over `UpdateServices`, so tests drive it with fakes.
- `Sources/Logcatnip/`: the app.
  - `AppModel.swift`: `@MainActor @Observable` root state: adb, devices, sessions.
  - `LogSession.swift`: one logcat stream per session: buffer, filter, pause state.
  - `LogTableView.swift`: `NSViewRepresentable` around `NSTableView`. The table is AppKit on purpose,
    because SwiftUI lists do not scroll smoothly with hundreds of thousands of rows.
  - `FindController.swift`, `FindBar.swift`: the find bar, its state, and incremental off-main scans.
  - `ScrollMarkers.swift`: the tick marks drawn over the table's vertical scroller, one layer per kind of
    mark.
  - `LogColors.swift`: level and per-tag colors, close to Android Studio's, for light and dark mode.
  - `WirelessModel.swift`, `WirelessConnectView.swift`, `QRCodeImage.swift`: the Connect over Wi-Fi sheet,
    its QR code, and the sidebar's Discovered list.
  - `Settings.swift`, `SettingsView.swift`: `SettingsKey` / `Defaults` (UserDefaults) and the settings UI.
  - `Updater.swift`: wires `UpdateController` to the bundle and the `LOGCATNIP_UPDATE_*` hooks, the Software Update
    window and the Check for Updates… command.
- `Tests/LogcatKitTests/`: Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). `Fixtures/` holds
  `-v long -v epoch -v uid` logs in real device wording, loaded with `Bundle.module`. Device tests
  are gated on `LOGCATNIP_DEVICE_TESTS=1`. Update tests never touch the network: `UpdateTestSupport.swift` has a
  `MockURLProtocol` (one host per test, so parallel suites don't collide) and builds signed fake app bundles.
- `Tests/LogcatnipTests/`: screenshot tests of the app (it `@testable import`s the executable target).
  `Snapshot.swift` renders a SwiftUI view in an offscreen window at 2x and compares it with
  `__Snapshots__/macOS-<major>/<name>.png`; mismatches write `.actual.png` and `.diff.png` files to
  `.build/snapshot-failures/`. `SessionScreenshotTests.swift` holds the fixture log.
- `scripts/install.sh`: the `curl | bash` installer in the README. It installs the latest (or `LOGCATNIP_VERSION`)
  release without quarantine, so Gatekeeper doesn't block it (that matters for the ad-hoc releases before 0.4).
  Keep it working with macOS's bash 3.2 and the release asset names in `release.yml`; CI installs the latest
  release with it.
- `scripts/next-version.sh`: the next release version from conventional commits, for the release workflow.
- `scripts/build-app.sh`: assembles the `.app` bundle and writes `Info.plist` inline (bundle id
  `studio.greenmist.logcatnip`). Add new bundle resources, such as an app icon, here. With `SIGN_IDENTITY` it signs
  with the hardened runtime; if the app ever needs an entitlement, pass `--entitlements` here.
- `scripts/package-release.sh`: checks a Developer ID build, makes the DMG (app + Applications link), notarizes it
  with `notarytool`, staples the DMG and the app, and zips the stapled app for the updater.
- `design/`: the app icon. `render-icons.swift` draws the concepts into `icons/` and the chosen one into
  `AppIcon.png`, which `scripts/build-app.sh` turns into `AppIcon.icns` with `sips` and `iconutil`. To
  change the icon, edit the script, run `swift design/render-icons.swift`, and commit the PNGs.

## Conventions

- Parsing, filtering and adb logic go in `LogcatKit` with unit tests. The app target only has screenshot
  tests, so keep logic out of views where you can.
- For a visible UI change, add or update a screenshot test, open the recorded PNG and check it before you
  commit it. References are per macOS major version: a missing one is recorded and fails the test once
  (CI only records). Re-record intended changes with `LOGCATNIP_RECORD_SNAPSHOTS=1` and review the PNG diff.
  Views rendered in tests take settings as values (see `SessionContent`) rather than reading
  `@AppStorage`. Blur materials, such as the table header's, are not captured, so size views so the
  table does not scroll.
- Use Swift Testing for new tests, not XCTest. Write a failing test first for parser and filter bugs.
- Mark public `LogcatKit` types `Sendable`. Use `@unchecked Sendable` only for lock-guarded boxes, and
  explain the locking in a comment.
- UI state is `@MainActor @Observable`. Use `@ObservationIgnored` for tasks and caches.
- Long-running child processes must use `StreamingProcess(..., stopsWithParent: true)` so they do not
  outlive the app.
- New settings get a key in `SettingsKey` and a default in `Defaults.register()`; read them with
  `@AppStorage` in views.
- The filter language must match Android Studio's Logcat behavior. When you change it, update the
  filter reference table in `README.md` and add tests in `FilterTests.swift`.
- Keep the table fast: avoid per-row allocations and work in `tableView(_:viewFor:row:)` and
  `heightOfRow`, and test with large buffers (`maxEntries` defaults to 250,000).
- Write doc comments that explain why, not what. Match the existing style: short `///` summaries and no
  banner comments.
- Avoid new dependencies. The package has none.

## Git

- Default branch: `main`. Remote: `GreenmistStudios/logcatnip`; use the `geoff-powell` gh account.
- Commit subjects use conventional commits: `feat: ...`, `fix: ...`, lowercase and imperative. Reference
  issues in the body (`Fixes #8.`).
- Other agents may have uncommitted work in the tree. Stage only your own files.
- Pull requests that change visible UI include screenshots in the description, before and after when
  something existing changed. The screenshot test PNGs in `Tests/LogcatnipTests/__Snapshots__/` work for
  this. Skip it for changes with nothing to see.
