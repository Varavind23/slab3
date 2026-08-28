import Testing
import Foundation
import ImageIO
import UniformTypeIdentifiers
@testable import Slab3

/// Official card renders arrive at whatever size the source felt like serving —
/// a PSA SecureScan can be several megabytes — and every one of them is cached
/// as bytes on the Card. These pin the two behaviours that keep the store sane
/// without ever leaving a row picture-less.
struct ImageDownscaleTests {
    /// A JPEG of the given size, noisy on purpose: a flat colour compresses to
    /// almost nothing and would never cross the passthrough limit.
    private func jpeg(width: Int, height: Int) throws -> Data {
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        var seed: UInt64 = 0x5EED
        for i in pixels.indices {
            seed = seed &* 6364136223846793005 &+ 1442695040888963407
            pixels[i] = UInt8((seed >> 33) & 0xFF)
        }
        let context = CGContext(
            data: &pixels, width: width, height: height, bitsPerComponent: 8,
            bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )
        let image = try #require(context?.makeImage())
        let out = NSMutableData()
        let dest = try #require(CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil))
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: 1.0] as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
        return out as Data
    }

    private func pixelSize(of data: Data) throws -> (width: Double, height: Double) {
        let source = try #require(CGImageSourceCreateWithData(data as CFData, nil))
        let props = try #require(CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any])
        return (
            Double(props[kCGImagePropertyPixelWidth] as? Int ?? 0),
            Double(props[kCGImagePropertyPixelHeight] as? Int ?? 0)
        )
    }

    @Test func largeImageIsScaledToTheLongEdgeCap() throws {
        let big = try jpeg(width: 3000, height: 2000)
        let scaled = try #require(ImageDownscale.jpeg(from: big, maxEdge: 1024, quality: 0.7))
        let size = try pixelSize(of: scaled)
        #expect(max(size.width, size.height) == 1024)
        #expect(scaled.count < big.count)
    }

    @Test func aspectRatioSurvivesTheScale() throws {
        let big = try jpeg(width: 3000, height: 2000)
        let scaled = try #require(ImageDownscale.jpeg(from: big, maxEdge: 1024, quality: 0.7))
        let size = try pixelSize(of: scaled)
        #expect(abs(size.width / size.height - 1.5) < 0.02)
    }

    @Test func smallImagePassesThroughUntouched() throws {
        let small = try jpeg(width: 120, height: 168)
        #expect(small.count < ImageDownscale.passthroughLimit)
        #expect(ImageDownscale.normalized(small) == small, "no re-encode, no generation loss")
    }

    /// The important failure mode: a picture we can't decode is still better
    /// than no picture, so normalization must never hand back nothing.
    @Test func undecodableDataIsReturnedRatherThanDropped() {
        let junk = Data(repeating: 0xAB, count: ImageDownscale.passthroughLimit + 1)
        #expect(ImageDownscale.normalized(junk) == junk)
        #expect(ImageDownscale.jpeg(from: junk, maxEdge: 1024, quality: 0.7) == nil)
    }
}
