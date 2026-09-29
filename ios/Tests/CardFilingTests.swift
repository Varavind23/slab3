import Foundation
import SwiftData
import SwiftUI
import Testing
@testable import Slab3

/// CardFiling is the single door every path uses to change a card's group (teams
/// plan §2). Pinned: filing records recency and un-filing does not (the Cards swipe
/// depends on both), the detail screen's toggle, and the filing bar rendered in its
/// two states.
///
/// Output: $TMPDIR/slabs-render/scan-filing-bar-*.png — look at them: the bar must
/// sit on one line, and a long group name must truncate before the count.
@MainActor
struct CardFilingTests {
    let store: ModelContainer = try! ModelContainer(
        for: Card.self, Folder.self,
        configurations: ModelConfiguration(isStoredInMemoryOnly: true)
    )

    private func card(_ cert: String, in context: ModelContext) -> Card {
        let c = Card(scan: CertScan(grader: .psa, certNumber: cert, raw: cert))
        context.insert(c)
        return c
    }

    @Test func filingSetsTheGroupAndRecency() {
        let context = store.mainContext
        let group = Folder(name: "consignment")
        context.insert(group)
        let a = card("11111111", in: context), b = card("22222222", in: context)
        let now = Date(timeIntervalSince1970: 1_790_000_000)

        CardFiling.file([a, b], into: group, in: context, at: now)
        #expect(a.folder === group && b.folder === group)
        #expect(group.lastUsedAt == now, "the swipe will offer this group next")
    }

    @Test func unfilingDoesNotCountAsUse() {
        let context = store.mainContext
        let group = Folder(name: "consignment")
        context.insert(group)
        let a = card("33333333", in: context)
        CardFiling.file([a], into: group, in: context, at: Date(timeIntervalSince1970: 1))
        CardFiling.unfile([a], in: context)
        #expect(a.folder == nil)
        #expect(group.lastUsedAt == Date(timeIntervalSince1970: 1),
                "leaving a group must not make the swipe offer it")
    }

    @Test func detailToggleFilesThenLeaves() {
        let context = store.mainContext
        let group = Folder(name: "consignment")
        context.insert(group)
        let a = card("44444444", in: context)
        CardFiling.toggle(a, group: group, in: context)
        #expect(a.folder === group)
        CardFiling.toggle(a, group: group, in: context)
        #expect(a.folder == nil)
    }

    @Test func filingNothingTouchesNothing() {
        let context = store.mainContext
        let group = Folder(name: "consignment")
        context.insert(group)
        CardFiling.file([], into: group, in: context)
        #expect(group.lastUsedAt == nil)
    }

    // MARK: The filing bar, rendered

    @Test func rendersTheBarUnsetAndSet() throws {
        let context = store.mainContext
        let short = Folder(name: "consignment", hueIndex: 1)
        let long = Folder(name: "Weekend show 7/24 — second table, graded only", hueIndex: 3)
        context.insert(short); context.insert(long)

        for (name, view) in [
            ("unset", AnyView(ScanFilingBar(target: nil, filedToday: 0) {})),
            ("set", AnyView(ScanFilingBar(target: short, filedToday: 18) {})),
            ("long-name", AnyView(ScanFilingBar(target: long, filedToday: 142) {})),
        ] {
            let url = try render(view.padding(Caliper.gutter).background(Caliper.bg),
                                 named: "scan-filing-bar-\(name)", height: 84)
            #expect(FileManager.default.fileExists(atPath: url.path))
        }
    }

    private func render(_ view: some View, named name: String, height: CGFloat) throws -> URL {
        let renderer = ImageRenderer(
            content: view
                .frame(width: 393, height: height)
                .environment(\.colorScheme, .dark)
        )
        renderer.scale = 2
        let dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("slabs-render")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).png")
        guard let image = renderer.uiImage, let data = image.pngData() else { throw RenderError.failed }
        try data.write(to: url)
        print("RENDERED \(url.path)")
        return url
    }

    enum RenderError: Error { case failed }
}
