// Generates the app icon from the SAME marks the app draws, so the icon and the
// launch screen can't drift apart: the "Slabs" wordmark (SplashView.swift) on the
// Caliper ground, using tokens from DesignSystem/DesignTokens.swift.
//
//   bg          #06090C   Caliper.bg
//   textPrimary #E8F1F4   Caliper.textPrimary
//   cyan        #35E0E8   Caliper.cyan
//
// Space Grotesk has no .ttf in the repo, so CaliperType falls back to the system
// face — this renders the system face too, matching what the app actually shows.
//
// Run:  swift ios/Tools/make-appicon.swift <output.png>
// App Store requires 1024x1024, fully opaque, NO alpha, NO pre-rounded corners.

import AppKit
import CoreText

let side = 1024.0
let out = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : "AppIcon-1024.png"

func hex(_ v: UInt32) -> CGColor {
    CGColor(srgbRed: CGFloat((v >> 16) & 0xFF) / 255,
            green: CGFloat((v >> 8) & 0xFF) / 255,
            blue: CGFloat(v & 0xFF) / 255, alpha: 1)
}
let bg = hex(0x06090C), textPrimary = hex(0xE8F1F4), cyan = hex(0x35E0E8)

// noneSkipLast => opaque RGB, so the PNG carries no alpha channel.
guard let ctx = CGContext(
    data: nil, width: Int(side), height: Int(side), bitsPerComponent: 8,
    bytesPerRow: 0, space: CGColorSpace(name: CGColorSpace.sRGB)!,
    bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
) else { fatalError("could not create context") }

ctx.setFillColor(bg)
ctx.fill(CGRect(x: 0, y: 0, width: side, height: side))

// Wordmark. SplashView draws .sans(34, .bold) with tracking(-1); the tracking is
// kept proportional (-1/34 of the size) so the letterfit matches at any scale.
//
// Size is derived by FITTING the mark to a target width rather than guessed, so
// the icon stays correct if the wordmark ever changes length.
func line(at size: CGFloat) -> (CTLine, CGRect) {
    let attributed = NSAttributedString(string: "Slabs", attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: .bold),
        .foregroundColor: NSColor(cgColor: textPrimary)!,
        .kern: -(size / 34.0),
    ])
    let l = CTLineCreateWithAttributedString(attributed)
    return (l, CTLineGetBoundsWithOptions(l, .useOpticalBounds))
}

let targetWidth = side * 0.70
var fontSize = side * 0.235
for _ in 0..<8 {                      // converges in two or three passes
    let (_, b) = line(at: fontSize)
    guard b.width > 0 else { break }
    fontSize *= targetWidth / b.width
}
let (mark, bounds) = line(at: fontSize)

// Compose the wordmark and its rule as ONE group and centre that, otherwise the
// rule drags the visual weight down and the icon reads bottom-heavy.
let ruleW = side * 0.34, ruleH = max(2, side * 0.007)
let gap = side * 0.055
let groupH = bounds.height + gap + ruleH
let groupTop = (side - groupH) / 2

ctx.textPosition = CGPoint(
    x: (side - bounds.width) / 2 - bounds.minX,
    y: side - groupTop - bounds.height - bounds.minY
)
CTLineDraw(mark, ctx)

// One cyan hairline under the mark — the system's structural motif (hairlines, no
// elevation), and the single accent the palette allows.
ctx.setFillColor(cyan)
ctx.fill(CGRect(x: (side - ruleW) / 2,
                y: side - groupTop - groupH,
                width: ruleW, height: ruleH))

guard let image = ctx.makeImage() else { fatalError("could not render") }
let url = URL(fileURLWithPath: out)
guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil)
else { fatalError("could not open \(out)") }
CGImageDestinationAddImage(dest, image, nil)
guard CGImageDestinationFinalize(dest) else { fatalError("could not write \(out)") }
print("wrote \(out)  \(Int(side))x\(Int(side))  alpha=\(image.alphaInfo == .none || image.alphaInfo == .noneSkipLast ? "none" : "PRESENT")")
