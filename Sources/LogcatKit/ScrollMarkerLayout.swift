import Foundation

/// Where to draw scroller tick marks for marked rows. Shared by find matches and, later, the crash
/// navigator.
public enum ScrollMarkerLayout {
    /// Pixel runs, top to bottom, in `0..<trackLength`. `rows` must be sorted. A pixel is marked when a
    /// marked row falls in the rows it stands for, so the cost is O(trackLength · log rows.count) and
    /// stays flat when every row is marked. Runs are at least `minLength` long so a single row in a big
    /// table is still visible.
    public static func runs(rows: [Int], rowCount: Int, trackLength: Int, minLength: Int = 2) -> [Range<Int>] {
        guard !rows.isEmpty, rowCount > 0, trackLength > 0 else { return [] }

        var runs: [Range<Int>] = []
        func add(start: Int, end: Int) {
            var start = start
            var end = max(end, start + minLength)
            if end > trackLength {
                start = max(0, trackLength - minLength)
                end = trackLength
            }
            if let last = runs.last, start <= last.upperBound {
                runs[runs.count - 1] = last.lowerBound..<max(last.upperBound, end)
            } else {
                runs.append(start..<end)
            }
        }

        var runStart: Int?
        for pixel in 0..<trackLength {
            let low = pixel * rowCount / trackLength
            let high = min(max((pixel + 1) * rowCount / trackLength, low + 1), rowCount)
            let marked = containsRow(in: low..<high, rows: rows)
            if marked {
                if runStart == nil { runStart = pixel }
            } else if let start = runStart {
                add(start: start, end: pixel)
                runStart = nil
            }
        }
        if let start = runStart { add(start: start, end: trackLength) }
        return runs
    }

    /// Whether the sorted `rows` has an element in `range`.
    private static func containsRow(in range: Range<Int>, rows: [Int]) -> Bool {
        var low = 0
        var high = rows.count
        while low < high {
            let mid = (low + high) / 2
            if rows[mid] < range.lowerBound { low = mid + 1 } else { high = mid }
        }
        return low < rows.count && rows[low] < range.upperBound
    }
}
