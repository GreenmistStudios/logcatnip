# AGENTS.md

Guidance for coding agents working on Logcatnip, a native macOS (SwiftUI + AppKit) viewer for Android
logcat. Read `README.md` for user-facing features and the filter reference.

## Commands

```sh
swift build                                  # debug build
swift run Logcatnip                          # run from the terminal
swift test                                   # parser and filter tests (what CI runs)
LOGCATNIP_DEVICE_TESTS=1 swift test          # also run device tests; needs adb and an online device
scripts/build-app.sh                         # build build/Logcatnip.app (release, ad-hoc signed)
CONFIG=debug scripts/build-app.sh            # debug app bundle
```

Debug helpers: `LOGCATNIP_DEBUG=1` prints device and session state to stderr every few seconds;
`LOGCATNIP_FILTER='level:WARN'` sets the filter of new sessions; `LOGCATNIP_FIND='text'` opens the find bar
with that query (the debug output then includes `find=... check=ok|MISMATCH`, a recount from scratch);
`LOGCATNIP_OPEN=/path/a.txt:/path/b.txt` opens log files at launch. `LOGCATNIP_PERF_TESTS=1 swift test
--filter FindPerformance` runs the opt-in find timings on 500,000 rows (`--filter WrapPerformance` times the
line spans). With `LOGCATNIP_DEBUG=1` each session also prints a `table:` line (soft wrap state, the Message
column, the selection, `clipped` and `truncated` counts); `LOGCATNIP_WRAP_TOGGLE=<seconds>` toggles soft wrap
four times and prints it after each (`LOGCATNIP_WRAP_SELECT=middle|end|none|<row>`, `LOGCATNIP_WRAP_RESIZE=<points>`
and `LOGCATNIP_WRAP_KEYS=1` add a selection, a window resize and the arrow keys), and
`LOGCATNIP_SCROLL_BENCH=<pages>` times scrolling in each mode. Use them to check wrapping from a terminal,
since screenshots of the Mac are off limits. `LOGCATNIP_VIEW=standard|compact|cards|<json>` sets the view options
of new sessions and `LOGCATNIP_VIEW_CYCLE=<seconds>` steps the selected session through every style (the card
layout included); `LOGCATNIP_LAYOUT_TOGGLE=1` makes `LOGCATNIP_WRAP_TOGGLE` switch between table and cards. With
`LOGCATNIP_DEBUG=1` each session prints its options and the table a `view:` line (column order, `header=`,
on-screen cells or `cards=[...]`, and `check=ok`, a recount of every visible cell, and in cards every row's
height, against the formatter). JSON launch arguments must be
quoted as plist strings: `-defaultViewOptions '"{\"timestampStyle\":\"time\"}"'`.

CI (`.github/workflows/ci.yml`, `macos-15`, Xcode 16.4) runs `swift build`, `swift test` and
`scripts/build-app.sh`. Run all three before you call a change done.

## Requirements

- macOS 14+, Swift 6 toolchain (`swift-tools-version: 6.0`, Swift 6 language mode with strict concurrency).
- `adb` is needed only to run the app or the device tests, not to build or run the unit tests.

## Layout

- `Sources/LogcatKit/`: UI-free library. Keep AppKit and SwiftUI out of it.
  - `ADB.swift`: locating adb, `StreamingProcess` (child processes under an `sh` watchdog so they die
    with the app), device tracking, logcat streaming.
  - `Devices.swift`: `adb track-devices` decoding and device properties.
  - `LogcatParser.swift`, `LogcatTime.swift`: `logcat -v long` and threadtime parsing.
  - `LogFilter.swift`: the Android Studio filter language (tokenizer, parser, compiled predicates).
  - `LogEntry.swift`, `LogLevel.swift`, `LogClassifier.swift`: the model, levels, crash and stack trace
    detection.
  - `LogFinder.swift`: find-in-results queries (plain, regex, whole word) and the rows they match.
  - `FindResults.swift`: matching row indexes kept across appends, front trims and resets, and the
    next/previous jump targets.
  - `ScrollMarkerLayout.swift`: pixel runs for scroller tick marks (find now, the crash navigator later).
  - `MessageLines.swift`: per-line spans and display widths of a message, computed once per row so the
    table sizes wrapped rows and the Message column without touching the text.
  - `ViewportAnchor.swift`: which row to hold still, and where to scroll, when row heights change.
  - `LogViewOptions.swift`: a session's view (columns, timestamp and PID style, widths, hide repeated, tag
    colors, table or card layout), the Standard and Compact presets (which ignore the layout), and lenient
    JSON for the saved default. `LogcatTime` formats the timestamp styles.
  - `LogLineFormatter.swift`: the text of every cell, of a copied line and of a card for a set of view
    options, so the table, Copy and the card layout agree.
  - `LogCardLayout.swift`: card geometry (row heights, wrap width) as plain arithmetic.
- `Sources/Logcatnip/`: the app.
  - `AppModel.swift`: `@MainActor @Observable` root state: adb, devices, sessions.
  - `LogSession.swift`: one logcat stream per session: buffer, filter, pause state.
  - `LogTableView.swift`: `NSViewRepresentable` around `NSTableView`. The table is AppKit on purpose,
    because SwiftUI lists do not scroll smoothly with hundreds of thousands of rows. Its card layout code
    sits in the `// MARK: Cards` section.
  - `LogCardViews.swift`: the card layout's cell view (header, message, footer) and row view (the card
    background across the rows of one entry).
  - `FindController.swift`, `FindBar.swift`: the find bar, its state, and incremental off-main scans.
  - `ScrollMarkers.swift`: the tick marks drawn over the table's vertical scroller, one layer per kind of
    mark.
  - `LogColors.swift`: level and per-tag colors, close to Android Studio's, for light and dark mode.
  - `Settings.swift`, `SettingsView.swift`: `SettingsKey` / `Defaults` (UserDefaults) and the settings UI.
  - `ViewOptionsView.swift`: the Modify View form and sheet, the preset picker and menu items.
- `Tests/LogcatKitTests/`: Swift Testing (`import Testing`, `@Suite`, `@Test`, `#expect`). Device tests
  are gated on `LOGCATNIP_DEVICE_TESTS=1`.
- `scripts/build-app.sh`: assembles the `.app` bundle and writes `Info.plist` inline (bundle id
  `studio.greenmist.logcatnip`). Add new bundle resources, such as an app icon, here.
- `design/`: the app icon. `render-icons.swift` draws the concepts into `icons/` and the chosen one into
  `AppIcon.png`, which `scripts/build-app.sh` turns into `AppIcon.icns` with `sips` and `iconutil`. To
  change the icon, edit the script, run `swift design/render-icons.swift`, and commit the PNGs.

## Conventions

- Parsing, filtering and adb logic go in `LogcatKit` with unit tests. The app target has no test target,
  so keep logic out of views where you can.
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

- Default branch: `master`. Remote: `GreenmistStudios/logcatnip`; use the `geoff-powell` gh account.
- Commit subjects use conventional commits: `feat: ...`, `fix: ...`, lowercase and imperative. Reference
  issues in the body (`Fixes #8.`).
- Other agents may have uncommitted work in the tree. Stage only your own files.
