// JPEGEncoderRotationTests.swift — the rotation flag must mean what it says.
//
// Guards the inversion that shipped in v1.2.0: `if !rotate` rotated the frame
// when the flag was false, so every call site read backwards and the LCD came
// up upside down by default.

import CoreGraphics
import Foundation
import ImageIO
import Testing

@testable import MacTR

// MARK: - Fixtures

// Deliberately not square, and wider than tall like the real 1920x480 panel: a
// square fixture would pass just the same if someone swapped a width for a
// height somewhere in the rotation path. Non-square also exercises the encoder's
// "is the cached context still the right size" branch.
private let imageWidth = 160
private let imageHeight = 80
private let patchSide = 24

private struct DecodeFailure: Error {}

private enum Corner {
    case a, b, c, d

    /// The corner diagonally across the frame — where a 180° turn lands.
    var diagonalOpposite: Corner {
        switch self {
        case .a: .d
        case .d: .a
        case .b: .c
        case .c: .b
        }
    }
}

/// A black square with one white patch, so a 180° turn is detectable purely by
/// which corner the patch ends up in.
private func makeCornerMarkedImage() -> CGImage {
    let ctx = CGContext(
        data: nil, width: imageWidth, height: imageHeight,
        bitsPerComponent: 8, bytesPerRow: imageWidth * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: imageWidth, height: imageHeight))
    ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: patchSide, height: patchSide))
    return ctx.makeImage()!
}

/// Which corner holds the brightest patch.
///
/// The corner labels are deliberately meaningless (a/b/c/d): both the reference
/// image and the round-tripped JPEG go through this same function, so the tests
/// only ever compare *which* corner moved. That keeps them out of the business
/// of deciding whether row 0 of a CoreGraphics bitmap is the top or the bottom.
///
/// Frames are JPEG-compressed, so this averages a patch rather than sampling a
/// single pixel — lossy artefacts move individual pixels around.
private func brightestCorner(of image: CGImage) -> Corner {
    let w = image.width, h = image.height
    var bytes = [UInt8](repeating: 0, count: w * h * 4)
    bytes.withUnsafeMutableBytes { raw in
        let ctx = CGContext(
            data: raw.baseAddress, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
    }

    func meanLuma(_ xRange: Range<Int>, _ yRange: Range<Int>) -> Double {
        var total = 0.0
        for y in yRange {
            for x in xRange {
                let i = (y * w + x) * 4
                total += (Double(bytes[i]) + Double(bytes[i + 1]) + Double(bytes[i + 2])) / 3
            }
        }
        return total / Double(xRange.count * yRange.count)
    }

    let lowX = 0..<patchSide, highX = (w - patchSide)..<w
    let lowY = 0..<patchSide, highY = (h - patchSide)..<h
    let scores: [(Corner, Double)] = [
        (.a, meanLuma(lowX, lowY)),
        (.b, meanLuma(highX, lowY)),
        (.c, meanLuma(lowX, highY)),
        (.d, meanLuma(highX, highY)),
    ]
    return scores.max(by: { $0.1 < $1.1 })!.0
}

/// Plain `throws` rather than `#require`, so there's no question of whether the
/// macro behaves outside a `@Test` function.
private func decode(_ jpeg: Data) throws -> CGImage {
    guard let source = CGImageSourceCreateWithData(jpeg as CFData, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else { throw DecodeFailure() }
    return image
}

// MARK: - Tests

@Test("rotate: false leaves the frame where it was")
func rotateFalseLeavesFrameAlone() throws {
    let original = makeCornerMarkedImage()
    let jpeg = try #require(JPEGEncoder.encode(original, brightness: 1, rotate: false))
    let decoded = try decode(jpeg)
    #expect(brightestCorner(of: decoded) == brightestCorner(of: original))
}

@Test("rotate: true turns the frame 180 degrees")
func rotateTrueTurnsFrame() throws {
    let original = makeCornerMarkedImage()
    let jpeg = try #require(JPEGEncoder.encode(original, brightness: 1, rotate: true))
    let decoded = try decode(jpeg)
    #expect(brightestCorner(of: decoded) == brightestCorner(of: original).diagonalOpposite)
}

/// `makeTestJPEG` in MacTRApp.swift relies on the default, and the USB test
/// pattern must not silently flip when the flag's meaning is corrected.
@Test("the default is no rotation")
func defaultIsNoRotation() throws {
    let original = makeCornerMarkedImage()
    let jpeg = try #require(JPEGEncoder.encode(original, brightness: 1))
    let decoded = try decode(jpeg)
    #expect(brightestCorner(of: decoded) == brightestCorner(of: original))
}
