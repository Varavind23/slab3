import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Keeps card pictures small enough to live in the store.
///
/// Every image the app holds is cached as `Data` on the `Card` (SwiftData spills
/// it to external storage past ~128 KB). The camera's own crop is already sized,
/// but an OFFICIAL render is whatever the source felt like serving: a PSA
/// SecureScan can be several megabytes. Storing those verbatim would bloat the
/// store for a picture that is displayed at 46 × 64 in a row and ~1035 px on the
/// detail screen.
///
/// Deliberately pure and Foundation-only so it can be unit-tested off-device
/// against a synthesized bitmap, with no camera and no network.
enum ImageDownscale {
    /// Longest edge of a stored image. Sized for the detail screen (~345 pt at
    /// @3x); the row thumbnail is oversampled several times over at this size.
    static let maxEdge: CGFloat = 1024
    static let quality: CGFloat = 0.7

    /// Bytes under which re-encoding isn't worth the CPU or the generation loss.
    static let passthroughLimit = 300 * 1024

    /// Downscale if the image is big; otherwise hand back exactly what arrived.
    /// Never returns empty — a failure to decode yields the original bytes, so a
    /// picture we can't process is still better than no picture.
    static func normalized(_ data: Data) -> Data {
        guard data.count > passthroughLimit else { return data }
        return jpeg(from: data, maxEdge: maxEdge, quality: quality) ?? data
    }

    /// Decode, scale the longest edge down to `maxEdge`, re-encode as JPEG.
    /// Uses ImageIO's thumbnail path, which decodes at the target size rather
    /// than decoding full-size and then shrinking.
    static func jpeg(from data: Data, maxEdge: CGFloat, quality: CGFloat) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxEdge,
        ]
        guard let scaled = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(dest, scaled, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
