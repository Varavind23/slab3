import SwiftUI

/// Full-bleed ground, "Slabs" wordmark centred, bold, no icon or illustration.
struct SplashView: View {
    var body: some View {
        ZStack {
            Caliper.bg.ignoresSafeArea()
            Text("Slabs")
                .font(.sans(34, .bold))
                .tracking(-1)
                .foregroundStyle(Caliper.textPrimary)
        }
    }
}
