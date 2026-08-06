// TextWrapper.swift — character wrap / ellipsis truncation with a result cache.

import AppKit

/// Wraps and truncates strings for the dashboard, caching results by
/// (text, font, width).
///
/// The frame loop redraws at up to 15fps while the text it draws only changes
/// every couple of seconds, and measuring text is by far the most expensive
/// thing the loop does — a 10s CPU sample put ~half of the frame thread inside
/// sizeWithAttributes, all reached from wrap/truncate. Caching makes the
/// repeat frames free; the wrap algorithm itself only runs when text changes.
///
/// Takes its own lock: render() is serialized by renderMutex, but
/// renderSimulated() renders outside that lock and reaches the same cache.
final class TextWrapper: @unchecked Sendable {
    typealias Measure = (String, NSFont) -> CGFloat

    /// Fonts come from Fonts.system, which caches per (size, weight), so object
    /// identity distinguishes fonts. An uncached NSFont would merely miss.
    private struct Key: Hashable {
        let text: String
        let font: ObjectIdentifier
        let maxW: CGFloat
        let maxLines: Int
    }

    private let measure: Measure
    private let maxEntries: Int
    private let lock = NSLock()
    private var wrapped: [Key: [String]] = [:]
    private var truncated: [Key: String] = [:]

    init(maxEntries: Int = 1024,
         measure: @escaping Measure = { s, font in
             (s as NSString).size(withAttributes: [.font: font]).width
         }) {
        self.maxEntries = maxEntries
        self.measure = measure
    }

    /// Truncate a single line with "…" to fit maxW.
    func truncate(_ s: String, font: NSFont, maxW: CGFloat) -> String {
        let key = Key(text: s, font: ObjectIdentifier(font), maxW: maxW, maxLines: 0)
        lock.lock()
        if let hit = truncated[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let result = computeTruncate(s, font: font, maxW: maxW)

        lock.lock()
        evictIfFull()
        truncated[key] = result
        lock.unlock()
        return result
    }

    /// Greedy character wrap (activity text may be CJK — no word boundaries).
    func wrap(_ s: String, font: NSFont, maxW: CGFloat, maxLines: Int) -> [String] {
        let key = Key(text: s, font: ObjectIdentifier(font), maxW: maxW, maxLines: maxLines)
        lock.lock()
        if let hit = wrapped[key] {
            lock.unlock()
            return hit
        }
        lock.unlock()

        let result = computeWrap(s, font: font, maxW: maxW, maxLines: maxLines)

        lock.lock()
        evictIfFull()
        wrapped[key] = result
        lock.unlock()
        return result
    }

    /// Must be called with the lock held. Recompute-on-miss is cheap enough
    /// that dumping everything beats bookkeeping an LRU.
    private func evictIfFull() {
        if wrapped.count + truncated.count >= maxEntries {
            wrapped.removeAll(keepingCapacity: true)
            truncated.removeAll(keepingCapacity: true)
        }
    }

    private func computeTruncate(_ s: String, font: NSFont, maxW: CGFloat) -> String {
        if measure(s, font) <= maxW { return s }
        var t = s
        while !t.isEmpty {
            t.removeLast()
            if measure(t + "…", font) <= maxW {
                return t + "…"
            }
        }
        return "…"
    }

    private func computeWrap(_ s: String, font: NSFont, maxW: CGFloat, maxLines: Int) -> [String] {
        guard maxLines >= 1 else { return [] }
        var lines: [String] = []
        var current = ""
        for ch in s {
            let candidate = current + String(ch)
            if measure(candidate, font) > maxW {
                // Reached the last allowed line → fold the whole remainder into it
                if lines.count == maxLines - 1 {
                    let rest = String(s[s.index(s.startIndex, offsetBy: lines.joined().count)...])
                    lines.append(truncate(rest, font: font, maxW: maxW))
                    return lines
                }
                lines.append(current)
                current = String(ch)
            } else {
                current = candidate
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
