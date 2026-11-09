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
  traces, column hiding (right-click the header), and follow mode that stops when you scroll up.
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
`LOGCATNIP_FILTER='level:WARN'` sets the filter of new sessions.

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

- `Sources/LogcatKit`: parsing (`logcat -v long`, threadtime), the filter language, and adb
  (device tracking, logcat streaming, process names). No UI dependencies.
- `Sources/Logcatnip`: the SwiftUI + AppKit app.
- `Tests/LogcatKitTests`: unit tests, plus opt-in device tests.

Long-running adb commands run under a small `sh` watchdog that stops them when the app exits, even if it
crashes.
