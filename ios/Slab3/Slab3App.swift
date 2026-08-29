import SwiftUI
import SwiftData

@main
struct Slab3App: App {
    @State private var auth = AuthManager()
    @State private var showSplash = true

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView(auth: auth)
                    .task { await auth.start() }
                if showSplash {
                    SplashView().transition(.opacity)
                }
            }
            .task {
                try? await Task.sleep(for: .seconds(1.1))
                withAnimation(.easeOut(duration: 0.35)) { showSplash = false }
            }
            // Caliper is dark only — there is no light variant, and the appearance
            // picker that used to live in Settings came out with it.
            .preferredColorScheme(.dark)
        }
        .modelContainer(for: [Card.self, Folder.self])
    }
}

struct RootView: View {
    let auth: AuthManager

    var body: some View {
        switch auth.state {
        case .loading:
            ZStack { Caliper.bg.ignoresSafeArea() }
        case .signedOut:
            AuthScreen(auth: auth)
        case .signedIn:
            MainShell(auth: auth)
                // The server holds the Card Ladder credentials, so it decides
                // whether this user is connected — not a flag in this install's
                // UserDefaults, which a reinstall wipes.
                .task { await PriceService.syncConnectionState() }
        }
    }
}
