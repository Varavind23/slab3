import SwiftUI
import SwiftData

@main
struct Slab3App: App {
    var body: some Scene {
        WindowGroup {
            RootView()
        }
        .modelContainer(for: Card.self)
    }
}

struct RootView: View {
    var body: some View {
        TabView {
            ScanScreen()
                .tabItem { Label("Scan", systemImage: "barcode.viewfinder") }
            InventoryScreen()
                .tabItem { Label("Inventory", systemImage: "square.stack.3d.up") }
        }
    }
}
