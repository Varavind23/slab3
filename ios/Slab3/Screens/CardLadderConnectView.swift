import SwiftUI

/// Connect the user's OWN Card Ladder account (bring-your-own-account).
/// Credentials go to the server, are validated with a real Card Ladder sign-in and
/// stored encrypted — the app keeps nothing beyond this screen. Once connected,
/// Card Ladder prices appear in the CL column for this user only.
struct CardLadderConnectView: View {
    @AppStorage(PriceService.connectedKey) private var connected = false
    @Environment(\.dismiss) private var dismiss

    @State private var email = ""
    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    private let client = CardLadderClient()

    var body: some View {
        CaliperSheet(title: "Card Ladder") {
            Button("Close") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            VStack(alignment: .leading, spacing: Caliper.space6) {
                if connected {
                    HStack(spacing: Caliper.space4) {
                        Circle().fill(Caliper.srcCL).frame(width: 6, height: 6)
                        Text("Connected").font(.calBody).foregroundStyle(Caliper.textPrimary)
                    }
                    Text("Your own subscription's average-sale prices fill the CL column.")
                        .caliperMeta()
                } else {
                    TextField("Email", text: $email)
                        .textContentType(.username)
                        .keyboardType(.emailAddress)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .modifier(FieldBox())
                    SecureField("Password", text: $password)
                        .textContentType(.password)
                        .modifier(FieldBox())
                    Text("Uses your own paid Card Ladder login. Credentials are stored encrypted on the server and used only to fetch your prices.")
                        .caliperMeta(Caliper.textTertiary)
                    if let error {
                        Text(error).caliperMeta(Caliper.confLow)
                    }
                }
            }
            .font(.calBody)
            .foregroundStyle(Caliper.textPrimary)
            .padding(.horizontal, Caliper.gutter)
            .padding(.top, Caliper.space6)
        } confirm: {
            if connected {
                CaliperButton(title: "Disconnect", variant: .danger, fullWidth: true) {
                    connected = false
                }
            } else {
                CaliperButton(
                    title: busy ? "Connecting…" : "Connect",
                    variant: .primary,
                    fullWidth: true,
                    disabled: busy || email.isEmpty || password.isEmpty
                ) {
                    Task { await connect() }
                }
            }
        }
        .background(Caliper.bg)
    }

    private func connect() async {
        busy = true; error = nil
        defer { busy = false }
        switch await client.connect(email: email, password: password) {
        case .connected:
            connected = true
            password = ""
            dismiss()
        case .invalidCredentials:
            error = "Wrong Card Ladder email or password."
        case .unreachable:
            error = "Couldn't reach Card Ladder. Try again."
        }
    }
}

/// The system's one text-field treatment: hairline box, square, no fill.
struct FieldBox: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(.horizontal, Caliper.rowPad)
            .frame(height: Caliper.hitMin)
            .overlay(Rectangle().strokeBorder(Caliper.lineStrong, lineWidth: Caliper.borderWidth))
    }
}
