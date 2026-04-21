import CryptoKit
import Foundation

final class SpotifyService {
    static let redirectURI = "cassette-swap://spotify-callback"
    static let clientID = "5c1a3737ee8046df8a340af0a377af19"

    private let authCoordinator = SpotifyOAuthCoordinator()
    private let tokenStore = SpotifyTokenStore()
    private let session = URLSession.shared

    init() {}

    func signIn() async throws -> MusicAccount {
        try await ensureAuthorized(requiredScopes: [.playlistReadPrivate, .playlistReadCollaborative])
        let profile = try await fetchCurrentUserProfile()
        return MusicAccount(
            service: .spotify,
            userID: profile.id,
            displayName: profile.displayName ?? profile.id,
            profileImageURL: profile.images.first?.url
        )
    }

    func fetchOwnedPlaylists() async throws -> [UserPlaylist] {
        let profile = try await fetchCurrentUserProfile()
        var playlists: [UserPlaylist] = []
        var offset = 0
        let pageSize = 50

        while true {
            let page: SpotifyCurrentUserPlaylistsPage = try await apiRequest(
                path: "/v1/me/playlists?limit=\(pageSize)&offset=\(offset)",
                requiredScopes: [.playlistReadPrivate, .playlistReadCollaborative]
            )

            let ownedPublic = page.items
                .filter { $0.owner?.id == profile.id && $0.isPublic != false }
                .map {
                    UserPlaylist(
                        id: $0.id,
                        service: .spotify,
                        name: $0.name,
                        summary: ($0.description ?? "").strippedHTML,
                        artworkURL: $0.images.first?.url,
                        ownerName: profile.displayName ?? profile.id
                    )
                }

            playlists.append(contentsOf: ownedPublic)
            offset += page.items.count

            if page.next == nil || page.items.isEmpty {
                break
            }
        }

        return playlists
    }

    func fetchOwnedPlaylist(id: String) async throws -> PlaylistSnapshot {
        let profile = try await fetchCurrentUserProfile()
        let snapshot = try await fetchPlaylist(id: id, originalURL: URL(string: "https://open.spotify.com/playlist/\(id)")!)

        return PlaylistSnapshot(
            id: snapshot.id,
            reference: snapshot.reference,
            name: snapshot.name,
            summary: snapshot.summary,
            artworkURL: snapshot.artworkURL,
            tracks: snapshot.tracks,
            ownerName: profile.displayName ?? profile.id,
            ownerImageURL: profile.images.first?.url
        )
    }

    func fetchPlaylist(id: String, originalURL: URL) async throws -> PlaylistSnapshot {
        let readScopes: Set<SpotifyScope> = [.playlistReadPrivate, .playlistReadCollaborative]
        try await ensureAuthorized(requiredScopes: readScopes)

        let metadata: SpotifyPlaylistMetadata
        var tracks: [TransferTrack] = []

        do {
            metadata = try await apiRequest(path: "/v1/playlists/\(id)?market=from_token")
        } catch {
            throw explainPlaylistReadFailure(error)
        }

        var offset = 0
        let pageSize = 100

        while true {
            do {
                let page: SpotifyPlaylistItemsPage = try await apiRequest(
                    path: "/v1/playlists/\(id)/items?limit=\(pageSize)&offset=\(offset)&additional_types=track&market=from_token",
                    requiredScopes: readScopes
                )

                for entry in page.items {
                    guard let track = entry.resolvedTrack, track.type == "track", entry.isLocal != true, let id = track.id else {
                        continue
                    }

                    tracks.append(
                        TransferTrack(
                            id: id,
                            title: track.name,
                            artistName: track.artists.map(\.name).joined(separator: ", "),
                            albumTitle: track.album?.name,
                            isrc: track.externalIDs?.isrc,
                            originalPosition: tracks.count + 1
                        )
                    )
                }

                offset += page.items.count
                if page.items.isEmpty || offset >= page.total {
                    break
                }
            } catch {
                throw explainPlaylistReadFailure(error)
            }
        }

        return PlaylistSnapshot(
            id: id,
            reference: PlaylistReference(
                service: .spotify,
                playlistID: id,
                storefront: nil,
                originalURL: originalURL
            ),
            name: metadata.name,
            summary: (metadata.description ?? "").strippedHTML,
            artworkURL: metadata.images.first?.url,
            tracks: tracks,
            ownerName: nil,
            ownerImageURL: nil
        )
    }

    func resolveTracks(from sourceTracks: [TransferTrack], progress: ProgressHandler? = nil) async throws -> TrackResolution {
        try await ensureAuthorized(requiredScopes: [])

        var matched: [DestinationTrackReference] = []
        var unmatched: [TransferTrack] = []
        var isrcCache: [String: DestinationTrackReference?] = [:]
        var textCache: [String: DestinationTrackReference?] = [:]

        for (index, track) in sourceTracks.enumerated() {
            if let progress {
                let fraction = sourceTracks.isEmpty ? 1 : Double(index) / Double(sourceTracks.count)
                await progress("Matching track \(index + 1) of \(sourceTracks.count) on Spotify...", fraction)
            }

            if let isrc = track.isrc?.uppercased(), !isrc.isEmpty, let cached = isrcCache[isrc] {
                if let cached {
                    matched.append(cached)
                } else {
                    unmatched.append(track)
                }
                continue
            }

            let textKey = "\(track.title.normalizedForMatching)|\(track.artistName.normalizedForMatching)|\(track.albumTitle?.normalizedForMatching ?? "")"
            if let cached = textCache[textKey] {
                if let cached {
                    matched.append(cached)
                } else {
                    unmatched.append(track)
                }
                continue
            }

            let resolved = try await findSpotifyTrack(for: track)

            if let isrc = track.isrc?.uppercased(), !isrc.isEmpty {
                isrcCache[isrc] = resolved
            }
            textCache[textKey] = resolved

            if let resolved {
                matched.append(resolved)
            } else {
                unmatched.append(track)
            }
        }

        if let progress {
            await progress("Matched \(matched.count) of \(sourceTracks.count) tracks on Spotify.", 1)
        }

        return TrackResolution(matched: matched, unmatched: unmatched)
    }

    func createPlaylist(from snapshot: PlaylistSnapshot, matchedTracks: [DestinationTrackReference], copyArtwork: Bool) async throws -> (playlistID: String, playlistURL: URL?, artworkCopied: Bool) {
        let scopes = copyArtwork ? Set([SpotifyScope.playlistModifyPublic, SpotifyScope.ugcImageUpload]) : Set([SpotifyScope.playlistModifyPublic])
        try await ensureAuthorized(requiredScopes: scopes)

        let createBody = SpotifyCreatePlaylistRequest(
            name: snapshot.name.truncated(to: 100),
            description: snapshot.summary.truncated(to: 300).nilIfBlank,
            public: true
        )

        let payload = try JSONEncoder().encode(createBody)
        let created: SpotifyCreatedPlaylist = try await apiRequest(
            path: "/v1/me/playlists",
            method: "POST",
            body: payload,
            contentType: "application/json",
            requiredScopes: scopes
        )

        let uris = matchedTracks.compactMap(\.uri)
        for chunk in uris.chunked(into: 100) {
            let addBody = try JSONEncoder().encode(SpotifyAddTracksRequest(uris: chunk))
            try await apiRequestWithoutBody(
                path: "/v1/playlists/\(created.id)/items",
                method: "POST",
                body: addBody,
                contentType: "application/json",
                requiredScopes: [.playlistModifyPublic]
            )
        }

        var artworkCopied = false
        if copyArtwork, let artworkURL = snapshot.artworkURL {
            do {
                let imagePayload = try await ImageTransferService.spotifyJPEGBase64Body(from: artworkURL)
                try await apiRequestWithoutBody(
                    path: "/v1/playlists/\(created.id)/images",
                    method: "PUT",
                    body: imagePayload,
                    contentType: "image/jpeg",
                    requiredScopes: [.ugcImageUpload]
                )
                artworkCopied = true
            } catch {
                artworkCopied = false
            }
        }

        return (playlistID: created.id, playlistURL: created.externalURLs.spotify, artworkCopied: artworkCopied)
    }

    private func findSpotifyTrack(for track: TransferTrack) async throws -> DestinationTrackReference? {
        if let isrc = track.isrc?.uppercased(), !isrc.isEmpty {
            let results = try await searchTracks(query: "isrc:\(isrc)", limit: 5)
            if let best = results.first {
                return DestinationTrackReference(id: best.id, type: best.type, uri: best.uri)
            }
        }

        let strictResults = try await searchTracks(query: "track:\(track.title) artist:\(track.artistName)", limit: 10)
        if let best = bestSpotifyMatch(in: strictResults, for: track) {
            let score = TrackMatcher.score(
                source: track,
                candidateTitle: best.name,
                candidateArtist: best.artists.map(\.name).joined(separator: ", "),
                candidateAlbum: best.album?.name,
                candidateISRC: nil
            )

            if TrackMatcher.isGoodEnough(score) {
                return DestinationTrackReference(id: best.id, type: best.type, uri: best.uri)
            }
        }

        let fallbackResults = try await searchTracks(query: "\(track.title) \(track.artistName) \(track.albumTitle ?? "")", limit: 10)
        guard let best = bestSpotifyMatch(in: fallbackResults, for: track) else {
            return nil
        }

        let score = TrackMatcher.score(
            source: track,
            candidateTitle: best.name,
            candidateArtist: best.artists.map(\.name).joined(separator: ", "),
            candidateAlbum: best.album?.name,
            candidateISRC: nil
        )

        guard TrackMatcher.isGoodEnough(score) else {
            return nil
        }

        return DestinationTrackReference(id: best.id, type: best.type, uri: best.uri)
    }

    private func bestSpotifyMatch(in candidates: [SpotifySearchTrack], for sourceTrack: TransferTrack) -> SpotifySearchTrack? {
        candidates.max { lhs, rhs in
            TrackMatcher.score(
                source: sourceTrack,
                candidateTitle: lhs.name,
                candidateArtist: lhs.artists.map(\.name).joined(separator: ", "),
                candidateAlbum: lhs.album?.name,
                candidateISRC: nil
            ) <
            TrackMatcher.score(
                source: sourceTrack,
                candidateTitle: rhs.name,
                candidateArtist: rhs.artists.map(\.name).joined(separator: ", "),
                candidateAlbum: rhs.album?.name,
                candidateISRC: nil
            )
        }
    }

    private func searchTracks(query: String, limit: Int) async throws -> [SpotifySearchTrack] {
        var components = URLComponents(string: "https://api.spotify.com/v1/search")!
        components.queryItems = [
            URLQueryItem(name: "type", value: "track"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "q", value: query)
        ]

        let response: SpotifySearchEnvelope = try await apiRequest(url: components.url!)
        return response.tracks.items
    }

    private func fetchCurrentUserProfile() async throws -> SpotifyCurrentUserProfile {
        try await ensureAuthorized(requiredScopes: [.playlistReadPrivate, .playlistReadCollaborative])
        return try await apiRequest(path: "/v1/me", requiredScopes: [.playlistReadPrivate, .playlistReadCollaborative])
    }

    private func ensureAuthorized(requiredScopes: Set<SpotifyScope>) async throws {
        let clientID = try validatedClientID()
        let scopeValues = Set(requiredScopes.map(\.rawValue))

        if let token = tokenStore.load(), token.scopes.isSuperset(of: scopeValues) {
            if token.isExpired {
                if let refreshed = try await refreshTokenIfPossible(clientID: clientID, existing: token) {
                    tokenStore.save(refreshed)
                    return
                }
            } else {
                return
            }
        }

        let freshToken = try await authorize(clientID: clientID, requiredScopes: scopeValues)
        tokenStore.save(freshToken)
    }

    private func authorize(clientID: String, requiredScopes: Set<String>) async throws -> SpotifyTokenRecord {
        let verifier = Self.randomVerifier()
        let challenge = Self.codeChallenge(for: verifier)
        let state = UUID().uuidString

        var components = URLComponents(string: "https://accounts.spotify.com/authorize")!
        var items = [
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "client_id", value: clientID),
            URLQueryItem(name: "redirect_uri", value: Self.redirectURI),
            URLQueryItem(name: "code_challenge_method", value: "S256"),
            URLQueryItem(name: "code_challenge", value: challenge),
            URLQueryItem(name: "state", value: state),
            URLQueryItem(name: "show_dialog", value: "false")
        ]

        if requiredScopes.isEmpty == false {
            items.append(URLQueryItem(name: "scope", value: requiredScopes.sorted().joined(separator: " ")))
        }

        components.queryItems = items

        let callbackURL = try await authCoordinator.authenticate(with: components.url!, callbackScheme: "cassette-swap")
        guard let callbackComponents = URLComponents(url: callbackURL, resolvingAgainstBaseURL: false) else {
            throw AppError.message("Spotify returned an invalid callback URL.")
        }

        if let error = callbackComponents.queryItems?.first(where: { $0.name == "error" })?.value {
            throw AppError.message("Spotify sign-in failed: \(error).")
        }

        guard callbackComponents.queryItems?.first(where: { $0.name == "state" })?.value == state else {
            throw AppError.message("Spotify sign-in returned an invalid state.")
        }

        guard let code = callbackComponents.queryItems?.first(where: { $0.name == "code" })?.value else {
            throw AppError.message("Spotify did not return an authorization code.")
        }

        let tokenResponse: SpotifyTokenResponse = try await tokenRequest(
            parameters: [
                "client_id": clientID,
                "grant_type": "authorization_code",
                "code": code,
                "redirect_uri": Self.redirectURI,
                "code_verifier": verifier
            ]
        )

        return SpotifyTokenRecord(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken,
            expirationDate: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            scopes: Set((tokenResponse.scope ?? "").split(separator: " ").map(String.init))
        )
    }

    private func refreshTokenIfPossible(clientID: String, existing: SpotifyTokenRecord) async throws -> SpotifyTokenRecord? {
        guard let refreshToken = existing.refreshToken else {
            return nil
        }

        let tokenResponse: SpotifyTokenResponse = try await tokenRequest(
            parameters: [
                "client_id": clientID,
                "grant_type": "refresh_token",
                "refresh_token": refreshToken
            ]
        )

        return SpotifyTokenRecord(
            accessToken: tokenResponse.accessToken,
            refreshToken: tokenResponse.refreshToken ?? refreshToken,
            expirationDate: Date().addingTimeInterval(TimeInterval(tokenResponse.expiresIn)),
            scopes: (tokenResponse.scope ?? "").isEmpty ? existing.scopes : Set((tokenResponse.scope ?? "").split(separator: " ").map(String.init))
        )
    }

    private func tokenRequest<Response: Decodable>(parameters: [String: String]) async throws -> Response {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = Self.formEncodedData(from: parameters)

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.message("Spotify returned an invalid token response.")
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw spotifyError(from: data, fallback: "Spotify token exchange failed.")
        }

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func apiRequest<Response: Decodable>(
        path: String? = nil,
        url: URL? = nil,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        requiredScopes: Set<SpotifyScope> = []
    ) async throws -> Response {
        let data = try await rawAPIRequest(
            path: path,
            url: url,
            method: method,
            body: body,
            contentType: contentType,
            requiredScopes: requiredScopes
        )

        return try JSONDecoder().decode(Response.self, from: data)
    }

    private func apiRequestWithoutBody(
        path: String? = nil,
        url: URL? = nil,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        requiredScopes: Set<SpotifyScope> = []
    ) async throws {
        _ = try await rawAPIRequest(
            path: path,
            url: url,
            method: method,
            body: body,
            contentType: contentType,
            requiredScopes: requiredScopes
        )
    }

    private func rawAPIRequest(
        path: String? = nil,
        url: URL? = nil,
        method: String = "GET",
        body: Data? = nil,
        contentType: String? = nil,
        requiredScopes: Set<SpotifyScope> = [],
        retryingAfterRefresh: Bool = false
    ) async throws -> Data {
        try await ensureAuthorized(requiredScopes: requiredScopes)

        guard let token = tokenStore.load()?.accessToken else {
            throw AppError.message("Spotify is not authorized.")
        }

        let requestURL: URL
        if let url {
            requestURL = url
        } else if let path, let resolved = URL(string: path, relativeTo: URL(string: "https://api.spotify.com")) {
            requestURL = resolved
        } else {
            throw AppError.message("Spotify request URL was invalid.")
        }

        var request = URLRequest(url: requestURL)
        request.httpMethod = method
        request.httpBody = body
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        if let contentType {
            request.setValue(contentType, forHTTPHeaderField: "Content-Type")
        }

        let (data, response) = try await session.data(for: request)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.message("Spotify returned an invalid response.")
        }

        #if DEBUG
        if !(200..<300).contains(httpResponse.statusCode) {
            let bodyPreview = String(data: data.prefix(500), encoding: .utf8) ?? "(non-text)"
            print("[SpotifyAPI] \(method) \(requestURL.absoluteString) → HTTP \(httpResponse.statusCode): \(bodyPreview)")
        }
        #endif

        if [401, 403, 404].contains(httpResponse.statusCode) && retryingAfterRefresh == false {
            let clientID = try validatedClientID()
            if tokenStore.load() != nil {
                if httpResponse.statusCode == 401 {
                    // Try refreshing first for auth failures
                    if let existing = tokenStore.load(),
                       let refreshed = try await refreshTokenIfPossible(clientID: clientID, existing: existing) {
                        tokenStore.save(refreshed)
                    } else {
                        let freshToken = try await authorize(clientID: clientID, requiredScopes: Set(requiredScopes.map(\.rawValue)))
                        tokenStore.save(freshToken)
                    }
                } else {
                    // 403/404: token may be for wrong account or stale — force full re-auth
                    tokenStore.clear()
                    let freshToken = try await authorize(clientID: clientID, requiredScopes: Set(requiredScopes.map(\.rawValue)))
                    tokenStore.save(freshToken)
                }
                return try await rawAPIRequest(
                    path: path,
                    url: url,
                    method: method,
                    body: body,
                    contentType: contentType,
                    requiredScopes: requiredScopes,
                    retryingAfterRefresh: true
                )
            }
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            throw spotifyError(from: data, fallback: "Spotify returned HTTP \(httpResponse.statusCode).")
        }

        return data
    }

    private func spotifyError(from data: Data, fallback: String) -> Error {
        if let payload = try? JSONDecoder().decode(SpotifyAPIErrorEnvelope.self, from: data) {
            return AppError.message(payload.error.message ?? fallback)
        }

        return AppError.message(fallback)
    }

    private func validatedClientID() throws -> String {
        Self.clientID
    }

    private func explainPlaylistReadFailure(_ error: Error) -> Error {
        let message = error.localizedDescription.lowercased()
        if message.contains("resource not found") || message.contains("forbidden") {
            return AppError.message(
                "Spotify Dev Mode can only read playlist items for playlists you own or collaborate on. Try one of your own Spotify playlists."
            )
        }

        return error
    }

    private static func randomVerifier() -> String {
        let raw = UUID().uuidString + UUID().uuidString + UUID().uuidString
        return raw.replacingOccurrences(of: "-", with: "")
    }

    private static func codeChallenge(for verifier: String) -> String {
        let data = Data(verifier.utf8)
        let digest = SHA256.hash(data: data)
        return Data(digest).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func formEncodedData(from parameters: [String: String]) -> Data? {
        let body = parameters
            .sorted(by: { $0.key < $1.key })
            .map { key, value in
                "\(Self.percentEncode(key))=\(Self.percentEncode(value))"
            }
            .joined(separator: "&")

        return Data(body.utf8)
    }

    private static func percentEncode(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "+&="))) ?? value
    }
}

private enum SpotifyScope: String {
    case playlistReadPrivate = "playlist-read-private"
    case playlistReadCollaborative = "playlist-read-collaborative"
    case playlistModifyPublic = "playlist-modify-public"
    case ugcImageUpload = "ugc-image-upload"
}

private struct SpotifyTokenRecord: Codable {
    let accessToken: String
    let refreshToken: String?
    let expirationDate: Date
    let scopes: Set<String>

    var isExpired: Bool {
        expirationDate <= Date().addingTimeInterval(60)
    }
}

private final class SpotifyTokenStore {
    private let defaultsKey = "cassette_swap.spotify_token"

    func load() -> SpotifyTokenRecord? {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey) else {
            return nil
        }

        return try? JSONDecoder().decode(SpotifyTokenRecord.self, from: data)
    }

    func save(_ token: SpotifyTokenRecord) {
        guard let data = try? JSONEncoder().encode(token) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }

    func clear() {
        UserDefaults.standard.removeObject(forKey: defaultsKey)
    }
}

private struct SpotifyTokenResponse: Decodable {
    let accessToken: String
    let tokenType: String
    let scope: String?
    let expiresIn: Int
    let refreshToken: String?

    enum CodingKeys: String, CodingKey {
        case accessToken = "access_token"
        case tokenType = "token_type"
        case scope
        case expiresIn = "expires_in"
        case refreshToken = "refresh_token"
    }
}

private struct SpotifyPlaylistMetadata: Decodable {
    let name: String
    let description: String?
    let images: [SpotifyImage]

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case images
    }
}

private struct SpotifyCurrentUserProfile: Decodable {
    let id: String
    let displayName: String?
    let images: [SpotifyImage]

    enum CodingKeys: String, CodingKey {
        case id
        case displayName = "display_name"
        case images
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        displayName = try container.decodeIfPresent(String.self, forKey: .displayName)
        images = try container.decodeIfPresent([SpotifyImage].self, forKey: .images) ?? []
    }
}

private struct SpotifyCurrentUserPlaylistsPage: Decodable {
    let items: [SpotifyOwnedPlaylist]
    let next: String?

    enum CodingKeys: String, CodingKey {
        case items
        case next
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        items = try container.decodeIfPresent([SpotifyOwnedPlaylist].self, forKey: .items) ?? []
        next = try container.decodeIfPresent(String.self, forKey: .next)
    }
}

private struct SpotifyOwnedPlaylist: Decodable {
    let id: String
    let name: String
    let description: String?
    let images: [SpotifyImage]
    let owner: SpotifyPlaylistOwner?
    let isPublic: Bool?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case description
        case images
        case owner
        case isPublic = "public"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? "Untitled Playlist"
        description = try container.decodeIfPresent(String.self, forKey: .description)
        images = try container.decodeIfPresent([SpotifyImage].self, forKey: .images) ?? []
        owner = try container.decodeIfPresent(SpotifyPlaylistOwner.self, forKey: .owner)
        isPublic = try container.decodeIfPresent(Bool.self, forKey: .isPublic)
    }
}

private struct SpotifyPlaylistOwner: Decodable {
    let id: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let raw = try? container.decode([String: String].self), let id = raw["id"], !id.isEmpty {
            self.id = id
        } else {
            let keyed = try decoder.container(keyedBy: CodingKeys.self)
            self.id = try keyed.decodeIfPresent(String.self, forKey: .id) ?? ""
        }
    }

    private enum CodingKeys: String, CodingKey {
        case id
    }
}

private struct SpotifyImage: Decodable {
    let url: URL?

    enum CodingKeys: String, CodingKey {
        case url
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        if let urlString = try container.decodeIfPresent(String.self, forKey: .url) {
            url = URL(string: urlString)
        } else {
            url = nil
        }
    }
}

private struct SpotifyPlaylistItemsPage: Decodable {
    let items: [SpotifyPlaylistPageItem]
    let total: Int
}

private struct SpotifyPlaylistPageItem: Decodable {
    let item: SpotifyPlaylistTrack?
    let track: SpotifyPlaylistTrack?
    let isLocal: Bool?

    var resolvedTrack: SpotifyPlaylistTrack? {
        item ?? track
    }

    enum CodingKeys: String, CodingKey {
        case item
        case track
        case isLocal = "is_local"
    }
}

private struct SpotifyPlaylistTrack: Decodable {
    let id: String?
    let name: String
    let uri: String
    let type: String
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum?
    let externalIDs: SpotifyExternalIDs?

    enum CodingKeys: String, CodingKey {
        case id
        case name
        case uri
        case type
        case artists
        case album
        case externalIDs = "external_ids"
    }
}

private struct SpotifyArtist: Decodable {
    let name: String
}

private struct SpotifyAlbum: Decodable {
    let name: String
}

private struct SpotifyExternalIDs: Decodable {
    let isrc: String?
}

private struct SpotifySearchEnvelope: Decodable {
    let tracks: SpotifySearchResults
}

private struct SpotifySearchResults: Decodable {
    let items: [SpotifySearchTrack]
}

private struct SpotifySearchTrack: Decodable {
    let id: String
    let name: String
    let uri: String
    let type: String
    let artists: [SpotifyArtist]
    let album: SpotifyAlbum?
}

private struct SpotifyCreatePlaylistRequest: Encodable {
    let name: String
    let description: String?
    let `public`: Bool

    enum CodingKeys: String, CodingKey {
        case name
        case description
        case `public`
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(name, forKey: .name)
        try container.encode(`public`, forKey: .public)

        if let description {
            try container.encode(description, forKey: .description)
        }
    }
}

private struct SpotifyCreatedPlaylist: Decodable {
    let id: String
    let externalURLs: SpotifyPublicURLs

    enum CodingKeys: String, CodingKey {
        case id
        case externalURLs = "external_urls"
    }
}

private struct SpotifyPublicURLs: Decodable {
    let spotify: URL?
}

private struct SpotifyAddTracksRequest: Encodable {
    let uris: [String]
}

private struct SpotifyAPIErrorEnvelope: Decodable {
    let error: SpotifyAPIError
}

private struct SpotifyAPIError: Decodable {
    let message: String?
}
