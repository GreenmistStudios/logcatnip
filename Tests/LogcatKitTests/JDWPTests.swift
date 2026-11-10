import Foundation
import Testing
@testable import LogcatKit

@Suite struct JDWPTrackDecoderTests {
    private func decode(_ chunks: [Data]) -> [Set<Int32>] {
        var decoder = JDWPTrackDecoder()
        return chunks.flatMap { decoder.feed($0) }
    }

    /// Real `adb track-jdwp` output (adb 37.0.1, emulator API 37): a 4-hex-digit length, then pids one per
    /// line. adb repeats unchanged lists.
    @Test func decodesRealTrackJDWPOutput() {
        let text = "00053194\n000b3194\n30267\n000b3194\n30267\n00053194\n"
        #expect(decode([Data(text.utf8)]) == [[3194], [3194, 30267], [3194, 30267], [3194]])
    }

    @Test func decodesAcrossChunkBoundaries() {
        let bytes = Array("00053194\n000b3194\n30267\n000b3194\n30267\n00053194\n".utf8)
        let chunks = bytes.map { Data([$0]) }
        #expect(decode(chunks) == [[3194], [3194, 30267], [3194, 30267], [3194]])
    }

    @Test func emptyListIsAnUpdate() {
        #expect(decode([Data("0000".utf8)]) == [[]])
    }

    @Test func skipsNonNumericLines() {
        // Length 9 covers `abc\n0\n12\n`; 0 and abc are not pids.
        #expect(decode([Data("0009abc\n0\n12\n".utf8)]) == [[12]])
    }

    @Test func dropsBufferWhenOutOfSync() {
        var decoder = JDWPTrackDecoder()
        #expect(decoder.feed(Data("zzzz0005".utf8)).isEmpty)
        #expect(decoder.feed(Data("00053194\n".utf8)) == [[3194]])
    }
}

@Suite struct JDWPProcessSetTests {
    @Test func firstListIsBaseline() {
        var set = JDWPProcessSet()
        #expect(set.apply([1, 2]).isEmpty)
        let change = set.apply([2, 3])
        #expect(change.added == [3])
        #expect(change.removed == [1])
        #expect(set.apply([2, 3]).isEmpty)
        #expect(set.pids == [2, 3])
    }

    @Test func removalsAndAdditionsAreSorted() {
        var set = JDWPProcessSet()
        _ = set.apply([5, 1, 9])
        let change = set.apply([7, 2])
        #expect(change.added == [2, 7])
        #expect(change.removed == [1, 5, 9])
    }
}
