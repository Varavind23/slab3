import SwiftUI

/// Email/password sign-in and sign-up. Deliberately minimal — the four launch
/// users are known, so this is a gate, not a growth surface. Caliper's one cyan
/// primary action per screen is the submit button; nothing else here is cyan.
struct AuthScreen: View {
    let auth: AuthManager

    @State private var mode: Mode = .signIn
    @State private var email = ""
    @State private var password = ""
    @State private var working = false

    enum Mode { case signIn, signUp }

    var body: some View {
        VStack(spacing: Caliper.space7) {
            Spacer()
            // Wordmark only — no icon, no illustration.
            Text("Slabs")
                .font(.sans(34, .bold))
                .tracking(-1)
                .foregroundStyle(Caliper.textPrimary)
            Text("Scan. Price. Sell.").caliperLabel()

            // Each field gets its own hairline box — one box around the stack was
            // the bug the first screenshot caught.
            VStack(spacing: Caliper.space4) {
                TextField("Email", text: $email)
                    .textContentType(.emailAddress)
                    .keyboardType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .modifier(FieldBox())
                SecureField("Password", text: $password)
                    .textContentType(mode == .signUp ? .newPassword : .password)
                    .modifier(FieldBox())
            }
            .font(.calBody)
            .foregroundStyle(Caliper.textPrimary)
            .padding(.horizontal, Caliper.gutter)

            if let err = auth.errorMessage {
                // Errors state what happened, without apology or alarm.
                Text(err).caliperMeta(Caliper.confLow)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, Caliper.gutter)
            }

            CaliperButton(
                title: working ? "…" : (mode == .signIn ? "Log in" : "Create account"),
                variant: .primary,
                fullWidth: true,
                disabled: working || email.isEmpty || password.isEmpty
            ) {
                Task { await submit() }
            }
            .padding(.horizontal, Caliper.gutter)

            Button(mode == .signIn ? "Need an account? Sign up" : "Have an account? Log in") {
                mode = mode == .signIn ? .signUp : .signIn
                auth.errorMessage = nil
            }
            .font(.calBody)
            .foregroundStyle(Caliper.textSecondary)

            Spacer()
        }
        .padding(.vertical, Caliper.space8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Caliper.bg.ignoresSafeArea())
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
