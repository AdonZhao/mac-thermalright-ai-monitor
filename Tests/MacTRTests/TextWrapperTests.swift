// TextWrapperTests.swift — wrap/truncate correctness and the measurement cache.

import AppKit
import Testing

@testable import MacTR

/// Fake measurer: every character is 10pt wide, and it counts how many times
/// the wrapper had to measure a string.
private final class CountingMeasure {
    var calls = 0
    func measure(_ s: String, _ font: NSFont) -> CGFloat {
        calls += 1
        return CGFloat(s.count) * 10
    }
}

@Test("wrap breaks lines at the width limit")
func wrapBreaksAtWidth() {
    let font19 = NSFont.systemFont(ofSize: 19)
    let m = CountingMeasure()
    let w = TextWrapper(measure: m.measure)

    #expect(w.wrap("abcdefg", font: font19, maxW: 30, maxLines: 10) == ["abc", "def", "g"])
}

@Test("wrap folds the remainder into the last allowed line with an ellipsis")
func wrapFoldsRemainderIntoLastLine() {
    let font19 = NSFont.systemFont(ofSize: 19)
    let w = TextWrapper(measure: CountingMeasure().measure)

    #expect(w.wrap("abcdefghij", font: font19, maxW: 30, maxLines: 2) == ["abc", "de…"])
}

@Test("wrap with no line budget returns nothing")
func wrapZeroMaxLines() {
    let font19 = NSFont.systemFont(ofSize: 19)
    let w = TextWrapper(measure: CountingMeasure().measure)

    #expect(w.wrap("abc", font: font19, maxW: 30, maxLines: 0) == [])
}

@Test("truncate keeps a string that already fits")
func truncateKeepsFittingString() {
    let font19 = NSFont.systemFont(ofSize: 19)
    let w = TextWrapper(measure: CountingMeasure().measure)

    #expect(w.truncate("abcd", font: font19, maxW: 40) == "abcd")
}

@Test("truncate cuts an overlong string and appends an ellipsis")
func truncateCutsOverlongString() {
    let font19 = NSFont.systemFont(ofSize: 19)
    let w = TextWrapper(measure: CountingMeasure().measure)

    #expect(w.truncate("abcdef", font: font19, maxW: 40) == "abc…")
}

@Test("an identical wrap call reuses the cached result instead of re-measuring")
func wrapCachesRepeatedInput() {
    let font19 = NSFont.systemFont(ofSize: 19)
    let m = CountingMeasure()
    let w = TextWrapper(measure: m.measure)

    let first = w.wrap("hello world", font: font19, maxW: 50, maxLines: 3)
    let callsAfterFirst = m.calls
    let second = w.wrap("hello world", font: font19, maxW: 50, maxLines: 3)

    #expect(callsAfterFirst > 0)
    #expect(second == first)
    #expect(m.calls == callsAfterFirst)
}

@Test("an identical truncate call reuses the cached result instead of re-measuring")
func truncateCachesRepeatedInput() {
    let font19 = NSFont.systemFont(ofSize: 19)
    let m = CountingMeasure()
    let w = TextWrapper(measure: m.measure)

    let first = w.truncate("hello world", font: font19, maxW: 50)
    let callsAfterFirst = m.calls
    let second = w.truncate("hello world", font: font19, maxW: 50)

    #expect(callsAfterFirst > 0)
    #expect(second == first)
    #expect(m.calls == callsAfterFirst)
}

@Test("a cached result for one font is not returned for another")
func differentFontsDoNotShareEntries() {
    let font19 = NSFont.systemFont(ofSize: 19)
    let m = CountingMeasure()
    let w = TextWrapper(measure: m.measure)
    let semibold = NSFont.systemFont(ofSize: 19, weight: .semibold)

    _ = w.truncate("abcdef", font: font19, maxW: 40)
    let callsAfterFirst = m.calls
    _ = w.truncate("abcdef", font: semibold, maxW: 40)

    #expect(m.calls > callsAfterFirst)
}

@Test("the cache stays bounded: overflowing evicts, evicted entries re-measure")
func cacheStaysBounded() {
    let font19 = NSFont.systemFont(ofSize: 19)
    let m = CountingMeasure()
    let w = TextWrapper(maxEntries: 2, measure: m.measure)

    _ = w.truncate("aaaa", font: font19, maxW: 30)
    _ = w.truncate("bbbb", font: font19, maxW: 30)
    _ = w.truncate("cccc", font: font19, maxW: 30)
    let callsBefore = m.calls

    #expect(w.truncate("aaaa", font: font19, maxW: 30) == "aa…")
    #expect(m.calls > callsBefore)
}
