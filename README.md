# Logcatnip

A native macOS app for reading Android logcat. It follows every connected device, keeps a separate session
per device (or several per device, each with its own filter), and filters with the same query language as
Android Studio's Logcat window.

## Features

- **Devices and sessions.** Each physical device gets one sidebar row, with icons for how it is connected
  (USB, Wi-Fi, emulator). Open one or more logcat sessions per device; each has its own filter, pause state
  and buffer. Sessions follow the device rather than the adb serial: when it disconnects they keep their
  logs and resume where they left off when it comes back, even on a new Wi-Fi port, as an emulator on
  another port, or over Wi-Fi after you unplug USB. When both USB and Wi-Fi are connected, logs stream over
  USB.
- **Wireless debugging.** Devices › + › Connect over Wi-Fi… (⇧⌘N) pairs an Android 11 or later device with a
  QR code or a pairing code, or connects to `host:port` (recent hosts are remembered). Devices that
  advertise wireless debugging but aren't connected appear under Discovered with a Connect button. Devices
  connected by address can be disconnected from their context menu; adb can't disconnect devices it
  connected over mDNS, so turn off Wireless debugging on the device for those. If `adb server-status` shows
  `mdns_enabled: false`, the window explains how to turn mDNS on.
- **Android Studio filter syntax.** `tag:`, `package:`, `process:`, `message:`, `line:`, `level:`, `age:`,
  `is:crash`, `is:stacktrace`, `name:`, plus `pid:` and `tid:`. Every text key supports contains (`key:`),
  exact (`key=:`), regex (`key~:`) and negation (`-key:`). Combine terms with `&`, `|` and parentheses.
  Without operators, same-key terms are ORed and everything else is ANDed, as in Android Studio.
- **package:mine.** List your app's packages in Settings.
- **Fast table.** Hundreds of thousands of entries, level colors, stable per-tag colors, multi-line stack
  traces, column hiding (right-click the header), and follow mode that stops when you scroll up. Long
  lines scroll horizontally, or turn on Wrap Lines in the toolbar to wrap them to the window width.
- **Filter from a line.** Right-click a line to show only or hide its tag, package, PID or TID, or set the
  minimum level.
- **Favorites and recents** for filter queries, a match-case toggle, and a minimum-level picker.
- **Import and export.** Open Android Studio `.logcat` files (with the filter they were saved with and the
  device), bug reports from `adb bugreport` (`.zip` or `.txt`; the system, event and radio logs open as
  separate sessions, with the device and build fingerprint in the status bar), Firebase Crashlytics logs, and
  threadtime, `-v long`, `-v time` and `-v brief` text. Drop files on the window or use File › Open Log File…
  (⌘O). Large files load in the background with a progress bar and Cancel; Logcatnip keeps the newest entries
  up to Settings › Logcat › Keep up to. File › Save Visible Logs As… (⌘S) and Save All Logs As… (⇧⌘S) save in
  Android Studio's `.logcat` format, which keeps process names, the device, the filter and My packages and
  opens in Android Studio; or as `logcat -v long`, threadtime, or plain text as the table shows it. Big saves
  run in the background with a progress bar and Cancel. Threadtime and old `-v long`
  lines have no year, so Logcatnip takes it from the file's modification date, and a time more than a day
  after that date belongs to the year before. Lines that carry a year (`-v year`) keep it.
- Pause, clear the view, clear the device buffer (`logcat -c`), and restart logcat.
- Android 6.0 and older: their logcat has no `-v epoch` or `-v uid`, so Logcatnip reads device-local times
  (in the Mac's time zone) and shows no uid. It switches automatically when getprop or logcat reports an old
  release.
- If logcat rejects an option, for example an unknown buffer in Settings › Logcat › Buffers, the status bar
  shows logcat's message. Fix the setting and choose Restart Logcat.

## Requirements

- macOS 14 or later
- Xcode 16 / Swift 6 toolchain to build
- `adb` from the Android SDK platform-tools. Logcatnip looks in `$ANDROID_HOME`, `$ANDROID_SDK_ROOT`,
  `~/Library/Android/sdk`, Homebrew and `PATH`, or you can set the path in Settings.
- Wireless pairing needs recent platform-tools with mDNS (`adb mdns check`) and the Mac and device on the
  same network.

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
`LOGCATNIP_WIFI_SHEET=qr|code|ip` opens the Connect over Wi-Fi sheet, `LOGCATNIP_WIFI_CONNECT=host:port|discovered`
connects, and `LOGCATNIP_WIFI_PAIR="host:port|discovered CODE"` pairs, without clicking.
`LOGCATNIP_OPEN=/path/a.txt:/path/b.txt` opens log files at launch; with `LOGCATNIP_DEBUG=1` the report shows a
file's first and last times as the table shows them and as Export writes them. With `LOGCATNIP_DEBUG=1` the
report also shows `mainLagMax`, the longest main-thread stall in the last few seconds, and a `file:` line per
opened file (format, load progress, device).
`LOGCATNIP_SAVE=/path/out.logcat` saves the selected session once after `LOGCATNIP_SAVE_DELAY` seconds (default 5),
as `LOGCATNIP_SAVE_FORMAT=logcat|long|threadtime|plainText` and `LOGCATNIP_SAVE_SCOPE=all|visible`; the debug
report then shows a `save:` line.

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

- `Sources/LogcatKit`: parsing (`logcat -v long`, threadtime, `-v brief`), reading and writing saved logs
  (Android Studio `.logcat` files, bug reports, chunked and off the main thread), the filter language, and adb
  (device tracking, logcat streaming, process names, wireless pairing and mDNS discovery). No UI
  dependencies.
- `Sources/Logcatnip`: the SwiftUI + AppKit app.
- `Tests/LogcatKitTests`: unit tests, plus opt-in device tests.

Long-running adb commands run under a small `sh` watchdog that stops them when the app exits, even if it
crashes.
