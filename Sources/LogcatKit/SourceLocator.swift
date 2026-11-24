import Foundation

/// A file in one of the source folders and the line to open it at.
public struct SourceLocation: Sendable, Hashable {
    public var url: URL
    public var line: Int?

    public init(url: URL, line: Int?) {
        self.url = url
        self.line = line
    }
}

/// The source file a stack frame names, reduced to parts that can't point anywhere by themselves: a file name
/// that is a single path component and package names that only rank files the index already found. Paths
/// are never built from log text, so a hostile log can't reach outside the source folders.
public struct SourceReference: Sendable, Hashable {
    /// `MainActivity.kt`.
    public var fileName: String
    /// `["com", "example", "app"]`, or empty for native frames and classes in the default package.
    public var packagePath: [String]
    public var line: Int?
    /// Whether the class belongs to Android, the JDK or Kotlin. Those open only when a source folder has the
    /// file at its package path, so a project file that happens to share the name isn't opened instead.
    public var isFramework: Bool

    public init?(fileName: String, packagePath: [String] = [], line: Int? = nil, isFramework: Bool = false) {
        guard Self.isSafeFileName(fileName) else { return nil }
        self.fileName = fileName
        self.packagePath = packagePath.allSatisfy(Self.isSafePackageComponent) ? packagePath : []
        self.line = line.flatMap { $0 > 0 ? $0 : nil }
        self.isFramework = isFramework
    }

    /// The file of a Java or Kotlin frame. Nested and synthetic classes (`MainActivity$onCreate$1`) live in
    /// their outer class's package, which is all the lookup needs.
    public init?(frame: JavaFrame) {
        guard let file = frame.file else { return nil }
        let outer = frame.className.prefix { $0 != "$" }
        let package = outer.lastIndex(of: ".").map { outer[..<$0] } ?? ""
        let components = package.split(separator: ".", omittingEmptySubsequences: false).map(String.init)
        self.init(
            fileName: file, packagePath: package.isEmpty ? [] : components, line: frame.line,
            isFramework: Self.isFrameworkClass(frame.className)
        )
    }

    /// The file of a symbolized native frame that also names its source, as in
    /// `#01 pc 00012345  /data/app/…/libnative.so (crashMe+20) (native-lib.cpp:42)`. Frames without both a
    /// symbol and a `(file:line)` group give nil.
    public init?<S: StringProtocol>(nativeLine line: S) {
        guard let frame = NativeFrame.parse(line), let symbol = frame.symbol else { return nil }
        for group in NativeFrame.parenthesizedGroups(Substring(line)).reversed() where group != symbol {
            guard let colon = group.lastIndex(of: ":"), var number = Int(group[group.index(after: colon)...]) else {
                continue
            }
            var path = group[..<colon]
            // `file.cpp:42:7` carries a column too.
            if let inner = path.lastIndex(of: ":"), let lineNumber = Int(path[path.index(after: inner)...]) {
                number = lineNumber
                path = path[..<inner]
            }
            guard number > 0 else { continue }
            let name = path.split(separator: "/").last.map(String.init) ?? ""
            guard SourceLocator.sourceExtensions.contains(Self.pathExtension(of: name)) else { continue }
            self.init(fileName: name, line: number)
            return
        }
        return nil
    }

    /// A Java frame, else a native frame with a source file, from one line of a log message.
    public init?<S: StringProtocol>(line: S) {
        if let frame = JavaFrame.parse(line) {
            self.init(frame: frame)
        } else {
            self.init(nativeLine: line)
        }
    }

    /// `MainActivity.kt:42`, for menu items.
    public var displayName: String {
        line.map { "\(fileName):\($0)" } ?? fileName
    }

    static let frameworkPrefixes = [
        "android.", "androidx.", "java.", "javax.", "kotlin.", "kotlinx.", "com.android.internal.", "dalvik.",
    ]

    public static func isFrameworkClass(_ className: String) -> Bool {
        frameworkPrefixes.contains { className.hasPrefix($0) }
    }

    static func isSafeFileName(_ name: String) -> Bool {
        !name.isEmpty && name.utf8.count <= 255 && name != "." && name != ".."
            && !name.contains { $0 == "/" || $0 == "\\" || $0 == "\0" || $0.isNewline }
    }

    static func isSafePackageComponent(_ component: String) -> Bool {
        !component.isEmpty && component.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    static func pathExtension(of name: String) -> String {
        name.lastIndex(of: ".").map { name[name.index(after: $0)...].lowercased() } ?? ""
    }
}

/// Finds the files that stack frames name in the user's source folders.
///
/// Each folder is walked once into a map of file name to paths, so a lookup is a dictionary access plus a
/// ranking of the few files that share the name. The walk is slow on a big checkout, so it only happens in
/// ``prepare()`` or ``locate(_:)``, which callers run off the main thread; ``cachedLookup(_:)`` never walks.
///
/// `@unchecked Sendable`: `index` and `generation` are only read and written while holding `stateLock`, and
/// walks are serialised by `buildLock` so two callers waiting for the first index don't both walk. A walk
/// runs outside `stateLock`, so lookups never wait for one.
public final class SourceLocator: @unchecked Sendable {
    public enum Lookup: Sendable, Hashable {
        /// The folders haven't been indexed yet.
        case pending
        case found(SourceLocation)
        case notFound
    }

    struct Index {
        var pathsByName: [String: [String]] = [:]
        var date = Date()
    }

    /// Directories that hold build output, caches or other checkouts rather than sources.
    static let skippedDirectories: Set<String> = ["build", ".gradle", ".git", "node_modules", ".idea", ".build"]
    /// Only these are indexed, which keeps the map small in repositories with many assets.
    static let sourceExtensions: Set<String> = [
        "kt", "kts", "java", "scala", "groovy", "aidl",
        "c", "cc", "cpp", "cxx", "h", "hh", "hpp", "hxx", "inl", "m", "mm", "rs", "swift",
    ]

    public let roots: [URL]
    private let stateLock = NSLock()
    private let buildLock = NSLock()
    private var index: Index?
    private var generation = 0

    public init(roots: [URL]) {
        self.roots = roots.map { $0.standardizedFileURL.resolvingSymlinksInPath() }
    }

    /// When the current index was built, nil before the first walk.
    public var indexDate: Date? {
        stateLock.withLock { index?.date }
    }

    /// The location from the index as it is, without walking: `.pending` until ``prepare()`` has run.
    public func cachedLookup(_ reference: SourceReference) -> Lookup {
        guard let index = stateLock.withLock({ index }) else { return .pending }
        return resolve(reference, in: index).map(Lookup.found) ?? .notFound
    }

    /// Walks the folders unless they are indexed already. Blocks; call it off the main thread.
    public func prepare() {
        _ = currentIndex()
    }

    /// Walks the folders again and swaps the new index in, so files added since show up. Lookups keep using the
    /// old index until the walk finishes. Blocks; call it off the main thread.
    /// A cancelled walk stops early and keeps the old index.
    public func rebuild() {
        buildLock.withLock {
            let started = stateLock.withLock { generation }
            let built = walk()
            store(built, ifStillAt: started)
        }
    }

    /// Drops the index; the next ``locate(_:)`` or ``prepare()`` walks again.
    public func invalidate() {
        stateLock.withLock {
            index = nil
            generation += 1
        }
    }

    /// Where the frame's file is, walking the folders first if needed. Blocks; call it off the main thread.
    public func locate(_ frame: JavaFrame) -> SourceLocation? {
        SourceReference(frame: frame).flatMap(locate)
    }

    public func locate(_ reference: SourceReference) -> SourceLocation? {
        resolve(reference, in: currentIndex())
    }

    private func currentIndex() -> Index {
        if let index = stateLock.withLock({ index }) { return index }
        return buildLock.withLock {
            if let index = stateLock.withLock({ index }) { return index }
            let started = stateLock.withLock { generation }
            let built = walk()
            store(built, ifStillAt: started)
            return built
        }
    }

    /// Keeps a walk's index unless ``invalidate()`` ran during it or the walk was cancelled, which leaves it
    /// partial.
    private func store(_ built: Index, ifStillAt started: Int) {
        guard !Task.isCancelled else { return }
        stateLock.withLock {
            if generation == started { index = built }
        }
    }

    private func walk() -> Index {
        var index = Index()
        for root in roots where !Task.isCancelled {
            Self.walk(root, into: &index.pathsByName)
        }
        index.date = Date()
        return index
    }

    /// Indexes regular source files under `root`. Symbolic links are skipped, files and directories alike,
    /// so every indexed path really is inside the folder. Stops early when the current task is cancelled, since
    /// a big checkout takes seconds to walk.
    static func walk(_ root: URL, into pathsByName: inout [String: [String]]) {
        let keys: [URLResourceKey] = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants],
            errorHandler: { _, _ in true }
        ) else { return }
        let keySet = Set(keys)
        for case let url as URL in enumerator {
            if Task.isCancelled { return }
            let name = url.lastPathComponent
            guard let values = try? url.resourceValues(forKeys: keySet), values.isSymbolicLink != true else { continue }
            if values.isDirectory == true {
                if skippedDirectories.contains(name) || name.hasPrefix(".") { enumerator.skipDescendants() }
                continue
            }
            guard values.isRegularFile == true, sourceExtensions.contains(SourceReference.pathExtension(of: name)) else {
                continue
            }
            pathsByName[name, default: []].append(url.path)
        }
    }

    /// Ranks the files with the reference's name by how many trailing directories match its package, so
    /// `com/example/app/MainActivity.kt` beats `com/example/feature/MainActivity.kt` for
    /// `com.example.app.MainActivity`, and a Kotlin file whose folders skip the common prefix still matches.
    /// A file name found only once matches whatever its folder; a name found several times with no package
    /// match is ambiguous and gives nil.
    func resolve(_ reference: SourceReference, in index: Index) -> SourceLocation? {
        guard let candidates = index.pathsByName[reference.fileName], !candidates.isEmpty else { return nil }
        var bestScore = -1
        var best: [String] = []
        for path in candidates {
            let score = Self.matchingPackageComponents(path: path, package: reference.packagePath)
            if score > bestScore {
                bestScore = score
                best = [path]
            } else if score == bestScore {
                best.append(path)
            }
        }
        if reference.isFramework {
            guard !reference.packagePath.isEmpty, bestScore == reference.packagePath.count else { return nil }
        } else if bestScore == 0, best.count > 1 {
            return nil
        }
        // Several copies at the same package path, such as main and debug source sets: prefer main.
        let chosen = best.min { lhs, rhs in
            let lhsMain = lhs.contains("/src/main/"), rhsMain = rhs.contains("/src/main/")
            return lhsMain != rhsMain ? lhsMain : lhs < rhs
        }
        return chosen.map { SourceLocation(url: URL(fileURLWithPath: $0), line: reference.line) }
    }

    static func matchingPackageComponents(path: String, package: [String]) -> Int {
        let directories = path.split(separator: "/").dropLast()
        var count = 0
        for (directory, component) in zip(directories.reversed(), package.reversed()) {
            guard directory == component else { break }
            count += 1
        }
        return count
    }
}

/// How to show a source location: a URL for `NSWorkspace` or a program and its arguments, run without a shell.
public enum EditorLaunch: Sendable, Hashable {
    case url(URL)
    case process(executable: String, arguments: [String])
}

/// The editors Open in Editor supports.
public enum Editor: String, CaseIterable, Sendable, Identifiable {
    case androidStudio
    case intellij
    case vscode
    case cursor
    case custom

    public var id: Self { self }

    public static let androidStudioBundleIdentifier = "com.google.android.studio"

    public var title: String {
        switch self {
        case .androidStudio: "Android Studio"
        case .intellij: "IntelliJ IDEA"
        case .vscode: "Visual Studio Code"
        case .cursor: "Cursor"
        case .custom: "Custom"
        }
    }

    /// The name in menu items: “Open MainActivity.kt:42 in Android Studio”.
    public var menuName: String {
        switch self {
        case .vscode: "VS Code"
        case .custom: "Editor"
        default: title
        }
    }

    /// How to open `location`. `studioExecutable` is Android Studio's `Contents/MacOS/studio`, when the app found
    /// one; without it the launch goes through `open`. A custom editor needs `customTemplate`, with `{file}`
    /// and `{line}` placeholders, and gives nil when it is empty or can't be parsed.
    public func launch(_ location: SourceLocation, customTemplate: String = "", studioExecutable: URL? = nil) -> EditorLaunch? {
        let path = location.url.path
        switch self {
        case .androidStudio:
            let lineArguments = location.line.map { ["--line", String($0)] } ?? []
            if let studioExecutable {
                return .process(executable: studioExecutable.path, arguments: lineArguments + [path])
            }
            return .process(executable: "/usr/bin/open", arguments: ["-na", "Android Studio.app", "--args"] + lineArguments + [path])
        case .intellij:
            var text = "idea://open?file=\(Self.encode(path))"
            if let line = location.line { text += "&line=\(line)" }
            return URL(string: text).map(EditorLaunch.url)
        case .vscode, .cursor:
            let scheme = self == .vscode ? "vscode" : "cursor"
            let suffix = location.line.map { ":\($0)" } ?? ""
            return URL(string: "\(scheme)://file\(Self.encode(path))\(suffix)").map(EditorLaunch.url)
        case .custom:
            return Self.customLaunch(template: customTemplate, path: path, line: location.line)
        }
    }

    /// A URL template (`subl://open?url=file://{file}&line={line}`) or a command line (`zed {file}:{line}`).
    /// Command lines are split into arguments before the placeholders are filled in, so a path with spaces stays
    /// one argument and nothing in it is ever read as shell syntax.
    static func customLaunch(template: String, path: String, line: Int?) -> EditorLaunch? {
        let template = template.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !template.isEmpty else { return nil }
        let lineText = String(line ?? 1)
        if isURLTemplate(template) {
            let text = template
                .replacingOccurrences(of: "{file}", with: encode(path))
                .replacingOccurrences(of: "{line}", with: lineText)
            return URL(string: text).map(EditorLaunch.url)
        }
        guard let tokens = splitArguments(template), let first = tokens.first else { return nil }
        // The file name comes from a device log, so it must never choose the program that runs.
        guard !first.contains("{file}"), !first.contains("{line}") else { return nil }
        let arguments = tokens.map {
            $0.replacingOccurrences(of: "{file}", with: path).replacingOccurrences(of: "{line}", with: lineText)
        }
        let program = (arguments[0] as NSString).expandingTildeInPath
        if first.contains("/") {
            guard program.hasPrefix("/") else { return nil }
            return .process(executable: program, arguments: Array(arguments.dropFirst()))
        }
        // A bare command name is looked up on PATH by env, which doesn't involve a shell.
        return .process(executable: "/usr/bin/env", arguments: arguments)
    }

    static func isURLTemplate(_ template: String) -> Bool {
        guard let separator = template.range(of: "://") else { return false }
        let scheme = template[..<separator.lowerBound]
        return scheme.first?.isLetter == true
            && scheme.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == ".") }
    }

    /// Splits like a shell would for words, single and double quotes and backslashes, and nothing else: no
    /// variables, globs or operators. Nil for an unterminated quote.
    static func splitArguments(_ text: String) -> [String]? {
        var arguments: [String] = []
        var current = ""
        var inWord = false
        var quote: Character?
        var escaped = false
        for character in text {
            if escaped {
                current.append(character)
                escaped = false
            } else if let open = quote {
                if character == open {
                    quote = nil
                } else if character == "\\" && open == "\"" {
                    escaped = true
                } else {
                    current.append(character)
                }
            } else if character == "\\" {
                escaped = true
                inWord = true
            } else if character == "'" || character == "\"" {
                quote = character
                inWord = true
            } else if character.isWhitespace {
                if inWord { arguments.append(current) }
                current = ""
                inWord = false
            } else {
                current.append(character)
                inWord = true
            }
        }
        guard quote == nil, !escaped else { return nil }
        if inWord { arguments.append(current) }
        return arguments
    }

    /// Percent-encodes a path for a URL's path or query: spaces, `&`, `?`, `#`, `+` and the like, but not `/`.
    static func encode(_ path: String) -> String {
        var allowed = CharacterSet.urlPathAllowed
        allowed.remove(charactersIn: "?#&=+;")
        return path.addingPercentEncoding(withAllowedCharacters: allowed) ?? path
    }
}
