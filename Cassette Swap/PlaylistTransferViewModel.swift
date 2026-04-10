import Foundation

@MainActor
final class PlaylistTransferViewModel: ObservableObject {
    @Published var playlistURLText = ""
    @Published var spotifyClientID: String {
        didSet {
            UserDefaults.standard.set(spotifyClientID.trimmed, forKey: Self.spotifyClientIDDefaultsKey)
        }
    }

    @Published private(set) var snapshot: PlaylistSnapshot?
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Paste a public playlist URL to begin."
    @Published private(set) var progressValue: Double?
    @Published private(set) var activityLog: [String] = []
    @Published private(set) var transferResult: TransferResult?

    private static let spotifyClientIDDefaultsKey = "cassette_swap.spotify_client_id"

    private let appleMusicService = AppleMusicService()
    private lazy var spotifyService = SpotifyService(clientIDProvider: {
        UserDefaults.standard.string(forKey: Self.spotifyClientIDDefaultsKey) ?? ""
    })

    init() {
        self.spotifyClientID = UserDefaults.standard.string(forKey: Self.spotifyClientIDDefaultsKey) ?? ""
    }

    var canInspect: Bool {
        !playlistURLText.trimmed.isEmpty && !isWorking
    }

    var canTransfer: Bool {
        snapshot != nil && !isWorking
    }

    func inspectPlaylist() {
        Task {
            await performInspection()
        }
    }

    func transferCurrentPlaylist() {
        Task {
            await performTransfer()
        }
    }

    private func performInspection() async {
        guard !isWorking else { return }

        isWorking = true
        snapshot = nil
        transferResult = nil
        progressValue = nil
        activityLog.removeAll()
        statusMessage = "Checking the playlist link..."

        defer {
            isWorking = false
        }

        do {
            let reference = try PlaylistLinkParser.parse(playlistURLText)
            appendLog("Detected \(reference.service.displayName) source.")

            let loadedSnapshot: PlaylistSnapshot
            switch reference.service {
            case .spotify:
                appendLog("Spotify requires sign-in because their API still needs an access token for public playlists.")
                loadedSnapshot = try await spotifyService.fetchPlaylist(id: reference.playlistID, originalURL: reference.originalURL)
            case .appleMusic:
                appendLog("Requesting Apple Music permission through MusicKit.")
                loadedSnapshot = try await appleMusicService.fetchPlaylist(
                    storefront: reference.storefront ?? "us",
                    id: reference.playlistID,
                    originalURL: reference.originalURL
                )
            }

            snapshot = loadedSnapshot
            statusMessage = "Loaded \(loadedSnapshot.name) with \(loadedSnapshot.tracks.count) tracks."
            appendLog("Ready to create the playlist on \(loadedSnapshot.destinationService.displayName).")
        } catch {
            snapshot = nil
            statusMessage = error.localizedDescription
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    private func performTransfer() async {
        guard !isWorking, let snapshot else { return }

        isWorking = true
        transferResult = nil
        progressValue = 0
        activityLog.removeAll()
        statusMessage = "Starting transfer..."
        appendLog("Preparing \(snapshot.destinationService.displayName) transfer.")

        defer {
            isWorking = false
        }

        do {
            switch snapshot.destinationService {
            case .spotify:
                let resolution = try await spotifyService.resolveTracks(from: snapshot.tracks, progress: makeProgressHandler())
                guard !resolution.matched.isEmpty else {
                    throw AppError.message("No tracks could be matched on Spotify.")
                }

                appendLog("Matched \(resolution.matched.count) of \(snapshot.tracks.count) tracks on Spotify.")

                let created = try await spotifyService.createPlaylist(
                    from: snapshot,
                    matchedTracks: resolution.matched,
                    copyArtwork: snapshot.artworkURL != nil
                )

                var notes: [String] = []
                if snapshot.artworkURL != nil && !created.artworkCopied {
                    notes.append("Spotify playlist created, but artwork upload was not completed.")
                }

                transferResult = TransferResult(
                    destinationService: .spotify,
                    playlistID: created.playlistID,
                    playlistURL: created.playlistURL,
                    matchedCount: resolution.matched.count,
                    unmatched: resolution.unmatched,
                    artworkCopied: created.artworkCopied,
                    notes: notes
                )
            case .appleMusic:
                let resolution = try await appleMusicService.resolveTracks(from: snapshot.tracks, progress: makeProgressHandler())
                guard !resolution.matched.isEmpty else {
                    throw AppError.message("No tracks could be matched on Apple Music.")
                }

                appendLog("Matched \(resolution.matched.count) of \(snapshot.tracks.count) tracks on Apple Music.")

                let created = try await appleMusicService.createPlaylist(from: snapshot, matchedTracks: resolution.matched)

                transferResult = TransferResult(
                    destinationService: .appleMusic,
                    playlistID: created.playlistID,
                    playlistURL: nil,
                    matchedCount: resolution.matched.count,
                    unmatched: resolution.unmatched,
                    artworkCopied: false,
                    notes: created.notes
                )
            }

            progressValue = 1
            statusMessage = "Finished. Matched \(transferResult?.matchedCount ?? 0) of \(snapshot.tracks.count) tracks."
            appendLog(statusMessage)
        } catch {
            progressValue = nil
            statusMessage = error.localizedDescription
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    private func makeProgressHandler() -> ProgressHandler {
        { [weak self] message, fractionComplete in
            guard let self else { return }
            await self.updateProgress(message: message, fractionComplete: fractionComplete)
        }
    }

    private func appendLog(_ line: String) {
        activityLog.append(line)
    }

    private func updateProgress(message: String, fractionComplete: Double?) {
        statusMessage = message
        progressValue = fractionComplete
    }
}
