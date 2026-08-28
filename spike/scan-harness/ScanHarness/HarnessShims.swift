import Foundation

/// The harness builds the APP's CertParser + Grader directly (see project.yml
/// `sources:`), not a copy. Until 2026-08-28 it carried its own fork, which had
/// drifted: it matched `host.contains("psacard")` and took any numeric path
/// component, where the app validates cert length per grader and reads query
/// params. The two answered differently on the same payload, which quietly made
/// every on-device verdict here a verdict about the harness rather than the app.
///
/// Only the bits the harness UI needs and the app doesn't live here.
extension CertScan: Identifiable {
    var id: String { "\(grader.rawValue):\(certNumber)" }
}
