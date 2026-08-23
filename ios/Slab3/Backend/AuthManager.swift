import Foundation
import Supabase

/// Owns the auth session and exposes sign-in / sign-up / sign-out. The app gates
/// on `state`: `.signedOut` shows the auth screen, `.signedIn` shows the app.
@MainActor
@Observable
final class AuthManager {
    enum State: Equatable {
        case loading
        case signedOut
        case signedIn(userId: UUID, email: String?)
    }

    private(set) var state: State = .loading
    var errorMessage: String?

    /// Start listening to auth changes and resolve the initial session.
    func start() async {
        for await (event, session) in Backend.client.auth.authStateChanges {
            switch event {
            case .initialSession, .signedIn, .tokenRefreshed, .userUpdated:
                if let session {
                    state = .signedIn(userId: session.user.id, email: session.user.email)
                } else {
                    state = .signedOut
                }
            case .signedOut:
                state = .signedOut
            default:
                break
            }
        }
    }

    func signIn(email: String, password: String) async {
        errorMessage = nil
        do {
            try await Backend.client.auth.signIn(email: email, password: password)
        } catch {
            errorMessage = friendly(error)
        }
    }

    func signUp(email: String, password: String) async {
        errorMessage = nil
        do {
            try await Backend.client.auth.signUp(email: email, password: password)
            // If email confirmation is ON, session stays nil until confirmed.
            if case .some = try? await Backend.client.auth.session {
                // signed in immediately (confirmation disabled)
            } else {
                errorMessage = "Check your email to confirm your account, then log in."
            }
        } catch {
            errorMessage = friendly(error)
        }
    }

    func signOut() async {
        try? await Backend.client.auth.signOut()
    }

    private func friendly(_ error: Error) -> String {
        let msg = error.localizedDescription
        if msg.localizedCaseInsensitiveContains("invalid login") { return "Wrong email or password." }
        return msg
    }
}
