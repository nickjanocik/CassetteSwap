import Foundation
import UIKit

@MainActor
final class PlaylistTransferViewModel: ObservableObject {
    @Published private(set) var signedInAccount: MusicAccount?
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published private(set) var snapshot: PlaylistSnapshot?
    @Published private(set) var pendingCassette: CassettePayload?
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Sign in to browse your playlists."
    @Published private(set) var progressValue: Double?
    @Published private(set) var activityLog: [String] = []
    @Published private(set) var transferResult: TransferResult?
    @Published private(set) var shareURL: URL?
    @Published private(set) var shareText: String?
    @Published private(set) var shareSheetRequest: ShareSheetRequest?

    private let appleMusicService = AppleMusicService()
    private let cassetteShareService = CassetteShareService()
    private let spotifyService = SpotifyService()

    init() {}

    var needsSignIn: Bool {
        signedInAccount == nil
    }

    var canTransform: Bool {
        snapshot != nil && !isWorking
    }

    var canAcceptIncomingCassette: Bool {
        pendingCassette != nil && signedInAccount != nil && !isWorking
    }

    func signIn(to service: MusicService) {
        Task {
            await performSignIn(to: service)
        }
    }

    func returnToHome() {
        guard !isWorking else { return }

        signedInAccount = nil
        playlists = []
        snapshot = nil
        transferResult = nil
        shareURL = nil
        shareText = nil
        shareSheetRequest = nil
        progressValue = nil
        activityLog.removeAll()
        statusMessage = pendingCassette == nil
            ? "Sign in to browse your playlists."
            : "Choose Spotify or Apple Music to recreate this cassette."
    }

    func refreshOwnedPlaylists() {
        Task {
            await loadOwnedPlaylists()
        }
    }

    func selectPlaylist(_ playlist: UserPlaylist) {
        Task {
            await loadPlaylistDetails(for: playlist)
        }
    }

    func backToLibrary() {
        snapshot = nil
        transferResult = nil
        shareURL = nil
        shareText = nil
        shareSheetRequest = nil
        progressValue = nil
        activityLog.removeAll()
        statusMessage = pendingCassette == nil ? "Choose one of your playlists." : "Incoming cassette ready to accept."
    }

    func transformCurrentPlaylist() {
        guard let snapshot else { return }

        Task {
            await createShareLink(for: snapshot)
        }
    }

    func handleIncomingURL(_ url: URL) {
        if let payload = CassetteDeepLinkParser.parse(url) {
            prepareForIncomingCassette(clearLog: true)
            presentIncomingCassette(payload)
            return
        }

        guard let reference = CassetteRemoteLinkParser.parse(url, fallbackBaseURL: CassetteShareConfiguration.activeBaseURL) else {
            return
        }

        Task {
            await loadIncomingCassette(reference)
        }
    }

    func acceptIncomingCassette(to destinationService: MusicService) {
        guard let payload = pendingCassette, !isWorking else { return }

        if signedInAccount?.service == destinationService {
            Task {
                await createPlaylistFromIncomingCassette(payload, destinationService: destinationService)
            }
            return
        }

        Task {
            await performSignIn(to: destinationService, autoAcceptPendingCassette: true)
        }
    }

    func declineIncomingCassette() {
        guard !isWorking else { return }

        prepareForIncomingCassette(clearLog: true)
        statusMessage = signedInAccount == nil
            ? "Sign in to browse your playlists."
            : "Choose one of your playlists."
    }

    private func performSignIn(to service: MusicService, autoAcceptPendingCassette: Bool = false) async {
        guard !isWorking else { return }

        isWorking = true
        statusMessage = "Signing in to \(service.displayName)..."
        activityLog.removeAll()

        do {
            switch service {
            case .spotify:
                signedInAccount = try await spotifyService.signIn()
            case .appleMusic:
                signedInAccount = try await appleMusicService.signIn()
            }

            appendLog("Signed in to \(signedInAccount?.service.displayName ?? service.displayName).")

            isWorking = false

            if autoAcceptPendingCassette, let pendingCassette {
                await createPlaylistFromIncomingCassette(pendingCassette, destinationService: service)
            } else {
                await loadOwnedPlaylists()
            }
        } catch {
            isWorking = false
            statusMessage = error.localizedDescription
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    private func loadOwnedPlaylists(allowWhileWorking: Bool = false) async {
        guard let account = signedInAccount else { return }
        guard allowWhileWorking || !isWorking else { return }

        isWorking = true
        playlists = []
        snapshot = nil
        transferResult = nil
        shareURL = nil
        shareText = nil
        progressValue = nil
        statusMessage = "Loading your \(account.service.displayName) playlists..."
        appendLog("Fetching owned public playlists.")
        defer { isWorking = false }

        do {
            switch account.service {
            case .spotify:
                playlists = try await spotifyService.fetchOwnedPlaylists()
            case .appleMusic:
                playlists = try await appleMusicService.fetchOwnedPlaylists()
            }

            if playlists.isEmpty {
                statusMessage = account.service == .spotify
                    ? "No owned public Spotify playlists were found."
                    : "No Apple Music library playlists were found."
            } else {
                statusMessage = "Choose one of your playlists."
            }
            appendLog("Loaded \(playlists.count) playlists.")
        } catch {
            statusMessage = error.localizedDescription
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    private func loadPlaylistDetails(for playlist: UserPlaylist) async {
        guard let account = signedInAccount, !isWorking else { return }

        isWorking = true
        snapshot = nil
        transferResult = nil
        shareURL = nil
        shareText = nil
        progressValue = nil
        activityLog.removeAll()
        statusMessage = "Loading \(playlist.name)..."
        appendLog("Fetching playlist details.")
        defer { isWorking = false }

        do {
            let loadedSnapshot: PlaylistSnapshot
            switch account.service {
            case .spotify:
                loadedSnapshot = try await spotifyService.fetchOwnedPlaylist(id: playlist.id)
            case .appleMusic:
                loadedSnapshot = try await appleMusicService.fetchOwnedPlaylist(id: playlist.id)
            }

            snapshot = loadedSnapshot
            statusMessage = "Loaded \(loadedSnapshot.name) with \(loadedSnapshot.tracks.count) tracks."
            appendLog("Ready to transform this playlist into a cassette link.")
        } catch {
            statusMessage = error.localizedDescription
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    private func createPlaylistFromIncomingCassette(_ payload: CassettePayload, destinationService: MusicService) async {
        guard !isWorking else { return }
        await performTransfer(snapshot: payload.toSnapshot(), destinationService: destinationService)
    }

    private func performTransfer(snapshot: PlaylistSnapshot, destinationService: MusicService) async {
        guard !isWorking else { return }

        isWorking = true
        transferResult = nil
        shareURL = nil
        shareText = nil
        shareSheetRequest = nil
        progressValue = 0
        activityLog.removeAll()
        statusMessage = "Creating playlist in \(destinationService.displayName)..."
        appendLog("Preparing \(destinationService.displayName) transfer.")
        defer { isWorking = false }

        do {
            switch destinationService {
            case .spotify:
                let resolution = try await spotifyService.resolveTracks(from: snapshot.tracks, progress: makeProgressHandler())
                guard !resolution.matched.isEmpty else {
                    throw AppError.message("No tracks could be matched on Spotify.")
                }

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

                let created = try await appleMusicService.createPlaylist(from: snapshot, matchedTracks: resolution.matched)

                transferResult = TransferResult(
                    destinationService: .appleMusic,
                    playlistID: created.playlistID,
                    playlistURL: created.playlistURL,
                    matchedCount: resolution.matched.count,
                    unmatched: resolution.unmatched,
                    artworkCopied: false,
                    notes: created.notes
                )
            }

            pendingCassette = nil
            progressValue = 1
            statusMessage = "Playlist created in \(destinationService.displayName)."
            appendLog(statusMessage)

            if let playlistURL = transferResult?.playlistURL {
                await UIApplication.shared.open(playlistURL)
            }
        } catch {
            progressValue = nil
            statusMessage = error.localizedDescription
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    private func makeProgressHandler() -> ProgressHandler {
        { [weak self] message, fractionComplete in
            guard let self else { return }
            self.updateProgress(message: message, fractionComplete: fractionComplete)
        }
    }

    private func appendLog(_ line: String) {
        activityLog.append(line)
    }

    private func updateProgress(message: String, fractionComplete: Double?) {
        statusMessage = message
        progressValue = fractionComplete
    }

    func clearShareSheetRequest() {
        shareSheetRequest = nil
    }

    private func createShareLink(for snapshot: PlaylistSnapshot) async {
        guard !isWorking else { return }

        isWorking = true
        shareURL = nil
        shareText = nil
        shareSheetRequest = nil
        transferResult = nil
        progressValue = nil
        statusMessage = "Preparing cassette link..."
        defer { isWorking = false }

        do {
            let payload = CassettePayload(from: snapshot)
            let shareURL: URL

            appendLog("Uploading cassette for public sharing.")
            let remoteShare = try await cassetteShareService.createShare(
                for: payload,
                baseURL: CassetteShareConfiguration.activeBaseURL
            )
            shareURL = remoteShare.shareURL
            statusMessage = "Public cassette link copied. Choose where to share it."
            appendLog("Generated public cassette \(remoteShare.id).")

            let shareString = shareURL.absoluteString
            UIPasteboard.general.string = shareString
            self.shareURL = shareURL
            shareText = shareString
            shareSheetRequest = ShareSheetRequest(items: [shareString])
        } catch {
            statusMessage = error.localizedDescription
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    private func loadIncomingCassette(_ reference: RemoteCassetteReference) async {
        guard !isWorking else { return }

        isWorking = true
        prepareForIncomingCassette(clearLog: true)
        statusMessage = "Loading shared cassette..."
        appendLog("Fetching cassette \(reference.id).")
        defer { isWorking = false }

        do {
            let payload = try await cassetteShareService.fetchCassette(id: reference.id, baseURL: reference.baseURL)
            presentIncomingCassette(payload)
        } catch {
            statusMessage = error.localizedDescription
            appendLog("Error: \(error.localizedDescription)")
        }
    }

    private func prepareForIncomingCassette(clearLog: Bool) {
        shareURL = nil
        shareText = nil
        shareSheetRequest = nil
        transferResult = nil
        pendingCassette = nil
        snapshot = nil
        progressValue = nil

        if clearLog {
            activityLog.removeAll()
        }
    }

    private func presentIncomingCassette(_ payload: CassettePayload) {
        pendingCassette = payload
        statusMessage = "Choose Spotify or Apple Music to recreate this cassette."
        appendLog("Received cassette \(payload.name).")
    }
}
