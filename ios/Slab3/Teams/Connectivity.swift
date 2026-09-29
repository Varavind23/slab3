import Foundation
import Network
import Observation
import SwiftUI

/// Whether the phone has a route to the internet right now. Card-show signal is
/// unreliable (teams.md §10); when it comes back, offline lot scans sync at once
/// rather than waiting for the next time the app comes forward.
///
/// Only started while the user is on a team — nobody else has anything to sync,
/// and a monitor nobody reads is a background cost for nothing.
@MainActor
@Observable
final class Connectivity {
    private(set) var isOnline = true
    private var monitor: NWPathMonitor?

    func start() {
        guard monitor == nil else { return }
        let m = NWPathMonitor()
        m.pathUpdateHandler = { [weak self] path in
            let online = path.status == .satisfied
            Task { @MainActor in
                guard let self, self.isOnline != online else { return }
                self.isOnline = online
            }
        }
        m.start(queue: DispatchQueue(label: "slabs.connectivity"))
        monitor = m
    }

    func stop() {
        monitor?.cancel()
        monitor = nil
        isOnline = true
    }
}

/// "Synced 5 offline scans · 3 in lot · 1 over limit · 1 not in lot" — shown for
/// a few seconds after a reconnect, in the undo bar's slot. Amber when anything
/// did not land clean, so it reads as "look at this" rather than as success.
struct LotSyncBar: View {
    let summary: LotClaims.SyncSummary
    var body: some View {
        let clean = summary.overLimit == 0 && summary.notInLot == 0 && summary.pickBucket == 0
        VStack(spacing: 0) {
            Rectangle().fill(Caliper.line).frame(height: Caliper.borderWidth)
            Text(summary.line)
                .caliperLabel(clean ? Caliper.textSecondary : Caliper.confMid)
                .lineLimit(2)
                .frame(maxWidth: .infinity, minHeight: Caliper.hitMin, alignment: .leading)
                .padding(.horizontal, Caliper.gutter)
        }
        .background(Caliper.surface)
    }
}
