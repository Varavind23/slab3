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
            Image(systemName: "barcode.viewfinder").font(.system(size: 52)).foregroundStyle(.tint)
            Text("Slab3").font(.largeTitle.bold())
            Text("Scan. Price. Sell.").foregroundStyle(.secondary)

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
                Text(err).font(.callout).foregroundStyle(.red).multilineTextAlignment(.center).padding(.horizontal)
            }

            Button {
                Task { await submit() }
            } label: {
                if working { ProgressView() }
                else { Text(mode == .signIn ? "Log in" : "Create account").bold() }
            }
            .buttonStyle(.borderedProminent)
            .disabled(working || email.isEmpty || password.isEmpty)

            Button(mode == .signIn ? "Need an account? Sign up" : "Have an account? Log in") {
                mode = mode == .signIn ? .signUp : .signIn
                auth.errorMessage = nil
            }
            .font(.callout)

            Spacer()
        }
        .padding()
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
