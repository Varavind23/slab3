import SwiftUI

/// Email/password sign-in and sign-up. Deliberately minimal — the four launch
/// users are known, so this is a gate, not a growth surface.
struct AuthScreen: View {
    let auth: AuthManager

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    enum Mode { case signIn, signUp }

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            // Wordmark only — grayscale, no icon color (design.md §1, §4).
            Text("Slabs")
                .font(.system(size: 40, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.textPrimary)
            Text("Scan. Price. Sell.").foregroundStyle(Palette.textSecondary)

            VStack(spacing: 12) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("Password", text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)
            }
            .textFieldStyle(.roundedBorder)
            .padding(.horizontal)

            if let err = auth.errorMessage {
                // Errors state what happened, muted — not alarm-red (design.md §3).
                Text(err).font(.callout).foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center).padding(.horizontal)
            }

            // Primary action: grayscale, distinguished by contrast not color.
            Button {
                Task { await submit() }
            } label: {
                Group {
                    if working { ProgressView().tint(Palette.bg) }
                    else { Text(mode == .signIn ? "Log in" : "Create account").fontWeight(.semibold) }
                }
                .frame(maxWidth: .infinity).padding(.vertical, 12)
                .background(Palette.textPrimary, in: RoundedRectangle(cornerRadius: 12))
                .foregroundStyle(Palette.bg)
            }
            .padding(.horizontal)
            .disabled(working || email.isEmpty || password.isEmpty)
            .opacity(working || email.isEmpty || password.isEmpty ? 0.5 : 1)

            Button(mode == .signIn ? "Need an account? Sign up" : "Have an account? Log in") {
                mode = mode == .signIn ? .signUp : .signIn
                auth.errorMessage = nil
            }
            .font(.callout)
            .tint(Palette.textSecondary)

            Spacer()
        }
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Palette.bg)
    }

    private func submit() async {
        working = true
        defer { working = false }
        if mode == .signIn {
            await auth.signIn(email: email, password: password)
        } else {
            await auth.signUp(email: email, password: password)
        }
    }
}
