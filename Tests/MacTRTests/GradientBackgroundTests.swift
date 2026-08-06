// GradientBackgroundTests.swift — the cached background must equal direct painting.

import CoreGraphics
import Testing

@testable import MacTR

/// A bitmap context flipped the same way render() flips it (Y=0 at top).
private func makeFlippedContext() -> CGContext? {
    let w = Layout.width, h = Layout.height
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    ctx.translateBy(x: 0, y: CGFloat(h))
    ctx.scaleBy(x: 1, y: -1)
    return ctx
}

private func pixelBytes(_ ctx: CGContext) -> [UInt8] {
    guard let data = ctx.data else { return [] }
    let count = ctx.bytesPerRow * ctx.height
    return Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self),
                                     count: count))
}

@Test("the cached background image exists and covers the full panel")
func backgroundImageCoversPanel() throws {
    let image = try #require(Draw.backgroundImage)
    #expect(image.width == Layout.width)
    #expect(image.height == Layout.height)
}

@Test("gradientBackground blits pixels identical to painting the gradient directly")
func cachedBackgroundEqualsDirectPaint() throws {
    let direct = try #require(makeFlippedContext())
    let cached = try #require(makeFlippedContext())

    Draw.paintGradientBackground(direct)
    Draw.gradientBackground(cached)

    let directPixels = pixelBytes(direct)
    #expect(!directPixels.isEmpty)
    #expect(directPixels == pixelBytes(cached))
}
