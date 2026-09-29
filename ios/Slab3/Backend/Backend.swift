import Foundation
import Supabase

/// The app's single Supabase client. The URL and anon key are PUBLIC by design —
/// the anon key ships in every client build, and row-level security (not secrecy)
/// is what protects each user's data. The service_role key is never here.
enum Backend {
    static let client = SupabaseClient(supabaseURL: endpoint.url, supabaseKey: endpoint.key)

    /// True only in a DEBUG build launched against the local stack (below). Shown in
    /// Settings → Server. (Teams was gated on it until 0.8, when it went live.)
    static let isLocal: Bool = endpoint.isLocal

    /// What Settings shows in a DEBUG build, so which server a test is hitting is
    /// never a guess (2026-09-27: a home-screen launch had silently gone live).
    static var serverLabel: String {
        endpoint.isLocal ? "Test · \(endpoint.url.host ?? "local")" : "Live"
    }

    private static let endpoint: (url: URL, key: String, isLocal: Bool) = {
        #if DEBUG
        // Teams is built against `supabase start` on the Mac, NEVER the live
        // project, while users are on the shipped app (2026-09-25, owner: "users
        // are live … need it working properly"). The WHOLE client — auth included,
        // because the local stack cannot validate a live JWT — talks to it.
        //
        // How a build gets there: Xcode's "… Local" schemes set SLABS_BACKEND=local
        // (+ SLABS_BACKEND_HOST, the Mac's Wi-Fi address, for a real iPhone — there
        // 127.0.0.1 is the phone). Scheme variables only exist while XCODE launches
        // the app, and the first on-device test was reopened from the home screen and
        // quietly went live. So the choice is REMEMBERED on the device until a scheme
        // sets SLABS_BACKEND=live (the plain SlabsDev scheme does).
        //
        // Compiled out of Release, so an archive can never take this branch; the
        // key is the stock `supabase-demo` anon key every local stack shares.
        let env = ProcessInfo.processInfo.environment
        let defaults = UserDefaults.standard
        let rememberKey = "debug_local_backend_host"
        switch env["SLABS_BACKEND"] {
        case "local":
            let host = env["SLABS_BACKEND_HOST"].flatMap { $0.isEmpty ? nil : $0 } ?? "127.0.0.1"
            defaults.set(host, forKey: rememberKey)
        case "live":
            defaults.removeObject(forKey: rememberKey)
        default:
            break
        }
        if let host = defaults.string(forKey: rememberKey) {
            return (URL(string: "http://\(host):54321")!,
                    "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZS1kZW1vIiwicm9sZSI6ImFub24iLCJleHAiOjE5ODM4MTI5OTZ9.CRXP1A7WOeoJeXxjNni43kdQwgnWNReilDMblYTn_I0",
                    true)
        }
        #endif
        return (URL(string: "https://rrkvlrtohmylhslpzuvz.supabase.co")!,
                "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InJya3ZscnRvaG15bGhzbHB6dXZ6Iiwicm9sZSI6ImFub24iLCJpYXQiOjE3ODc0NDM2MzksImV4cCI6MjEwMzAxOTYzOX0.dvXo9pVFu_NbVZznvc4RoAzxZ3AecyC9iKcu3EXg14g",
                false)
    }()
}
