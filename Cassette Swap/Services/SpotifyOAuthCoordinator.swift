import AuthenticationServices
import UIKit

final class SpotifyOAuthCoordinator: NSObject {
    private var session: ASWebAuthenticationSession?

    @MainActor
    func authenticate(with url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            print("[SpotifyOAuth] Starting ASWebAuthenticationSession")

            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { [weak self] callbackURL, error in
                self?.session = nil
                print("[SpotifyOAuth] Completion fired. URL: \(callbackURL?.absoluteString ?? "nil"), error: \(error?.localizedDescription ?? "nil")")

                if let callbackURL {
                    continuation.resume(returning: callbackURL)
                    return
                }

                if let error {
                    continuation.resume(throwing: error)
                    return
                }

                continuation.resume(throwing: AppError.message("Spotify sign-in did not complete."))
            }

            session.presentationContextProvider = self
            session.prefersEphemeralWebBrowserSession = true
            self.session = session

            let started = session.start()
            print("[SpotifyOAuth] session.start() returned: \(started)")

            if !started {
                self.session = nil
                continuation.resume(throwing: AppError.message("Unable to open the Spotify sign-in flow."))
            }
        }
    }
}

extension SpotifyOAuthCoordinator: ASWebAuthenticationPresentationContextProviding {
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        for case let scene as UIWindowScene in UIApplication.shared.connectedScenes {
            if let window = scene.windows.first(where: \.isKeyWindow) {
                return window
            }

            if let window = scene.windows.first {
                return window
            }
        }

        return UIWindow()
    }
}
