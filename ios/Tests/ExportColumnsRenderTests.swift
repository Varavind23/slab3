import Foundation
import SwiftUI
import Testing
@testable import Slab3

/// The export column chips are the densest tap targets in the app — fifteen of
/// them in a wrapping grid — and they were drawn at the size of the `GradeBadge`
/// they share a component with: about 20pt tall, against Caliper's own stated
/// "hit target minimum 44". A user reported them as fiddly to tap (2026-09-16).
///
/// Size is a layout property, so it gets the same treatment the comps panel got
/// in DetailScreenRenderTests: rules pinned as assertions, plus a PNG to look at.
///
/// Output: $TMPDIR/slabs-render/*.png — printed below, deliberately not asserted
/// on beyond existing; it is a developer's eye that reads it.
@MainActor
struct ExportColumnsRenderTests {

    /// The rule the design system states for itself.
    @Test func tapChipsMeetTheDesignsHitMinimum() {
        #expect(Chip.Size.tap.hitHeight >= Caliper.hitMin)
    }

    /// The ink has to grow too. A 44 target wrapped around 20pt of chip still
    /// LOOKS untappable, and looking untappable was the report.
    @Test func aTapChipIsDrawnLargerThanARowBadge() {
        #expect(Chip.Size.tap.hPad > Chip.Size.badge.hPad)
        #expect(Chip.Size.tap.vPad > Chip.Size.badge.vPad)
        #expect(Chip.Size.tap.orderSide > Chip.Size.badge.orderSide)
    }

    /// …and the row badge must NOT have grown with it. `GradeBadge` closes every
    /// card row, repeats down a long list, and nothing taps it, so it keeps the
    /// dense metrics it was designed with.
    @Test func rowBadgesAreUnchanged() {
        #expect(Chip.Size.badge.hPad == Caliper.space3)
        #expect(Chip.Size.badge.vPad == Caliper.space2)
        #expect(Chip.Size.badge.orderSide == 12)
        #expect(Chip.Size.badge.hitHeight == 0, "a display badge asks the caller for no target")
    }

    /// The grid as it actually wraps at iPhone width, with the first four columns
    /// selected so both tones and the order badges are in frame.
    @Test func rendersTheColumnGrid() throws {
        let columns = Array(CSVColumn.allCases.enumerated())
        let view = VStack(alignment: .leading, spacing: Caliper.space5) {
            Text("Include columns").caliperLabel()
            FlowLayout(spacing: Caliper.space4) {
                ForEach(columns, id: \.element) { position, column in
                    let selected = position < 4
                    Chip(
                        text: column.label,
                        tone: selected ? (column.source == nil ? .standard : .source) : .quiet,
                        color: column.source?.hue ?? Caliper.cyan,
                        order: selected ? position + 1 : nil,
                        size: .tap
                    )
                    .frame(minHeight: Chip.Size.tap.hitHeight)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Caliper.gutter)
        .background(Caliper.bg)

        let url = try render(view, named: "export-columns", height: 320)
        #expect(FileManager.default.fileExists(atPath: url.path))
    }

    private func render(_ view: some View, named name: String, height: CGFloat) throws -> URL {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 393, height: height) // iPhone 17 logical width
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slabs-render")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let image = renderer.uiImage, let data = image.pngData() else {
            throw RenderError.failed
        }
        try data.write(to: url)
        print("RENDERED \(url.path)")
        return url
    }

    enum RenderError: Error { case failed }
}
