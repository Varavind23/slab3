import SwiftUI

/// Splash (design.md §4, §6): full-bleed mode-dependent background, "Slabs"
/// wordmark centered, bold, no icon or illustration. The one screen where the
/// identity shows up as itself before the UI goes quiet.
struct SplashView: View {
    var body: some View {
        ZStack {
            Palette.bg.ignoresSafeArea()
            Text("Slabs")
                .font(.system(size: 44, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
                .tracking(0.5)
        }
    }
}

#Preview { SplashView() }
