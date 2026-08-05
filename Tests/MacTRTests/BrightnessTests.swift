// BrightnessTests.swift — applyBrightness must reproduce the historical
// brightness curve: decode sRGB to linear, multiply, encode back. Users
// calibrated their brightness levels against this behavior; a stored-value
// multiply reads several levels brighter at the same setting (level 8 washes
// bright colors to white). Expected values below were captured from the
// original CoreImage implementation and verified against the sRGB formula.

import CoreGraphics
import Testing

@testable import MacTR

/// Build a 1-row RGBA8888 image from (r,g,b) tuples, alpha 255.
private func makeImage(_ pixels: [(UInt8, UInt8, UInt8)]) -> CGImage? {
    guard let ctx = CGContext(
        data: nil, width: pixels.count, height: 1, bitsPerComponent: 8,
        bytesPerRow: pixels.count * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return nil }
    let buf = ctx.data!.assumingMemoryBound(to: UInt8.self)
    for (i, p) in pixels.enumerated() {
        buf[i * 4] = p.0; buf[i * 4 + 1] = p.1; buf[i * 4 + 2] = p.2; buf[i * 4 + 3] = 255
    }
    return ctx.makeImage()
}

/// Read back (r,g,b,a) rows from a CGImage via a bitmap context.
private func readPixels(_ image: CGImage) -> [(UInt8, UInt8, UInt8, UInt8)] {
    let w = image.width, h = image.height
    guard let ctx = CGContext(
        data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { return [] }
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    let buf = ctx.data!.assumingMemoryBound(to: UInt8.self)
    return (0..<(w * h)).map { i in
        (buf[i * 4], buf[i * 4 + 1], buf[i * 4 + 2], buf[i * 4 + 3])
    }
}

private func within1(_ a: UInt8, _ b: UInt8) -> Bool {
    abs(Int(a) - Int(b)) <= 1
}

@Test("level 1 leaves the image untouched")
func brightnessLevel1IsIdentity() throws {
    let image = try #require(makeImage([(100, 50, 20)]))

    let out = try #require(JPEGEncoder.applyBrightness(image, level: 1))

    let px = try #require(readPixels(out).first)
    #expect(px == (100, 50, 20, 255))
}

@Test("level 2 multiplies linear-light by 1.3, alpha untouched")
func brightnessMultipliesLinearValues() throws {
    // srgb_encode(srgb_decode(100,50,20) × 1.3) = (113, 57, 24) — the curve
    // the original CoreImage path produced. A stored-value multiply would
    // give (130, 65, 26) and reads far brighter at high levels.
    let image = try #require(makeImage([(100, 50, 20)]))

    let out = try #require(JPEGEncoder.applyBrightness(image, level: 2))

    let px = try #require(readPixels(out).first)
    let rgb = (px.0, px.1, px.2)
    #expect(within1(px.0, 113) && within1(px.1, 57) && within1(px.2, 24),
            Comment(rawValue: "got \(rgb), want ≈(113, 57, 24)"))
    #expect(px.3 == 255)
}

@Test("values that overflow clamp to 255")
func brightnessClampsAt255() throws {
    // Linear-space at factor 1.9: 200 → clamps to 255, 10 → 17
    let image = try #require(makeImage([(200, 255, 10)]))

    let out = try #require(JPEGEncoder.applyBrightness(image, level: 4))

    let px = try #require(readPixels(out).first)
    #expect(px.0 == 255)
    #expect(px.1 == 255)
    #expect(within1(px.2, 17), Comment(rawValue: "B: got \(px.2), want ≈17"))
}

@Test("level 8 keeps bright yellow yellow instead of washing it white")
func brightnessLevel8KeepsHue() throws {
    // Pikachu-yellow (255, 220, 60) at factor 3.1: linear-space gives
    // (255, 255, 105) — still yellow. A stored-value multiply gives
    // (255, 255, 186), visibly washed toward white (the reported bug).
    let image = try #require(makeImage([(255, 220, 60)]))

    let out = try #require(JPEGEncoder.applyBrightness(image, level: 8))

    let px = try #require(readPixels(out).first)
    #expect(px.0 == 255 && px.1 == 255)
    #expect(within1(px.2, 105), Comment(rawValue: "B: got \(px.2), want ≈105"))
}
