import SwiftUI

/// Connect the user's OWN Courtyard account (bring-your-own-account, 2026-10-29).
///
/// Why it exists: Courtyard put its price scanner behind login (spike/README.md
/// §2g), so Courtyard prices now come through each user's own account, the way
/// Card Ladder's do (owner decisions C1/C2). Courtyard has no password — it signs
/// in with an emailed code — so this is two steps where Card Ladder's sheet is one:
/// email → code. The server keeps the session sealed; this screen keeps nothing.
struct CourtyardConnectView: View {
    @AppStorage(PriceService.courtyardConnectedKey) private var connected = false
    @AppStorage(PriceService.courtyardExpiredKey) private var expired = false
    @Environment(\.dismiss) private var dismiss

    enum Step: Equatable { case email, code }

    @State private var step: Step
    @State private var email: String
    @State private var code = ""
    @State private var busy = false
    @State private var error: String?
    @FocusState private var codeFocused: Bool

    private let client = CourtyardAccountClient()

    /// The arguments exist for render tests, which need to show a later step.
    init(step: Step = .email, email: String = "", error: String? = nil) {
        _step = State(initialValue: step)
        _email = State(initialValue: email)
        _error = State(initialValue: error)
    }

    var body: some View {
        CaliperSheet(title: "Courtyard") {
            Button("Close") { dismiss() }
                .font(.mono(10, .medium))
                .foregroundStyle(Caliper.textSecondary)
        } content: {
            form
        } confirm: {
            if connected {
                CaliperButton(title: busy ? "Disconnecting…" : "Disconnect", variant: .danger,
                              fullWidth: true, disabled: busy) {
                    Task { await disconnect() }
                }
            } else if step == .email {
                CaliperButton(title: busy ? "Sending…" : "Send code", variant: .primary,
                              fullWidth: true, disabled: busy || !email.contains("@")) {
                    Task { await start() }
                }
            } else {
                CaliperButton(title: busy ? "Connecting…" : "Connect", variant: .primary,
                              fullWidth: true, disabled: busy || code.count < 4) {
                    Task { await verify() }
                }
            }
        }
        .background(Caliper.bg)
    }

    /// The sheet's body, apart from its ScrollView so a render test can draw it:
    /// ImageRenderer leaves a ScrollView's contents blank (ManualEntryRenderTests).
    var form: some View {
    VStack(alignment: .leading, spacing: Caliper.space6) {
        if connected {
            HStack(spacing: Caliper.space4) {
                Circle().fill(Caliper.srcCY).frame(width: 6, height: 6)
                Text("Connected").font(.calBody).foregroundStyle(Caliper.textPrimary)
            }
            Text("Courtyard's market values fill the CY column, fetched with your own Courtyard login.")
                .caliperMeta()
        } else if step == .email {
            if expired {
                Text("Your Courtyard sign-in expired. Enter your email to get a new code.")
                    .caliperMeta(Caliper.confMid)
            }
            TextField("Courtyard email", text: $email)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .modifier(FieldBox())
            Text("Courtyard signs in with a code sent to your email. Use the email of your existing Courtyard account; Slabs never creates one.")
                .caliperMeta(Caliper.textTertiary)
        } else {
            Text("Courtyard sent a code to \(email).").caliperMeta()
            TextField("Code", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .focused($codeFocused)
                .modifier(FieldBox())
            HStack(spacing: Caliper.space6) {
                Button("Change email") { step = .email; code = ""; error = nil }
                Button("Send a new code") { Task { await start() } }
                    .disabled(busy)
            }
            .font(.mono(10, .medium))
            .foregroundStyle(Caliper.textSecondary)
            Text("Your session is stored encrypted on the server and used only to fetch your Courtyard prices.")
                .caliperMeta(Caliper.textTertiary)
        }
        if let error {
            Text(error).caliperMeta(Caliper.confLow)
        }
    }
    .font(.calBody)
    .foregroundStyle(Caliper.textPrimary)
    .padding(.horizontal, Caliper.gutter)
    .padding(.top, Caliper.space6)
    }

    private var trimmedEmail: String { email.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func start() async {
        busy = true; error = nil
        defer { busy = false }
        switch await client.start(email: trimmedEmail) {
        case .sent:
            step = .code
            code = ""
            codeFocused = true
        case .invalidEmail: error = "That isn't a valid email address."
        case .rateLimited: error = "Courtyard is limiting sign-in attempts. Wait a minute and try again."
        case .unreachable: error = "Couldn't reach Courtyard. Try again."
        }
    }

    private func verify() async {
        busy = true; error = nil
        defer { busy = false }
        switch await client.verify(email: trimmedEmail, code: code) {
        case .connected:
            connected = true
            expired = false
            code = ""
            dismiss()
        case .invalidCode: error = "That code didn't work. Check it, or send a new one."
        case .noAccount: error = "No Courtyard account uses that email. Create one in the Courtyard app, then connect it here."
        case .rejected: error = "Courtyard accepted the code but refused price lookups for this account."
        case .rateLimited: error = "Courtyard is limiting sign-in attempts. Wait a minute and try again."
        case .unreachable: error = "Couldn't reach Courtyard. Try again."
        }
    }

    /// Only once the server has forgotten the session (the CardLadderConnectView rule).
    private func disconnect() async {
        busy = true; error = nil
        defer { busy = false }
        if await client.disconnect() {
            connected = false
            expired = false
            step = .email
        } else {
            error = "Couldn't disconnect. Nothing changed. Try again."
        }
    }
}
