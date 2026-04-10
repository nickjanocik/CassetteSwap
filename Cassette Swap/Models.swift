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
    let id = UUID()
    let reference: PlaylistReference
    let name: String
    let summary: String
    let artworkURL: URL?
    let tracks: [TransferTrack]

    var sourceService: MusicService {
        reference.service
    }

    var destinationService: MusicService {
        reference.service.otherService
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
