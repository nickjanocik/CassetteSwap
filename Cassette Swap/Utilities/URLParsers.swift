import Foundation

enum PlaylistLinkParser {
    static func parse(_ rawValue: String) throws -> PlaylistReference {
        let text = rawValue.trimmed
        guard let url = URL(string: text), let host = url.host?.lowercased() else {
            throw AppError.message("Enter a valid Spotify or Apple Music playlist URL.")
        }

        if host.contains("spotify.com") {
            return try parseSpotify(url: url)
        }

        if host.contains("music.apple.com") {
            return try parseAppleMusic(url: url)
        }

        throw AppError.message("Only public Spotify and Apple Music playlist links are supported.")
    }

    private static func parseSpotify(url: URL) throws -> PlaylistReference {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 2, components[0] == "playlist" else {
            throw AppError.message("That Spotify link is not a playlist URL.")
        }

        return PlaylistReference(
            service: .spotify,
            playlistID: components[1],
            storefront: nil,
            originalURL: url
        )
    }

    private static func parseAppleMusic(url: URL) throws -> PlaylistReference {
        let components = url.pathComponents.filter { $0 != "/" }
        guard components.count >= 3 else {
            throw AppError.message("That Apple Music link is not a playlist URL.")
        }

        guard let playlistIndex = components.firstIndex(of: "playlist"), playlistIndex < components.count - 1 else {
            throw AppError.message("That Apple Music link is not a playlist URL.")
        }

        let playlistID = components.last ?? ""
        guard playlistID.isEmpty == false else {
            throw AppError.message("That Apple Music playlist link is missing its playlist ID.")
        }

        return PlaylistReference(
            service: .appleMusic,
            playlistID: playlistID,
            storefront: components[0],
            originalURL: url
        )
    }
}

enum CassetteDeepLinkParser {
    static func parse(_ url: URL) -> CassettePayload? {
        guard url.scheme == "cassette-swap", url.host == "cassette" else {
            return nil
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let dataParam = components.queryItems?.first(where: { $0.name == "data" })?.value else {
            return nil
        }

        return try? CassettePayload.decode(from: dataParam)
    }
}

enum CassetteRemoteLinkParser {
    static func parse(_ url: URL, fallbackBaseURL: URL?) -> RemoteCassetteReference? {
        if url.scheme == "cassette-swap", url.host == "cassette" {
            guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
                return nil
            }

            let id = components.queryItems?
                .first(where: { $0.name == "id" })?
                .value?
                .trimmed
                .nilIfBlank

            guard let id else {
                return nil
            }

            let base = components.queryItems?.first(where: { $0.name == "base" })?.value
            let baseURL = base.flatMap(CassetteShareService.normalizedBaseURL(from:)) ?? fallbackBaseURL
            guard let baseURL else {
                return nil
            }

            return RemoteCassetteReference(id: id, baseURL: baseURL)
        }

        guard let scheme = url.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              let host = url.host else {
            return nil
        }

        let pathComponents = url.pathComponents.filter { $0 != "/" }
        guard pathComponents.count >= 2 else {
            return nil
        }

        let route = pathComponents[0]
        guard route == "c" || route == "cassette" else {
            return nil
        }

        let id = pathComponents[1]
        guard id.isEmpty == false else {
            return nil
        }

        var components = URLComponents()
        components.scheme = scheme
        components.host = host
        components.port = url.port

        guard let baseURL = components.url else {
            return nil
        }

        return RemoteCassetteReference(id: id, baseURL: baseURL)
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [] }

        var chunks: [[Element]] = []
        var index = startIndex

        while index < endIndex {
            let nextIndex = self.index(index, offsetBy: size, limitedBy: endIndex) ?? endIndex
            chunks.append(Array(self[index..<nextIndex]))
            index = nextIndex
        }

        return chunks
    }
}
