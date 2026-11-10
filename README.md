# Logcatnip

A native macOS app for reading Android logcat. It follows every connected device, keeps a separate session
per device (or several per device, each with its own filter), and filters with the same query language as
Android Studio's Logcat window.

## Features

- **Devices and sessions.** Devices appear in the sidebar as adb reports them. Open one or more logcat
  sessions per device; each has its own filter, pause state and buffer. When a device disconnects, its
  sessions keep their logs and resume where they left off when it comes back.
- **Android Studio filter syntax.** `tag:`, `package:`, `process:`, `message:`, `line:`, `level:`, `age:`,
  `is:crash`, `is:stacktrace`, `name:`, plus `pid:` and `tid:`. Every text key supports contains (`key:`),
  exact (`key=:`), regex (`key~:`) and negation (`-key:`). Combine terms with `&`, `|` and parentheses.
  Without operators, same-key terms are ORed and everything else is ANDed, as in Android Studio.
- **package:mine.** List your app's packages in Settings.
- **Fast table.** Hundreds of thousands of entries, level colors, stable per-tag colors, multi-line stack
  traces, column hiding (right-click the header, or View > Modify View…), and follow mode that stops when you
  scroll up. The Package column shows the package; the optional Process column shows the full process name
  (`com.example.app:remote`). Long lines scroll horizontally (trackpad, or ←/→ with the table focused;
  ⌘←/⌘→ jump to either edge), or turn on View > Soft Wrap (⌃⌘L, also in the toolbar) to wrap them inside
  the Message column. Soft wrap is per session, and a new session starts with the last choice. Lines over
  10,000 characters are cut off with an ellipsis when not wrapping; hover for the whole line.
- **View presets.** View > Presets switches a session between **Standard** (date and time, PID-TID, tag,
  package, level, message) and **Compact** (time, tag, level, message). View > Modify View… changes the
  session's view as you watch: the timestamp as date and time, time, epoch seconds, seconds since the
  session's first line (`+12.345s`) or the delta from the previous visible line (`Δ 3 ms`), in local time or
  UTC; PID or PID-TID; a Process column; the width of the Tag, Package and Process columns (dragging a column
  edge changes it too); **Hide repeated**, which blanks a tag, package or process equal to the one in the row
  above (what is visible, so it stays right after filtering and trimming); and tag colors on or off. Any
  change makes the view Custom, and choosing a preset again restores it. Each session has its own view. New
  sessions start with the default in Settings > Log View, or "Use as Default for New Sessions" in the sheet.
  Copy (⌘C, or Copy in the row menu) uses the format you see: the visible columns in their order, with the
  chosen timestamp style, one line per entry, every value in full and nothing blanked as repeated. Export
  stays in `logcat -v long` format.
- **Card layout.** View > Card Layout (also in the toolbar's More menu and in Modify View) shows each entry
  as a card, like Wirecat: the level badge and bold tag on the first line with the time on the right, the
  message below (always wrapped, so Soft Wrap is disabled while cards show), and the PID, TID and
  package underneath. The card shows the fields of the visible columns, so Standard and Compact (which
  keep the layout) choose its fields, and the timestamp and PID formats apply. Hide repeated and the
  column widths belong to the table and apply when you switch back. A click or arrow key selects a whole
  card, and Copy uses the same one-line format as the table. The layout is per session, and
  Settings > Log View sets what new sessions start with.
- **Find in results.** ⌘F opens a find bar that searches the tag and message of the rows shown (after the
  filter), with match case, regex and whole word options. Every match is highlighted, the current one in
  orange, with an "N of M" counter and tick marks on the scroller. Return or ⌘G goes to the next match,
  ⇧Return or ⇧⌘G to the previous (both wrap), ⌘E searches for the selected text or line, and Esc closes the
  bar. ⌘L focuses the filter.
- **Filter from a line.** Right-click a line to show only or hide its tag, package, PID or TID, or set the
  minimum level.
- **Favorites and recents** for filter queries, a match-case toggle, and a minimum-level picker.
- **Import and export.** Export in `logcat -v long` format. Open long or threadtime (`adb logcat` default,
  bug report) files, or drop them on the window.
- Pause, clear the view, clear the device buffer (`logcat -c`), and restart logcat.

## Requirements

- macOS 14 or later
- Xcode 16 / Swift 6 toolchain to build
- `adb` from the Android SDK platform-tools. Logcatnip looks in `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`,
  `~/Library/Android/sdk`, Homebrew and `PATH`, or you can set the path in Settings.

## Build and run

```sh
swift run Logcatnip              # run from the terminal
scripts/build-app.sh             # build build/Logcatnip.app (ad-hoc signed)
open build/Logcatnip.app
```

You can also open `Package.swift` in Xcode and run the `Logcatnip` scheme.

## Tests

```sh
swift test                                   # parser and filter tests
LOGCATNIP_DEVICE_TESTS=1 swift test          # also run against an attached device
```

`LOGCATNIP_DEBUG=1 swift run Logcatnip` prints device and session state to stderr every few seconds.
`LOGCATNIP_FILTER='level:WARN'` sets the filter of new sessions, `LOGCATNIP_FIND='text'` opens the find bar
with that query, and `LOGCATNIP_OPEN=/path/a.txt:/path/b.txt` opens log files at launch. With
`LOGCATNIP_DEBUG=1` the find bar's state is printed too, including a recount from scratch (`check=ok`).
`LOGCATNIP_PERF_TESTS=1 swift test --filter FindPerformance` times find on 500,000 rows.
`LOGCATNIP_WRAP_TOGGLE=<seconds>` toggles soft wrap four times, that far apart, and prints the table's state
after each (`LOGCATNIP_WRAP_SELECT=middle|end|none|<row>` picks the row it selects first, `LOGCATNIP_WRAP_RESIZE=<points>`
resizes the window afterwards, `LOGCATNIP_WRAP_KEYS=1` sends the arrow keys); `LOGCATNIP_SCROLL_BENCH=<pages>`
times scrolling page by page in each mode. With `LOGCATNIP_DEBUG=1` every session also prints a `table:` line,
where `clipped` counts visible wrapped lines taller than their row and `truncated` counts visible unwrapped
lines wider than the Message column; both should stay 0.
`LOGCATNIP_PERF_TESTS=1 swift test --filter WrapPerformance` times the line spans on 500,000 rows.
`LOGCATNIP_VIEW=standard|compact|cards|<json>` sets the view options of new sessions, and
`LOGCATNIP_VIEW_CYCLE=<seconds>` steps the selected session through every timestamp style, the Process
column, hide repeated, tag colors and the card layout, printing after each step what Copy would paste for
the last three entries. `LOGCATNIP_LAYOUT_TOGGLE=1` makes `LOGCATNIP_WRAP_TOGGLE` switch between the table and
cards instead of soft wrap, printing `layout-toggle:` lines. With `LOGCATNIP_DEBUG=1` every session prints its options, and its table a `view:` line with the
column order, whether the header is shown (`header=`), the cells on screen (`cards=[level|tag|time|footer|message]`
in the card layout) and `check=ok`, a comparison of every visible cell with a fresh run of the formatter, and in
cards of every row's height too (`MISMATCH` means a cell was not reloaded after an option change, a filter or a
trim). To pass JSON
as a launch argument, quote it as a property-list string: `-defaultViewOptions '"{\"timestampStyle\":\"time\"}"'`.

## Filter reference

| Query | Matches |
| --- | --- |
| `tag:foo` / `tag=:foo` / `tag~:fo+` | tag contains / equals / matches regex |
| `-tag:foo` | negation; works with every key and with free text |
| `package:com.example` | package (process name before `:`) |
| `process:com.example:remote` | full process name |
| `message:timeout` | message text |
| `line:foo`, `foo`, `"foo bar"` | anywhere in the line |
| `package:mine` | packages listed in Settings |
| `level:WARN` | WARN and above (`V D I W E A` work too) |
| `age:30s`, `age:5m`, `age:2h`, `age:1d` | recent entries only |
| `is:crash`, `is:stacktrace` | crashes and ANRs; entries containing stack frames |
| `pid:1234`, `tid:5678` | process or thread id |
| `name:"My filter"` | names the filter |
| `(tag:a \| tag:b) & level:E` | explicit operators; `&` binds tighter than `\|` |

Unquoted values end at whitespace, `&` or `|` (regex values only at whitespace). Quote values that contain
them.

## Layout

- `Sources/LogcatKit`: parsing (`logcat -v long`, threadtime), the filter language, find, and adb
  (device tracking, logcat streaming, process names). No UI dependencies.
- `Sources/Logcatnip`: the SwiftUI + AppKit app.
- `Tests/LogcatKitTests`: unit tests, plus opt-in device tests.

Long-running adb commands run under a small `sh` watchdog that stops them when the app exits, even if it
crashes.
