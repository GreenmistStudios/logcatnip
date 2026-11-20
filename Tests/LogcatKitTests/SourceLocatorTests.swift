import Foundation
import Testing
@testable import LogcatKit

/// A throwaway Gradle-shaped project. Removed when the value is dropped by the test.
private final class FakeProject {
    let root: URL

    init() throws {
        let temporary = FileManager.default.temporaryDirectory
            .appending(path: "SourceLocatorTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        // `/var` is a link to `/private/var`, and the enumerator reports real paths. `resolvingSymlinksInPath()`
        // maps them back to `/var`, so it can't be used here.
        let real = try #require(realpath(temporary.path, nil))
        defer { free(real) }
        root = URL(fileURLWithPath: String(cString: real), isDirectory: true)
        try add("app/src/main/java/com/example/app/MainActivity.kt")
        try add("app/src/debug/java/com/example/app/MainActivity.kt")
        try add("feature/src/main/java/com/example/feature/MainActivity.kt")
        try add("app/src/main/kotlin/ui/SettingsScreen.kt")
        try add("app/src/main/java/com/example/app/Helper.kt")
        try add("lib/src/main/java/com/other/Helper.kt")
        try add("app/build/generated/source/com/example/app/Generated.kt")
        try add("app/.gradle/com/example/app/Cached.kt")
        try add("app/src/main/cpp/native-lib.cpp")
        try add("app/src/main/res/layout/activity_main.xml")
    }

    deinit {
        try? FileManager.default.removeItem(at: root)
    }

    func add(_ relative: String) throws {
        let url = root.appending(path: relative)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("// \(relative)\n".utf8).write(to: url)
    }

    func path(_ relative: String) -> String {
        root.appending(path: relative).path
    }
}

private func frame(_ line: String) throws -> JavaFrame {
    try #require(JavaFrame.parse(line))
}

@Suite struct SourceLocatorTests {
    @Test func findsTheFileAtItsPackagePath() throws {
        let project = try FakeProject()
        let locator = SourceLocator(roots: [project.root])
        let location = try #require(locator.locate(try frame("at com.example.app.MainActivity.onCreate(MainActivity.kt:42)")))
        // The debug source set has the same package path; main wins.
        #expect(location.url.path == project.path("app/src/main/java/com/example/app/MainActivity.kt"))
        #expect(location.line == 42)

        let feature = locator.locate(try frame("at com.example.feature.MainActivity.onResume(MainActivity.kt:7)"))
        #expect(feature?.url.path == project.path("feature/src/main/java/com/example/feature/MainActivity.kt"))
    }

    @Test func nestedAndSyntheticClassesUseTheOuterPackage() throws {
        let project = try FakeProject()
        let locator = SourceLocator(roots: [project.root])
        let expected = project.path("app/src/main/java/com/example/app/MainActivity.kt")
        for line in [
            "at com.example.app.MainActivity$Inner.run(MainActivity.kt:10)",
            "at com.example.app.MainActivity$onCreate$1.invoke(MainActivity.kt:11)",
            "at com.example.app.MainActivity$lambda$0.invoke(MainActivity.kt:12)",
            "at com.example.app.MainActivity$$ExternalSyntheticLambda0.run(D8$$SyntheticClass:0)",
        ] {
            let parsed = try frame(line)
            if parsed.file == "MainActivity.kt" {
                #expect(locator.locate(parsed)?.url.path == expected, "\(line)")
            } else {
                #expect(locator.locate(parsed) == nil, "\(line)")
            }
        }
    }

    @Test func fallsBackToAUniqueFileNameButNotAnAmbiguousOne() throws {
        let project = try FakeProject()
        let locator = SourceLocator(roots: [project.root])
        // Kotlin files don't have to sit at their package path.
        let settings = locator.locate(try frame("at com.example.app.ui.SettingsScreen.render(SettingsScreen.kt:3)"))
        #expect(settings?.url.path == project.path("app/src/main/kotlin/ui/SettingsScreen.kt"))
        // Two MainActivity.kt files and neither in com.unknown.
        #expect(locator.locate(try frame("at com.unknown.MainActivity.onCreate(MainActivity.kt:1)")) == nil)
        // Two Helper.kt files; the package picks one.
        let helper = locator.locate(try frame("at com.other.Helper.help(Helper.kt:5)"))
        #expect(helper?.url.path == project.path("lib/src/main/java/com/other/Helper.kt"))
    }

    @Test func frameworkFramesNeedTheirPackagePath() throws {
        let project = try FakeProject()
        try project.add("app/src/main/java/com/example/app/View.java")
        let locator = SourceLocator(roots: [project.root])
        // A project file with the same name is not the framework's.
        #expect(locator.locate(try frame("at android.view.View.performClick(View.java:7448)")) == nil)
        #expect(locator.locate(try frame("at java.lang.Thread.run(Thread.java:1012)")) == nil)
        #expect(locator.locate(try frame("at kotlinx.coroutines.DispatchedTask.run(DispatchedTask.kt:108)")) == nil)

        // Unless a source folder really has it, such as an AOSP checkout.
        try project.add("aosp/frameworks/base/core/java/android/view/View.java")
        locator.invalidate()
        let view = locator.locate(try frame("at android.view.View.performClick(View.java:7448)"))
        #expect(view?.url.path == project.path("aosp/frameworks/base/core/java/android/view/View.java"))
    }

    @Test func skipsBuildOutputAndCaches() throws {
        let project = try FakeProject()
        let locator = SourceLocator(roots: [project.root])
        #expect(locator.locate(try frame("at com.example.app.Generated.make(Generated.kt:1)")) == nil)
        #expect(locator.locate(try frame("at com.example.app.Cached.make(Cached.kt:1)")) == nil)
    }

    @Test func doesNotFollowSymbolicLinksOutOfTheRoot() throws {
        let project = try FakeProject()
        let outside = try FakeProject()
        try outside.add("secret/com/example/app/Secret.kt")
        try FileManager.default.createSymbolicLink(
            at: project.root.appending(path: "linked"), withDestinationURL: outside.root.appending(path: "secret")
        )
        try FileManager.default.createSymbolicLink(
            at: project.root.appending(path: "app/src/main/java/com/example/app/Secret.kt"),
            withDestinationURL: outside.root.appending(path: "secret/com/example/app/Secret.kt")
        )
        let locator = SourceLocator(roots: [project.root])
        #expect(locator.locate(try frame("at com.example.app.Secret.run(Secret.kt:1)")) == nil)
    }

    @Test func rejectsFileNamesThatArePaths() {
        #expect(SourceReference(fileName: "../../etc/passwd") == nil)
        #expect(SourceReference(fileName: "/etc/passwd") == nil)
        #expect(SourceReference(fileName: "..") == nil)
        #expect(SourceReference(fileName: "") == nil)
        #expect(SourceReference(frame: JavaFrame(className: "com.example.Foo", method: "bar", file: "../Foo.kt", line: 1)) == nil)
        // A package with path syntax in it ranks nothing rather than walking anywhere.
        let reference = SourceReference(fileName: "Foo.kt", packagePath: ["..", "etc"])
        #expect(reference?.packagePath == [])
    }

    @Test func cachedLookupNeverWalks() throws {
        let project = try FakeProject()
        let locator = SourceLocator(roots: [project.root])
        let reference = try #require(SourceReference(frame: try frame("at com.example.app.Helper.help(Helper.kt:5)")))
        #expect(locator.cachedLookup(reference) == .pending)
        #expect(locator.indexDate == nil)
        locator.prepare()
        #expect(locator.cachedLookup(reference) == .found(SourceLocation(
            url: URL(fileURLWithPath: project.path("app/src/main/java/com/example/app/Helper.kt")), line: 5
        )))
        let missing = try #require(SourceReference(frame: try frame("at com.example.app.Gone.run(Gone.kt:1)")))
        #expect(locator.cachedLookup(missing) == .notFound)

        // New files show up after a rebuild; until then the old index answers.
        try project.add("app/src/main/java/com/example/app/Gone.kt")
        #expect(locator.cachedLookup(missing) == .notFound)
        locator.rebuild()
        #expect(locator.cachedLookup(missing) != .notFound)
        locator.invalidate()
        #expect(locator.cachedLookup(missing) == .pending)
    }

    @Test func cancelledWalkKeepsNoPartialIndex() async throws {
        let project = try FakeProject()
        let locator = SourceLocator(roots: [project.root])
        let task = Task.detached { () -> Date? in
            // Sleep returns as soon as the task is cancelled, so the walk below always starts cancelled.
            try? await Task.sleep(for: .seconds(60))
            locator.prepare()
            return locator.indexDate
        }
        task.cancel()
        #expect(await task.value == nil)
        locator.prepare()
        #expect(locator.indexDate != nil)
        let built = try #require(locator.indexDate)

        let rebuild = Task.detached { () -> Date? in
            try? await Task.sleep(for: .seconds(60))
            locator.rebuild()
            return locator.indexDate
        }
        rebuild.cancel()
        #expect(await rebuild.value == built)
    }

    @Test func nativeFramesWithASourceFile() throws {
        let project = try FakeProject()
        let locator = SourceLocator(roots: [project.root])
        let line = "#01 pc 0000000000012345  /data/app/~~a==/com.example.app-1/lib/arm64/libnative.so (crashMe(int)+20) (native-lib.cpp:42)"
        let reference = try #require(SourceReference(nativeLine: line))
        #expect(reference.displayName == "native-lib.cpp:42")
        #expect(locator.locate(reference)?.url.path == project.path("app/src/main/cpp/native-lib.cpp"))
        #expect(SourceReference(line: "  " + line) == reference)

        let withPathAndColumn = "#01 pc 0000000000012345  /data/app/libnative.so (crashMe+20) (../src/native-lib.cpp:42:7) (BuildId: abc)"
        #expect(SourceReference(nativeLine: withPathAndColumn)?.displayName == "native-lib.cpp:42")
        // No symbol, or no source group: nothing to open.
        #expect(SourceReference(nativeLine: "#01 pc 0000000000012345  /data/app/libnative.so (native-lib.cpp:42)") == nil)
        #expect(SourceReference(nativeLine: "#00 pc 000000000004f0c8  /apex/com.android.runtime/lib64/bionic/libc.so (abort+164) (BuildId: 1234)") == nil)
    }

    @Test func topAppFrameMatchesTheSignature() throws {
        let message = """
            java.lang.IllegalStateException: boom
            \tat android.app.Activity.performCreate(Activity.java:8000)
            \tat com.example.app.MainActivity.onCreate(MainActivity.kt:42)
            """
        let top = CrashSignature.topAppFrame(in: message, package: "com.example.app")
        #expect(top?.file == "MainActivity.kt")
        #expect(CrashSignature.javaCrash(message: message, package: "com.example.app").detail == top?.displayText)
        #expect(CrashSignature.topAppFrame(in: message, package: nil)?.file == "Activity.java")
    }
}

@Suite struct EditorLaunchTests {
    private let location = SourceLocation(url: URL(fileURLWithPath: "/Users/me/My Projects/app/Main Activity.kt"), line: 42)

    @Test func androidStudio() {
        #expect(Editor.androidStudio.launch(location) == .process(
            executable: "/usr/bin/open",
            arguments: ["-na", "Android Studio.app", "--args", "--line", "42", "/Users/me/My Projects/app/Main Activity.kt"]
        ))
        let studio = URL(fileURLWithPath: "/Applications/Android Studio.app/Contents/MacOS/studio")
        #expect(Editor.androidStudio.launch(SourceLocation(url: location.url, line: nil), studioExecutable: studio) == .process(
            executable: "/Applications/Android Studio.app/Contents/MacOS/studio",
            arguments: ["/Users/me/My Projects/app/Main Activity.kt"]
        ))
    }

    @Test func urlSchemes() {
        #expect(Editor.intellij.launch(location) == .url(URL(string: "idea://open?file=/Users/me/My%20Projects/app/Main%20Activity.kt&line=42")!))
        #expect(Editor.vscode.launch(location) == .url(URL(string: "vscode://file/Users/me/My%20Projects/app/Main%20Activity.kt:42")!))
        #expect(Editor.cursor.launch(location) == .url(URL(string: "cursor://file/Users/me/My%20Projects/app/Main%20Activity.kt:42")!))
        let ampersand = SourceLocation(url: URL(fileURLWithPath: "/tmp/a&b=c+d#e?.kt"), line: 1)
        #expect(Editor.intellij.launch(ampersand) == .url(URL(string: "idea://open?file=/tmp/a%26b%3Dc%2Bd%23e%3F.kt&line=1")!))
    }

    @Test func customURLTemplate() {
        let launch = Editor.custom.launch(location, customTemplate: "subl://open?url=file://{file}&line={line}")
        #expect(launch == .url(URL(string: "subl://open?url=file:///Users/me/My%20Projects/app/Main%20Activity.kt&line=42")!))
    }

    @Test func customCommandLine() {
        #expect(Editor.custom.launch(location, customTemplate: "zed {file}:{line}") == .process(
            executable: "/usr/bin/env", arguments: ["zed", "/Users/me/My Projects/app/Main Activity.kt:42"]
        ))
        #expect(Editor.custom.launch(location, customTemplate: "'/Applications/My Editor.app/Contents/MacOS/edit' --goto \"{file}:{line}\"") == .process(
            executable: "/Applications/My Editor.app/Contents/MacOS/edit",
            arguments: ["--goto", "/Users/me/My Projects/app/Main Activity.kt:42"]
        ))
        // Shell syntax in the file name stays inside its argument.
        let hostile = SourceLocation(url: URL(fileURLWithPath: "/tmp/$(rm -rf ~); echo.kt"), line: nil)
        #expect(Editor.custom.launch(hostile, customTemplate: "edit {file} {line}") == .process(
            executable: "/usr/bin/env", arguments: ["edit", "/tmp/$(rm -rf ~); echo.kt", "1"]
        ))
        #expect(Editor.custom.launch(location, customTemplate: "") == nil)
        #expect(Editor.custom.launch(location, customTemplate: "edit 'unterminated {file}") == nil)
        #expect(Editor.custom.launch(location, customTemplate: "bin/edit {file}") == nil)
    }

    @Test func customCommandLineProgramIsNeverAPlaceholder() {
        // A file named after a program would otherwise run it.
        let program = SourceLocation(url: URL(fileURLWithPath: "/tmp/evil.kt"), line: 3)
        #expect(Editor.custom.launch(program, customTemplate: "{file}") == nil)
        #expect(Editor.custom.launch(program, customTemplate: "{file} --line {line}") == nil)
        #expect(Editor.custom.launch(program, customTemplate: "'{file}'") == nil)
        #expect(Editor.custom.launch(program, customTemplate: "/usr/local/bin/{line}edit {file}") == nil)
        #expect(Editor.custom.launch(program, customTemplate: "edit{line} {file}") == nil)
    }
}
