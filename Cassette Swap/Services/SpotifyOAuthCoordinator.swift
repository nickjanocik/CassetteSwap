import AuthenticationServices
import UIKit

final class SpotifyOAuthCoordinator: NSObject {
    private var session: ASWebAuthenticationSession?

    func authenticate(with url: URL, callbackScheme: String) async throws -> URL {
        try await withCheckedThrowingContinuation { continuation in
            let session = ASWebAuthenticationSession(url: url, callbackURLScheme: callbackScheme) { callbackURL, error in
                self.session = nil

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
            session.prefersEphemeralWebBrowserSession = false
            self.session = session

            if session.start() == false {
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
