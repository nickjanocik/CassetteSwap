import Foundation
import MusicKit

final class AppleMusicService {
    func signIn() async throws -> MusicAccount {
        try await ensureAuthorized()
        return MusicAccount(service: .appleMusic, userID: nil, displayName: "Apple Music", profileImageURL: nil)
    }

    func fetchOwnedPlaylists() async throws -> [UserPlaylist] {
        try await ensureAuthorized()
        var request = MusicLibraryRequest<Playlist>()
        request.limit = 100
        let response = try await request.response()

        return response.items.map { playlist in
            UserPlaylist(
                id: playlist.id.rawValue,
                service: .appleMusic,
                name: playlist.name,
                summary: playlist.standardDescription?.strippedHTML.nilIfBlank
                    ?? playlist.shortDescription?.strippedHTML.nilIfBlank
                    ?? "",
                artworkURL: normalizedArtworkURL(playlist.artwork?.url(width: 600, height: 600)),
                ownerName: playlist.curatorName?.nilIfBlank ?? "Apple Music"
            )
        }
    }

    func fetchOwnedPlaylist(id: String) async throws -> PlaylistSnapshot {
        try await ensureAuthorized()
        var request = MusicLibraryRequest<Playlist>()
        request.filter(matching: \.id, equalTo: MusicItemID(id))
        request.limit = 1
        let response = try await request.response()

        guard let basePlaylist = response.items.first else {
            throw AppError.message("Apple Music did not return that playlist.")
        }

        let playlist = try await basePlaylist.with([.tracks])
        let tracks = mapLibraryTracks(from: playlist.tracks ?? [])

        return PlaylistSnapshot(
            id: playlist.id.rawValue,
            reference: PlaylistReference(
                service: .appleMusic,
                playlistID: playlist.id.rawValue,
                storefront: nil,
                originalURL: playlist.url ?? URL(string: "https://music.apple.com/library/playlist/\(playlist.id.rawValue)")!
            ),
            name: playlist.name,
            summary: playlist.standardDescription?.strippedHTML.nilIfBlank
                ?? playlist.shortDescription?.strippedHTML.nilIfBlank
                ?? "",
            artworkURL: normalizedArtworkURL(playlist.artwork?.url(width: 600, height: 600)),
            tracks: tracks,
            ownerName: playlist.curatorName?.nilIfBlank ?? "Apple Music",
            ownerImageURL: nil
        )
    }

    func fetchPlaylist(storefront: String, id: String, originalURL: URL) async throws -> PlaylistSnapshot {
        try await ensureAuthorized()

        let escapedID = id.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? id
        let url = URL(string: "https://api.music.apple.com/v1/catalog/\(storefront)/playlists/\(escapedID)?include=tracks&limit[tracks]=100")!
        let response: ApplePlaylistEnvelope = try await request(url: url)

        guard let playlist = response.data.first else {
            throw AppError.message("Apple Music did not return a playlist for that link.")
        }

        var tracks: [TransferTrack] = []
        var nextPath = playlist.relationships?.tracks?.next

        appendTracks(from: playlist.relationships?.tracks?.data ?? [], into: &tracks)

        while let currentNextPath = nextPath {
            let pageURL = absoluteURL(from: currentNextPath)
            let page: AppleTracksPage = try await request(url: pageURL)
            appendTracks(from: page.data, into: &tracks)
            nextPath = page.next
        }

        let summary = [
            playlist.attributes.playlistDescription?.standard,
            playlist.attributes.editorialNotes?.standard,
            playlist.attributes.editorialNotes?.short
        ]
        .compactMap { $0?.strippedHTML.nilIfBlank }
        .first ?? ""

        return PlaylistSnapshot(
            id: id,
            reference: PlaylistReference(
                service: .appleMusic,
                playlistID: id,
                storefront: storefront,
                originalURL: originalURL
            ),
            name: playlist.attributes.name,
            summary: summary,
            artworkURL: normalizedArtworkURL(playlist.attributes.artwork?.resolvedURL(width: 600, height: 600)),
            tracks: tracks,
            ownerName: nil,
            ownerImageURL: nil
        )
    }

    func resolveTracks(from sourceTracks: [TransferTrack], progress: ProgressHandler? = nil) async throws -> TrackResolution {
        try await ensureAuthorized()

        let storefront = try await resolvedCurrentStorefront()
        var matched: [DestinationTrackReference] = []
        var unmatched: [TransferTrack] = []
        var isrcCache: [String: DestinationTrackReference?] = [:]
        var textCache: [String: DestinationTrackReference?] = [:]

        for (index, track) in sourceTracks.enumerated() {
            if let progress {
                let fraction = sourceTracks.isEmpty ? 1 : Double(index) / Double(sourceTracks.count)
                await progress("Matching track \(index + 1) of \(sourceTracks.count) on Apple Music...", fraction)
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

            let resolved = try await findAppleMusicTrack(for: track, storefront: storefront)

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
            await progress("Matched \(matched.count) of \(sourceTracks.count) tracks on Apple Music.", 1)
        }

        return TrackResolution(matched: matched, unmatched: unmatched)
    }

    func createPlaylist(from snapshot: PlaylistSnapshot, matchedTracks: [DestinationTrackReference]) async throws -> (playlistID: String, playlistURL: URL?, notes: [String]) {
        try await ensureAuthorized()

        let requestBody = AppleCreatePlaylistRequest(
            attributes: .init(
                name: snapshot.name.truncated(to: 100),
                description: snapshot.summary.nilIfBlank
            ),
            relationships: matchedTracks.isEmpty ? nil : .init(
                tracks: .init(
                    data: matchedTracks.map {
                        .init(id: $0.id, type: $0.type)
                    }
                )
            )
        )

        let body = try JSONEncoder().encode(requestBody)
        let url = URL(string: "https://api.music.apple.com/v1/me/library/playlists")!
        let response: AppleCreatedLibraryPlaylistEnvelope = try await request(url: url, method: "POST", body: body)

        guard let playlist = response.data.first else {
            throw AppError.message("Apple Music returned an empty playlist creation response.")
        }

        return (
            playlistID: playlist.id,
            playlistURL: URL(string: "https://music.apple.com/library/playlist/\(playlist.id)"),
            notes: [
                "Apple Music created a library playlist in your account.",
                "Apple does not expose custom playlist artwork upload or public-profile publishing through MusicKit."
            ]
        )
    }

    private func findAppleMusicTrack(for track: TransferTrack, storefront: String) async throws -> DestinationTrackReference? {
        if let isrc = track.isrc?.uppercased(), !isrc.isEmpty {
            let byISRC = try await lookupSongsByISRC(isrc, storefront: storefront)
            if let exact = byISRC.first {
                return DestinationTrackReference(id: exact.id, type: exact.type, uri: nil)
            }
        }

        let candidates = try await searchSongs(for: track, storefront: storefront)
        guard let best = candidates.max(by: { lhs, rhs in
            TrackMatcher.score(source: track, candidateTitle: lhs.attributes?.name ?? "", candidateArtist: lhs.attributes?.artistName ?? "", candidateAlbum: lhs.attributes?.albumName, candidateISRC: lhs.attributes?.isrc) <
            TrackMatcher.score(source: track, candidateTitle: rhs.attributes?.name ?? "", candidateArtist: rhs.attributes?.artistName ?? "", candidateAlbum: rhs.attributes?.albumName, candidateISRC: rhs.attributes?.isrc)
        }) else {
            return nil
        }

        let score = TrackMatcher.score(
            source: track,
            candidateTitle: best.attributes?.name ?? "",
            candidateArtist: best.attributes?.artistName ?? "",
            candidateAlbum: best.attributes?.albumName,
            candidateISRC: best.attributes?.isrc
        )

        guard TrackMatcher.isGoodEnough(score) else {
            return nil
        }

        return DestinationTrackReference(id: best.id, type: best.type, uri: nil)
    }

    private func lookupSongsByISRC(_ isrc: String, storefront: String) async throws -> [AppleSongResource] {
        var components = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(storefront)/songs")!
        components.queryItems = [
            URLQueryItem(name: "filter[isrc]", value: isrc)
        ]

        let response: AppleSongsEnvelope = try await request(url: components.url!)
        return response.data
    }

    private func searchSongs(for track: TransferTrack, storefront: String) async throws -> [AppleSongResource] {
        var components = URLComponents(string: "https://api.music.apple.com/v1/catalog/\(storefront)/search")!
        components.queryItems = [
            URLQueryItem(name: "types", value: "songs"),
            URLQueryItem(name: "limit", value: "10"),
            URLQueryItem(name: "term", value: "\(track.title) \(track.artistName)")
        ]

        let response: AppleSearchEnvelope = try await request(url: components.url!)
        return response.results?.songs?.data ?? []
    }

    private func appendTracks(from resources: [AppleSongResource], into tracks: inout [TransferTrack]) {
        for resource in resources {
            guard let attributes = resource.attributes else { continue }

            tracks.append(
                TransferTrack(
                    id: resource.id,
                    title: attributes.name,
                    artistName: attributes.artistName,
                    albumTitle: attributes.albumName,
                    isrc: attributes.isrc,
                    originalPosition: tracks.count + 1
                )
            )
        }
    }

    private func mapLibraryTracks(from items: MusicItemCollection<Track>) -> [TransferTrack] {
        items.enumerated().compactMap { index, track in
            TransferTrack(
                id: track.id.rawValue,
                title: track.title,
                artistName: track.artistName,
                albumTitle: track.albumTitle,
                isrc: track.isrc,
                originalPosition: index + 1
            )
        }
    }

    private func ensureAuthorized() async throws {
        let status = await MusicAuthorization.request()
        guard status == .authorized else {
            throw AppError.message("Apple Music access is required to read or create playlists.")
        }
    }

    private func resolvedCurrentStorefront() async throws -> String {
        let rawValue: Any
        do {
            rawValue = try await MusicDataRequest.currentCountryCode as Any
        } catch {
            throw explainMusicKitFailure(error)
        }

        if let storefront = unwrappedOptional(rawValue) as? String, storefront.isEmpty == false {
            return storefront
        }

        throw AppError.message("Apple Music did not provide a storefront country code for this account.")
    }

    private func unwrappedOptional(_ value: Any) -> Any? {
        let mirror = Mirror(reflecting: value)
        guard mirror.displayStyle == .optional else {
            return value
        }

        return mirror.children.first?.value
    }

    private func absoluteURL(from path: String) -> URL {
        if let url = URL(string: path), url.scheme != nil {
            return url
        }

        return URL(string: path, relativeTo: URL(string: "https://api.music.apple.com"))!
    }

    private func normalizedArtworkURL(_ url: URL?) -> URL? {
        guard let url, let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme) else {
            return nil
        }

        return url
    }

    private func request<Response: Decodable>(url: URL, method: String = "GET", body: Data? = nil) async throws -> Response {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body

        if body != nil {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }

        let dataResponse: MusicDataResponse
        do {
            dataResponse = try await MusicDataRequest(urlRequest: request).response()
        } catch {
            throw explainMusicKitFailure(error)
        }

        if let decoded = try? JSONDecoder().decode(Response.self, from: dataResponse.data) {
            return decoded
        }

        if let errorResponse = try? JSONDecoder().decode(AppleErrorEnvelope.self, from: dataResponse.data),
           let error = errorResponse.errors.first {
            throw AppError.message(error.detail ?? error.title ?? "Apple Music returned an error.")
        }

        throw AppError.message("Apple Music returned an unexpected response.")
    }

    private func explainMusicKitFailure(_ error: Error) -> Error {
        let nsError = error as NSError
        let descriptions = [
            error.localizedDescription,
            nsError.localizedDescription,
            nsError.userInfo[NSDebugDescriptionErrorKey] as? String,
            nsError.userInfo["AMSDescription"] as? String
        ]
            .compactMap { $0?.lowercased() }

        if descriptions.contains(where: {
            $0.contains("client identifier")
                || $0.contains("client not found")
                || $0.contains("status code: not found")
                || $0.contains("failed to request developer token")
                || $0.contains("developer token")
        }) {
            return AppError.message(
                "Apple Music catalog access is not configured for this build. Enable the MusicKit App Service for this app's exact bundle identifier in Apple Developer, then try again."
            )
        }

        if descriptions.contains(where: { $0.contains("permission") || $0.contains("authorized") }) {
            return AppError.message("Apple Music access is required to read or create playlists.")
        }

        return error
    }
}

private struct ApplePlaylistEnvelope: Decodable {
    let data: [ApplePlaylistResource]
}

private struct AppleLibraryPlaylistsEnvelope: Decodable {
    let data: [AppleLibraryPlaylistResource]
    let next: String?
}

private struct AppleLibraryPlaylistDetailsEnvelope: Decodable {
    let data: [AppleLibraryPlaylistResource]
}

private struct ApplePlaylistResource: Decodable {
    let id: String
    let attributes: ApplePlaylistAttributes
    let relationships: ApplePlaylistRelationships?
}

private struct AppleLibraryPlaylistResource: Decodable {
    let id: String
    let attributes: ApplePlaylistAttributes
    let relationships: ApplePlaylistRelationships?
}

private struct ApplePlaylistAttributes: Decodable {
    let name: String
    let artwork: AppleArtwork?
    let playlistDescription: AppleTextBlock?
    let editorialNotes: AppleTextBlock?

    enum CodingKeys: String, CodingKey {
        case name
        case artwork
        case playlistDescription = "description"
        case editorialNotes
    }
}

private struct ApplePlaylistRelationships: Decodable {
    let tracks: AppleTracksRelationship?
}

private struct AppleTracksRelationship: Decodable {
    let data: [AppleSongResource]
    let next: String?
}

private struct AppleTracksPage: Decodable {
    let data: [AppleSongResource]
    let next: String?
}

private struct AppleSongsEnvelope: Decodable {
    let data: [AppleSongResource]
}

private struct AppleSongResource: Decodable {
    let id: String
    let type: String
    let attributes: AppleSongAttributes?
}

private struct AppleSongAttributes: Decodable {
    let name: String
    let artistName: String
    let albumName: String?
    let isrc: String?
}

private struct AppleSearchEnvelope: Decodable {
    let results: AppleSearchResults?
}

private struct AppleSearchResults: Decodable {
    let songs: AppleSongsCollection?
}

private struct AppleSongsCollection: Decodable {
    let data: [AppleSongResource]
}

private struct AppleArtwork: Decodable {
    let url: String

    func resolvedURL(width: Int, height: Int) -> URL? {
        let resolved = url
            .replacingOccurrences(of: "{w}", with: "\(width)")
            .replacingOccurrences(of: "{h}", with: "\(height)")

        return URL(string: resolved)
    }
}

private struct AppleTextBlock: Decodable {
    let standard: String?
    let short: String?
}

private struct AppleCreatePlaylistRequest: Encodable {
    let attributes: Attributes
    let relationships: Relationships?

    struct Attributes: Encodable {
        let name: String
        let description: String?
    }

    struct Relationships: Encodable {
        let tracks: TrackRelationship
    }

    struct TrackRelationship: Encodable {
        let data: [TrackReference]
    }

    struct TrackReference: Encodable {
        let id: String
        let type: String
    }
}

private struct AppleCreatedLibraryPlaylistEnvelope: Decodable {
    let data: [AppleLibraryPlaylist]
}

private struct AppleLibraryPlaylist: Decodable {
    let id: String
}

private struct AppleErrorEnvelope: Decodable {
    let errors: [AppleServiceError]
}

private struct AppleServiceError: Decodable {
    let title: String?
    let detail: String?
}
