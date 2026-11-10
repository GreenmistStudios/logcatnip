import Foundation

/// What the minimum-level picker shows for a filter.
public enum LevelSelection: Hashable, Sendable {
    /// The filter has no level terms.
    case any
    /// The filter only passes entries at this level or above.
    case minimum(LogLevel)
    /// Level terms the picker cannot express, such as `is:error` or `(level:E | tag:x)`.
    case mixed
}

extension LogFilter {
    /// The minimum level every entry that passes the filter satisfies, for the level picker. It reads the
    /// parsed filter rather than the query text, so `is:error` or a level inside parentheses is not mistaken
    /// for a `level:` term the picker could edit.
    ///
    /// The floor is the highest top-level `level:` conjunct: other conjuncts only narrow the result further.
    /// A `level:` inside an `&` chain (`level:W & tag:a`) counts as that floor too, but the editor never edits
    /// inside such a chain, so picking another level appends a term instead.
    public var levelSelection: LevelSelection {
        guard let root else { return .any }
        var conjuncts: [FilterNode] = []
        func collect(_ node: FilterNode) {
            if case let .and(nodes) = node {
                nodes.forEach(collect)
            } else {
                conjuncts.append(node)
            }
        }
        collect(root)
        let minimums = conjuncts.compactMap { node -> LogLevel? in
            if case let .predicate(.minLevel(level)) = node { level } else { nil }
        }
        if let highest = minimums.max() { return .minimum(highest) }
        return root.containsLevelPredicate ? .mixed : .any
    }
}

extension FilterNode {
    fileprivate var containsLevelPredicate: Bool {
        switch self {
        case let .predicate(predicate):
            switch predicate {
            case .minLevel, .exactLevel: true
            default: false
            }
        case let .not(node): node.containsLevelPredicate
        case let .and(nodes), let .or(nodes): nodes.contains { $0.containsLevelPredicate }
        }
    }
}

/// Edits a filter query the way the context menu and the level picker need: a new term always narrows the whole
/// query and never joins an OR with what is already there.
///
/// Appending text does neither. `tag:a | tag:b -tag=:c` used to bind the new term to the last branch, and
/// `tag:Net tag=:Http` ORs two terms with the same key. The editor works on the parsed top-level elements
/// instead: it replaces the lone terms a new term would be ORed with, keeps the user's own text for everything
/// else, and wraps the query in parentheses only when a term has to be ANDed with a top-level `|`.
public enum FilterQueryEditor {
    /// `value` as a filter value, quoted only when it needs to be.
    public static func quoted(_ value: String) -> String {
        let needsQuotes = value.isEmpty || value.contains { $0.isWhitespace || "\"'()&|\\".contains($0) }
        return needsQuotes ? quote(value) : value
    }

    /// ANDs one term (`tag=:Foo`, `-package=:com.x`, `pid:12`, `level:WARN`) with the whole query. A non-negated
    /// term first removes the top-level terms it would be ORed with, so "Show Only" replaces rather than widens.
    /// Terms inside parentheses or `&`/`|` expressions are never edited; the new term is ANDed beside them.
    public static func adding(_ term: String, to query: String) -> String {
        guard let parsedTerm = ParsedTerm(term) else { return plainAppend(query, term) }
        return edit(query, term: parsedTerm) { lone in
            guard !parsedTerm.negated, !lone.negated else { return false }
            return lone.key == parsedTerm.key || (parsedTerm.group != nil && lone.group == parsedTerm.group)
        }
    }

    /// Replaces the top-level `level:` and `is:<level>` terms with `level:<level>`, or removes them for `nil`.
    /// Level terms inside parentheses, `&` or `|` expressions are left alone and the new term is ANDed beside
    /// them: `(level:E | tag:x)` becomes `(level:E | tag:x) level:WARN`.
    public static func settingMinimumLevel(_ level: LogLevel?, in query: String) -> String {
        let term = level.flatMap { ParsedTerm("level:\($0.name)") }
        return edit(query, term: term) { lone in !lone.negated && lone.group == .level }
    }

    // MARK: Parsing

    /// A query lexed and parsed into its top-level elements, with the text each one came from.
    private struct ParsedQuery {
        let chars: [Character]
        let tokens: [LocatedToken]
        let elements: [FilterParser.TopLevelElement]
        let parser: FilterParser

        init?(_ query: String) {
            guard let located = try? FilterLexer.locatedTokens(query) else { return nil }
            var parser = FilterParser(tokens: located.map(\.token), caseSensitive: false)
            guard let elements = try? parser.parseTopLevelElements() else { return nil }
            self.chars = Array(query)
            self.tokens = located
            self.elements = elements
            self.parser = parser
        }

        /// The original characters of an element, from its first token to its last.
        func text(of element: FilterParser.TopLevelElement) -> String {
            let range = tokens[element.tokens.lowerBound].range.lowerBound..<tokens[element.tokens.upperBound - 1].range.upperBound
            return String(chars[range])
        }

        /// The key and negation of an element that is exactly one term.
        func loneTerm(of element: FilterParser.TopLevelElement) -> LoneTerm? {
            guard element.tokens.count == 1, case let .term(key, _, _, negated, _) = tokens[element.tokens.lowerBound].token else {
                return nil
            }
            return LoneTerm(key: key, negated: negated, group: element.element.orGroup)
        }

        /// Whether the element has a `|` outside parentheses, which a following `&` term would not reach.
        func hasTopLevelOr(_ element: FilterParser.TopLevelElement) -> Bool {
            var depth = 0
            for token in tokens[element.tokens] {
                switch token.token {
                case .leftParen: depth += 1
                case .rightParen: depth -= 1
                case .or where depth == 0: return true
                default: break
                }
            }
            return false
        }
    }

    private struct LoneTerm {
        let key: FilterKey
        let negated: Bool
        /// The implicit-OR group, which is `nil` for negated terms and `package:mine`.
        let group: ImplicitOrGroup?
    }

    /// A term to add: exactly one element that is exactly one `key:value` token.
    private struct ParsedTerm {
        let text: String
        let key: FilterKey
        let negated: Bool
        let group: ImplicitOrGroup?
        let element: FilterParser.Element

        init?(_ text: String) {
            guard let parsed = ParsedQuery(text), parsed.elements.count == 1,
                  let lone = parsed.loneTerm(of: parsed.elements[0])
            else { return nil }
            self.text = text
            self.key = lone.key
            self.negated = lone.negated
            self.group = lone.group
            self.element = parsed.elements[0].element
        }
    }

    // MARK: Editing

    /// Applies one edit: removes the lone top-level terms `removes` accepts, puts `term` where the first one was
    /// (or appends it), and checks that the result means what the edit says.
    private static func edit(_ query: String, term: ParsedTerm?, removing removes: (LoneTerm) -> Bool) -> String {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = ParsedQuery(query) else {
            // Appending to an invalid query could make it valid with another meaning (`tag:a |` plus a term
            // would read as an OR), so keep it invalid and let the user see their own error.
            guard let term else { return query }
            return wrapped(trimmed, term)
        }

        let removed = parsed.elements.map { element in parsed.loneTerm(of: element).map(removes) ?? false }
        let candidate: String
        if removed.contains(true) {
            candidate = replacing(removed, with: term, in: parsed)
        } else if let term {
            let needsParentheses = parsed.elements.contains { parsed.hasTopLevelOr($0) }
            candidate = needsParentheses ? wrapped(trimmed, term) : plainAppend(query, term.text)
        } else {
            return query
        }

        var expected = parsed.elements.enumerated().map { index, element in
            removed[index] ? FilterParser.Element(node: .predicate(.always), isName: true) : element.element
        }
        if let term { expected.append(term.element) }
        // The stand-in for a removed element is a name, which `combine` skips after flushing pending phrase
        // words, so words that were apart before the edit stay apart.
        let expectedTree = parsed.parser.combine(expected)?.canonical

        guard let filter = try? LogFilter(candidate), filter.root?.canonical == expectedTree else {
            // Only pathological input gets here, such as a query ending in a lone `\` that escapes the space
            // before the new term. Over-narrowing is better than a term that silently ORs.
            guard let term else { return query }
            let fallback = wrapped(trimmed, term)
            return (try? LogFilter(fallback)) == nil ? query : fallback
        }
        // Keep the user's spelling when the edit changes nothing (`level:w` + Warn, Hide Tag twice).
        if let original = try? LogFilter(query), original.root?.canonical == filter.root?.canonical {
            return query
        }
        return candidate
    }

    /// The query with the removed elements dropped and the term in the place of the first one, joined with
    /// single spaces.
    private static func replacing(_ removed: [Bool], with term: ParsedTerm?, in parsed: ParsedQuery) -> String {
        var pieces: [String] = []
        var termPlaced = term == nil
        /// The original index of the last unquoted free-text word emitted, while it is the previous piece.
        var lastWord: Int?
        var index = 0
        while index < parsed.elements.count {
            defer { index += 1 }
            let element = parsed.elements[index]
            if removed[index] {
                if !termPlaced, let term {
                    pieces.append(term.text)
                    termPlaced = true
                    lastWord = nil
                }
                continue
            }
            guard element.element.phraseWord != nil else {
                pieces.append(parsed.text(of: element))
                lastWord = nil
                continue
            }
            if let previous = lastWord, previous != index - 1 {
                // Removing what separated two free-text runs would glue their words into one phrase, so quote
                // this run to keep it a phrase of its own.
                var words: [String] = []
                var next = index
                while next < parsed.elements.count, !removed[next], let word = parsed.elements[next].element.phraseWord {
                    words.append(word)
                    next += 1
                }
                pieces.append(quote(words.joined(separator: " ")))
                lastWord = nil
                index = next - 1
            } else {
                pieces.append(parsed.text(of: element))
                lastWord = index
            }
        }
        if !termPlaced, let term { pieces.append(term.text) }
        return pieces.joined(separator: " ")
    }

    /// `(<query>) & <term>`: the term applies to the whole query, whatever its top-level structure.
    private static func wrapped(_ trimmedQuery: String, _ term: ParsedTerm) -> String {
        trimmedQuery.isEmpty ? term.text : "(\(trimmedQuery)) & \(term.text)"
    }

    private static func plainAppend(_ query: String, _ term: String) -> String {
        let base = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return base.isEmpty ? term : "\(base) \(term)"
    }

    private static func quote(_ value: String) -> String {
        let escaped = value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
