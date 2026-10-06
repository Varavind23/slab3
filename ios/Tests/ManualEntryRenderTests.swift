import Foundation
import SwiftUI
import Testing
@testable import Slab3

/// The cert-entry sheet with a pasted list in it — empty, a short seller list
/// with one cert already held, and a list past the 30 cap. Layout bugs have
/// shipped green before (CLAUDE.md), so these exist to be LOOKED AT.
///
/// Output: $TMPDIR/slabs-render/manual-entry-*.png (simulator), printed below.
/// ImageRenderer draws no UIKit-backed controls (the text field, PasteButton), so
/// those show as placeholders; the preview rows and confirm are what to check.
@MainActor
struct ManualEntryRenderTests {

    @Test func rendersEmpty() throws {
        try render(sheet(""), named: "manual-entry-empty")
    }

    @Test func rendersASellerList() throws {
        let list = """
        PSA 10 Charizard - 49385027
        96679812
        CGC 9.5 6055 074 171
        87654321, 12345678
        """
        try render(sheet(list, held: ["96679812"], overrides: ["87654321": .cgc]), named: "manual-entry-list")
    }

    @Test func rendersPastTheCap() throws {
        let list = (0..<34).map { String(10_000_000 + $0) }.joined(separator: "\n")
        try render(sheet(list), named: "manual-entry-over-cap", height: 1600)
    }

    /// The sheet's shell (title, confirm) plus the preview drawn OUTSIDE its
    /// ScrollView — ImageRenderer leaves a ScrollView's contents blank.
    private func sheet(_ text: String, held: Set<String> = [], overrides: [String: Grader] = [:]) -> some View {
        let scans = ManualEntrySheet.scans(in: text, overrides: overrides, excluded: [])
        let split = CertBatch.split(scans) { held.contains($0.certNumber) }
        return VStack(spacing: 0) {
            ManualEntrySheet(add: { _ in }, addBatch: { _ in },
                             isHeld: { held.contains($0.certNumber) }, text: text)
                .frame(height: 230)
            CertPreview(scans: scans, split: split, overrides: .constant(overrides), excluded: .constant([]))
                .padding(.horizontal, Caliper.gutter)
            Spacer(minLength: 0)
        }
        .background(Caliper.bg)
    }

    private func render(_ view: some View, named name: String, height: CGFloat = 700) throws {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 393, height: height) // iPhone 17 logical width
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slabs-render")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        let data = try #require(renderer.uiImage?.pngData())
        try data.write(to: url)
        print("RENDERED \(url.path)")
        #expect(FileManager.default.fileExists(atPath: url.path))
    }
}
