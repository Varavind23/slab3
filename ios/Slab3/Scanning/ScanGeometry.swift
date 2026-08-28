import CoreGraphics

/// The one rectangle the scanner agrees on.
///
/// Three things have to line up exactly: the guide brackets drawn on screen,
/// the region Vision is allowed to look at, and the crop taken for the card's
/// picture. If they drift apart the user aims at one rectangle while the app
/// reads and photographs another, so they are one constant rather than three.
enum ScanGeometry {
    /// Normalized within the preview, origin bottom-left (Vision's convention).
    /// A wide, letterboxed band: slab labels sit across the middle of the frame,
    /// and excluding the edges is what stops the NEXT slab in the tray from
    /// being read while the user is still framing this one.
    static let guideRect = CGRect(x: 0.06, y: 0.30, width: 0.88, height: 0.40)

    /// The same rectangle in UIKit's top-left origin, for drawing and cropping.
    static var guideRectFlipped: CGRect {
        CGRect(
            x: guideRect.minX,
            y: 1 - guideRect.maxY,
            width: guideRect.width,
            height: guideRect.height
        )
    }

    /// Longest edge of the JPEG kept for a card. The row thumbnail is 46 × 64 pt
    /// and the detail view about 345 pt wide, so at @3x this is comfortably
    /// oversampled — going higher costs encode time and bytes for nothing.
    static let captureMaxEdge: CGFloat = 1024
    static let captureQuality: CGFloat = 0.7

    /// Vision runs at this rate, not at the camera's frame rate. A person cannot
    /// present slabs faster than this, and the headroom matters across a
    /// several-hundred-slab session.
    static let detectionsPerSecond: Double = 12
}
