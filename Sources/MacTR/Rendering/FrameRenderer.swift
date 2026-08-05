// FrameRenderer.swift — Protocol for display set renderers
//
// Each display set implements this protocol.
// The frame loop calls render() to get a CGImage, then encodes it to JPEG.

import Accelerate
import CoreGraphics
import Foundation
import ImageIO

// MARK: - Protocol

protocol FrameRenderer {
    /// Render a full 1920x480 frame. Returns CGImage in device orientation.
    func render() -> CGImage?
}

// MARK: - JPEG Encoding

enum JPEGEncoder {

    // Reusable context for 180° rotation — prevents CG raster data leak
    nonisolated(unsafe) private static var rotateCtx: CGContext?

    /// Encode a CGImage to JPEG. Turns the frame 180° when `rotate` is true, for
    /// coolers whose LCD is mounted the other way up. Reduces quality if over 650KB.
    static func encode(
        _ image: CGImage, brightness: Int = 1, rotate: Bool = false, maxBytes: Int = 650_000
    ) -> Data? {
        let w = image.width
        let h = image.height

        var finalImage: CGImage

        if rotate {
            // Reuse rotation context
            if rotateCtx == nil || rotateCtx!.width != w || rotateCtx!.height != h {
                let colorSpace = CGColorSpaceCreateDeviceRGB()
                rotateCtx = CGContext(
                    data: nil, width: w, height: h,
                    bitsPerComponent: 8, bytesPerRow: w * 4,
                    space: colorSpace,
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            }
            guard let rotatedCtx = rotateCtx else { return nil }

            // 180° rotation
            rotatedCtx.saveGState()
            rotatedCtx.translateBy(x: CGFloat(w), y: CGFloat(h))
            rotatedCtx.scaleBy(x: -1, y: -1)
            rotatedCtx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            rotatedCtx.restoreGState()

            guard let rotated = rotatedCtx.makeImage() else { return nil }
            finalImage = rotated
        } else {
            finalImage = image
        }

        // Apply brightness if needed
        if brightness > 1 {
            if let brightened = applyBrightness(finalImage, level: brightness) {
                finalImage = brightened
            }
        }

        // Encode to JPEG with quality reduction loop
        var quality = 0.9
        while quality > 0.3 {
            if let data = jpegData(from: finalImage, quality: quality) {
                if data.count <= maxBytes || quality <= 0.3 {
                    return data
                }
            }
            quality -= 0.05
        }
        return jpegData(from: finalImage, quality: 0.3)
    }

    private static func jpegData(from image: CGImage, quality: Double) -> Data? {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data, "public.jpeg" as CFString, 1, nil)
        else { return nil }

        let options: [CFString: Any] = [
            kCGImageDestinationLossyCompressionQuality: quality
        ]
        CGImageDestinationAddImage(dest, image, options as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return data as Data
    }

    // Reusable context for the brightness multiply — same leak-avoidance as
    // rotateCtx. Locked: the buffer is drawn into and multiplied in place, so
    // two concurrent callers (parallel tests today, any second caller tomorrow)
    // corrupt each other's pixels.
    nonisolated(unsafe) private static var brightnessCtx: CGContext?
    private static let brightnessLock = NSLock()

    /// Apply brightness: decode sRGB to linear light, multiply by factor,
    /// encode back, saturating at 1.0 — the exact curve the original CoreImage
    /// colorMatrix path produced. That curve is the contract: users calibrated
    /// their brightness levels against it, and a stored-value multiply reads
    /// several levels brighter (level 8 washes Pikachu's yellow to white).
    /// The whole decode→multiply→encode is baked into a per-level 256-entry
    /// table, applied in one SIMD pass over a reused bitmap.
    /// Internal (not private) so tests can pin the curve with known pixels.
    static func applyBrightness(_ image: CGImage, level: Int) -> CGImage? {
        if Brightness.factor(for: level) <= 1.0 { return image }

        let w = image.width, h = image.height
        brightnessLock.lock()
        defer { brightnessLock.unlock() }
        if let ctx = brightnessCtx, ctx.width != w || ctx.height != h {
            brightnessCtx = nil
        }
        if brightnessCtx == nil {
            brightnessCtx = CGContext(
                data: nil, width: w, height: h,
                bitsPerComponent: 8, bytesPerRow: w * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        }
        guard let ctx = brightnessCtx, let data = ctx.data else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))

        var buffer = vImage_Buffer(data: data, height: vImagePixelCount(h),
                                   width: vImagePixelCount(w), rowBytes: ctx.bytesPerRow)
        // Tables apply to bytes in memory order — RGBA here, so the brightness
        // curve goes on the first three and alpha keeps the identity table.
        let lut = brightnessLUT(level: level)
        guard vImageTableLookUp_ARGB8888(&buffer, &buffer, lut, lut, lut,
                                         Self.identityLUT,
                                         vImage_Flags(kvImageNoFlags))
            == kvImageNoError
        else { return nil }

        return ctx.makeImage()
    }

    private static let identityLUT: [UInt8] = (0...255).map { UInt8($0) }

    // Guarded by brightnessLock, like brightnessCtx
    nonisolated(unsafe) private static var brightnessLUTs: [Int: [UInt8]] = [:]

    private static func brightnessLUT(level: Int) -> [UInt8] {
        if let hit = brightnessLUTs[level] { return hit }
        let factor = Double(Brightness.factor(for: level))
        func decode(_ c: Double) -> Double {
            c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4)
        }
        func encode(_ l: Double) -> Double {
            l <= 0.0031308 ? l * 12.92 : 1.055 * pow(l, 1 / 2.4) - 0.055
        }
        let lut = (0...255).map { v in
            UInt8(clamping: Int((encode(min(1.0, decode(Double(v) / 255) * factor)) * 255).rounded()))
        }
        brightnessLUTs[level] = lut
        return lut
    }
}
