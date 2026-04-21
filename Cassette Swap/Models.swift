import Foundation

enum MusicService: String, Codable {
    case spotify
    case appleMusic

    var displayName: String {
        switch self {
        case .spotify:
            return "Spotify"
        case .appleMusic:
            return "Apple Music"
        }
    }

    var otherService: MusicService {
        switch self {
        case .spotify:
            return .appleMusic
        case .appleMusic:
            return .spotify
        }
    }
}

struct ShareSheetRequest: Identifiable {
    let id = UUID()
    let items: [Any]
}

struct RemoteCassetteReference: Hashable {
    let id: String
    let baseURL: URL
}

struct MusicAccount: Equatable {
    let service: MusicService
    let userID: String?
    let displayName: String
}

struct UserPlaylist: Identifiable, Hashable {
    let id: String
    let service: MusicService
    let name: String
    let summary: String
    let artworkURL: URL?
    let ownerName: String?
}

struct PlaylistReference: Hashable {
    let service: MusicService
    let playlistID: String
    let storefront: String?
    let originalURL: URL
}

struct TransferTrack: Identifiable, Hashable {
    let id: String
    let title: String
    let artistName: String
    let albumTitle: String?
    let isrc: String?
    let originalPosition: Int
}

struct PlaylistSnapshot: Identifiable {
    let id: String
    let reference: PlaylistReference
    let name: String
    let summary: String
    let artworkURL: URL?
    let tracks: [TransferTrack]
    let ownerName: String?

    var sourceService: MusicService {
        reference.service
    }
}

struct DestinationTrackReference: Hashable {
    let id: String
    let type: String
    let uri: String?
}

struct TrackResolution {
    let matched: [DestinationTrackReference]
    let unmatched: [TransferTrack]
}

struct TransferResult {
    let destinationService: MusicService
    let playlistID: String
    let playlistURL: URL?
    let matchedCount: Int
    let unmatched: [TransferTrack]
    let artworkCopied: Bool
    let notes: [String]
}

// MARK: - Shareable Cassette

struct CassettePayload: Codable {
    let name: String
    let summary: String
    let artworkURLString: String?
    let sourceService: MusicService
    let senderName: String?
    let tracks: [CassetteTrack]

    struct CassetteTrack: Codable {
        let title: String
        let artistName: String
        let albumTitle: String?
        let isrc: String?
    }

    init(from snapshot: PlaylistSnapshot) {
        self.name = snapshot.name
        self.summary = snapshot.summary
        self.artworkURLString = snapshot.artworkURL?.absoluteString
        self.sourceService = snapshot.sourceService
        self.senderName = snapshot.ownerName
        self.tracks = snapshot.tracks.map {
            CassetteTrack(title: $0.title, artistName: $0.artistName, albumTitle: $0.albumTitle, isrc: $0.isrc)
        }
    }

    func toSnapshot() -> PlaylistSnapshot {
        let transferTracks = tracks.enumerated().map { index, t in
            TransferTrack(
                id: t.isrc ?? "\(index)",
                title: t.title,
                artistName: t.artistName,
                albumTitle: t.albumTitle,
                isrc: t.isrc,
                originalPosition: index + 1
            )
        }

        return PlaylistSnapshot(
            id: "shared-\(name)",
            reference: PlaylistReference(
                service: sourceService,
                playlistID: "shared",
                storefront: nil,
                originalURL: URL(string: "https://cassetteswap.app")!
            ),
            name: name,
            summary: summary,
            artworkURL: artworkURLString.flatMap { URL(string: $0) },
            tracks: transferTracks,
            ownerName: senderName
        )
    }

    func encoded() throws -> String {
        let data = try JSONEncoder().encode(self)
        return data.base64EncodedString()
    }

    static func decode(from base64String: String) throws -> CassettePayload {
        guard let data = Data(base64Encoded: base64String) else {
            throw AppError.message("Invalid cassette data.")
        }
        return try JSONDecoder().decode(CassettePayload.self, from: data)
    }
}

typealias ProgressHandler = (_ message: String, _ fractionComplete: Double?) async -> Void

enum AppError: LocalizedError {
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message):
            return message
        }
    }
}
