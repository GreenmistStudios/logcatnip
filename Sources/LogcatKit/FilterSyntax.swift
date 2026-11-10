import Foundation

/// One colored stretch of a filter query.
public struct FilterSyntaxSpan: Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        /// `tag:`, `-tag=:`, `level:`, `name:`: the key with its leading `-` and its operator.
        case key
        /// An unquoted value of a term that is not a regular expression.
        case value
        /// A quoted value of a term that is not a regular expression, quotes included.
        case quotedValue
        /// The value of a `~:` term, quoted or not.
        case regexValue
        /// Unquoted free text, and a lone `-`.
        case text
        /// Quoted free text.
        case quotedText
        /// `&`, `&&`, `|` and `||`.
        case logicalOperator
        case parenthesis
    }

    public let kind: Kind
    /// Character offsets into the query.
    public let range: Range<Int>
}

public struct FilterHighlighting: Sendable, Equatable {
    public let spans: [FilterSyntaxSpan]
    /// The error `LogFilter` reports for the query, if any.
    public let error: FilterError?
}

public enum FilterSyntax {
    /// Spans from the lenient lexer, so a half-typed or invalid query is still colored. The error comes from a
    /// full parse of the same text, so the underline always matches what the field shows rather than the
    /// debounced filter the session applied.
    public static func highlighting(for query: String) -> FilterHighlighting {
        let chars = Array(query)
        var spans: [FilterSyntaxSpan] = []
        for located in FilterLexer.scan(query).tokens {
            switch located.token {
            case .leftParen, .rightParen:
                spans.append(FilterSyntaxSpan(kind: .parenthesis, range: located.range))
            case .and, .or:
                spans.append(FilterSyntaxSpan(kind: .logicalOperator, range: located.range))
            case let .text(_, _, quoted, _):
                spans.append(FilterSyntaxSpan(kind: quoted ? .quotedText : .text, range: located.range))
            case let .term(_, op, _, _, _):
                guard let value = located.valueRange else { continue }
                spans.append(FilterSyntaxSpan(kind: .key, range: located.range.lowerBound..<value.lowerBound))
                guard !value.isEmpty else { continue }
                let kind: FilterSyntaxSpan.Kind = if op == .regex {
                    .regexValue
                } else if chars[value.lowerBound] == "\"" || chars[value.lowerBound] == "'" {
                    .quotedValue
                } else {
                    .value
                }
                spans.append(FilterSyntaxSpan(kind: kind, range: value))
            }
        }
        // Case sensitivity cannot change whether a query is valid.
        do {
            _ = try LogFilter(query)
            return FilterHighlighting(spans: spans, error: nil)
        } catch {
            return FilterHighlighting(spans: spans, error: error)
        }
    }
}

/// Converts between the `Character` offsets LogcatKit uses and the UTF-16 offsets of `NSString` and `NSRange`,
/// which AppKit text views use. They differ for emoji and combined characters.
public struct FilterTextOffsets: Sendable {
    /// The UTF-16 offset where each character starts, then the total length.
    private let boundaries: [Int]

    public init(_ text: String) {
        var boundaries = [0]
        boundaries.reserveCapacity(text.count + 1)
        var total = 0
        for character in text {
            total += character.utf16.count
            boundaries.append(total)
        }
        self.boundaries = boundaries
    }

    public var characterCount: Int { boundaries.count - 1 }

    /// The UTF-16 offset of a character offset, clamped to the text.
    public func utf16(_ characterOffset: Int) -> Int {
        boundaries[min(max(characterOffset, 0), characterCount)]
    }

    /// The character containing a UTF-16 offset, or the boundary at it. An offset inside a surrogate pair or a
    /// combined character maps to the start of that character.
    public func character(forUTF16 offset: Int) -> Int {
        var low = 0
        var high = characterCount
        while low < high {
            let mid = (low + high + 1) / 2
            if boundaries[mid] <= offset { low = mid } else { high = mid - 1 }
        }
        return low
    }

    public func nsRange(_ range: Range<Int>) -> NSRange {
        let start = utf16(range.lowerBound)
        return NSRange(location: start, length: utf16(range.upperBound) - start)
    }
}
