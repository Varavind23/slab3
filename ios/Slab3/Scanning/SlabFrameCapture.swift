import CoreImage
import CoreVideo
import Foundation

/// Turns the frame a cert was recognised in into the card's picture.
///
/// The whole point of owning the capture session is that this is free: no second
/// shutter, no session reconfiguration, no freeze. The cost is one crop, one
/// scale and one JPEG encode — around 10–25 ms, and only ONCE per slab, not once
/// per frame.
///
/// Two rules keep it that way:
///   * one long-lived `CIContext`. Building one per frame costs 80–150 ms and is
///     the classic way to make this slower than the thing it replaced.
///   * never retain the `CVPixelBuffer` past the delegate callback. Holding
///     buffers starves the capture pool and stalls the session — precisely the
///     stall this rebuild exists to remove. So conversion happens inline, on the
///     video queue, and only the encoded bytes escape.
struct SlabFrameCapture {
    /// Reused across the life of the scanner.
    private let context = CIContext(options: [.useSoftwareRenderer: false])

    /// Crop to the guide rectangle rather than to the barcode.
    ///
    /// The barcode's own bounding box is tempting but it locates the LABEL, not
    /// the card, and the offset between the two differs by grader and by slab
    /// orientation — getting it wrong photographs the label instead of the card.
    /// The guides are the rectangle the user is already aiming with, so they are
    /// the honest crop until on-device evidence says otherwise.
    func jpeg(from buffer: CVPixelBuffer) -> Data? {
        let image = CIImage(cvPixelBuffer: buffer)
        let full = image.extent

        let crop = CGRect(
            x: full.minX + ScanGeometry.guideRect.minX * full.width,
            y: full.minY + ScanGeometry.guideRect.minY * full.height,
            width: ScanGeometry.guideRect.width * full.width,
            height: ScanGeometry.guideRect.height * full.height
        ).intersection(full)
        guard !crop.isNull, !crop.isEmpty else { return nil }

        let cropped = image.cropped(to: crop)
        let longest = max(cropped.extent.width, cropped.extent.height)
        let scale = longest > ScanGeometry.captureMaxEdge ? ScanGeometry.captureMaxEdge / longest : 1
        let scaled = scale < 1
            ? cropped.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            : cropped

        return context.jpegRepresentation(
            of: scaled,
            colorSpace: CGColorSpaceCreateDeviceRGB(),
            options: [kCGImageDestinationLossyCompressionQuality as CIImageRepresentationOption: ScanGeometry.captureQuality]
        )
    }
}
