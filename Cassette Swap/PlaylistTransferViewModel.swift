import Foundation
import UIKit

@MainActor
final class PlaylistTransferViewModel: ObservableObject {
    @Published private(set) var signedInAccount: MusicAccount?
    @Published private(set) var knownAccounts: [MusicService: MusicAccount]
    @Published var senderProfileName: String {
        didSet { persistSenderProfile() }
    }
    @Published private(set) var senderProfileImageData: Data? {
        didSet { persistSenderProfile() }
    }
    @Published private(set) var playlists: [UserPlaylist] = []
    @Published private(set) var snapshot: PlaylistSnapshot?
    @Published private(set) var pendingCassette: CassettePayload?
    @Published private(set) var isWorking = false
    @Published private(set) var statusMessage = "Sign in to browse your playlists."
    @Published private(set) var progressValue: Double?
    @Published private(set) var activityLog: [String] = []
    @Published private(set) var transferResult: TransferResult?
    @Published private(set) var isPreparingShareLink = false
    @Published private(set) var shareURL: URL?
    @Published private(set) var shareText: String?
    @Published private(set) var shareSheetRequest: ShareSheetRequest?
    @Published private(set) var sentCassetteHistory: [SentCassetteRecord]
    @Published private(set) var mostRecentlySentCassetteID: SentCassetteRecord.ID?
    @Published private(set) var needsAppleMusicSenderProfileSetup = false

    private let appleMusicService = AppleMusicService()
    private let sessionStore = MusicAccountSessionStore()
    private let senderProfileStore = SenderProfileStore()
    private let sentCassetteStore = SentCassetteStore()
    private let cassetteShareService = CassetteShareService()
    private let spotifyService = SpotifyService()
    private var pendingSentCassetteRecord: SentCassetteRecord?

    init() {
        let restoredSession = sessionStore.load()
        let restoredSenderProfile = senderProfileStore.load()
        let restoredSentCassetteHistory = sentCassetteStore.load()
        self.knownAccounts = restoredSession.knownAccounts
        self.signedInAccount = restoredSession.activeService.flatMap { restoredSession.knownAccounts[$0] }
        self.senderProfileName = restoredSenderProfile.displayName ?? ""
        self.senderProfileImageData = restoredSenderProfile.imageData
        self.sentCassetteHistory = restoredSentCassetteHistory

        if signedInAccount == nil {
            self.statusMessage = "Sign in to browse your playlists."
        } else {
            self.statusMessage = "Choose a service to continue."
        }
    }

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

    func continueWith(_ service: MusicService) {
        if signedInAccount?.service == service {
            Task {
                await loadOwnedPlaylists()
            }
        } else {
            signIn(to: service)
        }
    }

    func buttonTitle(for service: MusicService) -> String {
        guard knownAccounts[service] != nil else {
            return "Continue with \(service.displayName)"
        }

        guard let resolvedName = resolvedAccountDisplayName(for: service) else {
            return "Signed in to \(service.displayName)"
        }

        return "\(resolvedName) on \(service.displayName)"
    }

    func buttonSubtitle(for service: MusicService) -> String {
        if signedInAccount?.service == service {
            return "Already signed in. Browse your playlists."
        }

        if knownAccounts[service] != nil {
            return "Reconnect this account and browse your playlists."
        }

        switch service {
        case .spotify:
            return "Browse the public playlists you own."
        case .appleMusic:
            return "Browse your library playlists with MusicKit."
        }
    }

    func returnToHome() {
        guard !isWorking else { return }

        snapshot = nil
        transferResult = nil
        shareURL = nil
        shareText = nil
        shareSheetRequest = nil
        progressValue = nil
        activityLog.removeAll()
        statusMessage = pendingCassette == nil
            ? (signedInAccount == nil ? "Sign in to browse your playlists." : "Choose a service to continue.")
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
        guard let snapshot, !isWorking else { return }

        isPreparingShareLink = true

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
            : "Choose a service to continue."
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

            if let signedInAccount {
                knownAccounts[signedInAccount.service] = signedInAccount
                persistSession()
            }

            appendLog("Signed in to \(signedInAccount?.service.displayName ?? service.displayName).")

            isWorking = false

            if autoAcceptPendingCassette, let pendingCassette {
                needsAppleMusicSenderProfileSetup = false
                await createPlaylistFromIncomingCassette(pendingCassette, destinationService: service)
            } else if service == .appleMusic {
                needsAppleMusicSenderProfileSetup = true
                statusMessage = "Add the name and photo you want to send with Apple Music cassettes."
            } else {
                needsAppleMusicSenderProfileSetup = false
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

            refreshSignedInAccountMetadata(using: playlists)

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

            let resolvedSnapshot = snapshotWithSignedInOwner(from: loadedSnapshot, account: account)
            snapshot = resolvedSnapshot
            statusMessage = "Loaded \(resolvedSnapshot.name) with \(resolvedSnapshot.tracks.count) tracks."
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

    func handleShareSheetCompletion(completed: Bool) {
        shareSheetRequest = nil

        guard completed, let record = pendingSentCassetteRecord else {
            pendingSentCassetteRecord = nil
            return
        }

        sentCassetteHistory.insert(record, at: 0)
        mostRecentlySentCassetteID = record.id
        pendingSentCassetteRecord = nil
        persistSentCassetteHistory()
    }

    func clearMostRecentlySentCassetteHighlight() {
        mostRecentlySentCassetteID = nil
    }

    func completeAppleMusicSenderProfileSetup() {
        guard needsAppleMusicSenderProfileSetup else {
            return
        }

        needsAppleMusicSenderProfileSetup = false

        Task {
            await loadOwnedPlaylists()
        }
    }

    func editAppleMusicSenderProfile() {
        guard signedInAccount?.service == .appleMusic else {
            return
        }

        needsAppleMusicSenderProfileSetup = true
        statusMessage = "Update the name and photo you want to send with Apple Music cassettes."
    }

    var senderProfileImage: UIImage? {
        senderProfileImageData.flatMap(UIImage.init(data:))
    }

    func setSenderProfileImageData(_ data: Data?) {
        senderProfileImageData = data
    }

    func clearSenderProfileImage() {
        senderProfileImageData = nil
    }

    func displayName(for service: MusicService) -> String {
        resolvedAccountDisplayName(for: service) ?? service.displayName
    }

    private func createShareLink(for snapshot: PlaylistSnapshot) async {
        guard !isWorking else { return }

        isWorking = true
        isPreparingShareLink = true
        shareURL = nil
        shareText = nil
        shareSheetRequest = nil
        transferResult = nil
        progressValue = nil
        statusMessage = "Preparing cassette link..."
        defer {
            isWorking = false
            isPreparingShareLink = false
        }

        do {
            let payload = buildCassettePayload(from: snapshot)
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
            pendingSentCassetteRecord = SentCassetteRecord(
                id: UUID(),
                name: snapshot.name,
                summary: snapshot.summary,
                artworkURL: snapshot.artworkURL,
                sourceService: snapshot.sourceService,
                shareURL: shareURL,
                trackCount: snapshot.tracks.count,
                sentAt: Date()
            )
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

    private func refreshSignedInAccountMetadata(using playlists: [UserPlaylist]) {
        guard let account = signedInAccount else {
            return
        }

        let fallbackName = playlists
            .compactMap(\.ownerName)
            .compactMap(\.nilIfBlank)
            .first(where: { displayNameIsMeaningful($0, for: account.service) })

        let resolvedDisplayName = fallbackName ?? account.displayName
        guard resolvedDisplayName != account.displayName else {
            return
        }

        let updatedAccount = MusicAccount(
            service: account.service,
            userID: account.userID,
            displayName: resolvedDisplayName,
            profileImageURL: account.profileImageURL
        )

        signedInAccount = updatedAccount
        knownAccounts[updatedAccount.service] = updatedAccount
        persistSession()
    }

    private func snapshotWithSignedInOwner(from snapshot: PlaylistSnapshot, account: MusicAccount) -> PlaylistSnapshot {
        let resolvedOwnerName = resolvedAccountDisplayName(for: account.service) ?? snapshot.ownerName

        let resolvedOwnerImageURL = account.profileImageURL ?? snapshot.ownerImageURL

        return PlaylistSnapshot(
            id: snapshot.id,
            reference: snapshot.reference,
            name: snapshot.name,
            summary: snapshot.summary,
            artworkURL: snapshot.artworkURL,
            tracks: snapshot.tracks,
            ownerName: resolvedOwnerName,
            ownerImageURL: resolvedOwnerImageURL
        )
    }

    private func displayNameIsMeaningful(_ displayName: String, for service: MusicService) -> Bool {
        let trimmed = displayName.trimmed
        return trimmed.isEmpty == false && trimmed.caseInsensitiveCompare(service.displayName) != .orderedSame
    }

    private func resolvedAccountDisplayName(for service: MusicService) -> String? {
        if let account = knownAccounts[service],
           displayNameIsMeaningful(account.displayName, for: service) {
            return account.displayName
        }

        guard knownAccounts[service] != nil else {
            return nil
        }

        return senderProfileName.nilIfBlank
    }

    private func resolvedAccountProfileImageURL(for service: MusicService) -> URL? {
        knownAccounts[service]?.profileImageURL
    }

    private func resolvedAccountProfileImageData(for service: MusicService) -> Data? {
        guard knownAccounts[service] != nil else {
            return nil
        }

        guard resolvedAccountProfileImageURL(for: service) == nil else {
            return nil
        }

        return senderProfileImageData
    }

    private func buildCassettePayload(from snapshot: PlaylistSnapshot) -> CassettePayload {
        let service = snapshot.sourceService

        return CassettePayload(
            from: snapshot,
            senderNameOverride: resolvedAccountDisplayName(for: service) ?? snapshot.ownerName,
            senderImageURLOverride: resolvedAccountProfileImageURL(for: service) ?? snapshot.ownerImageURL,
            senderImageDataOverride: resolvedAccountProfileImageData(for: service)
        )
    }

    private func persistSession() {
        sessionStore.save(
            knownAccounts: knownAccounts,
            activeService: signedInAccount?.service
        )
    }

    private func persistSenderProfile() {
        senderProfileStore.save(
            displayName: senderProfileName.nilIfBlank,
            imageData: senderProfileImageData
        )
    }

    private func persistSentCassetteHistory() {
        sentCassetteStore.save(sentCassetteHistory)
    }
}

private struct StoredMusicAccountSession: Codable {
    let knownAccounts: [MusicAccount]
    let activeService: MusicService?
}

private final class MusicAccountSessionStore {
    private let defaultsKey = "cassette_swap.music_account_session"

    func load() -> (knownAccounts: [MusicService: MusicAccount], activeService: MusicService?) {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(StoredMusicAccountSession.self, from: data) else {
            return ([:], nil)
        }

        let accounts = Dictionary(uniqueKeysWithValues: stored.knownAccounts.map { ($0.service, $0) })
        return (accounts, stored.activeService)
    }

    func save(knownAccounts: [MusicService: MusicAccount], activeService: MusicService?) {
        let stored = StoredMusicAccountSession(
            knownAccounts: Array(knownAccounts.values),
            activeService: activeService
        )

        guard let data = try? JSONEncoder().encode(stored) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

private struct StoredSenderProfile: Codable {
    let displayName: String?
    let imageDataBase64: String?
}

private final class SenderProfileStore {
    private let defaultsKey = "cassette_swap.sender_profile"

    func load() -> (displayName: String?, imageData: Data?) {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode(StoredSenderProfile.self, from: data) else {
            return (nil, nil)
        }

        return (
            displayName: stored.displayName,
            imageData: stored.imageDataBase64.flatMap { Data(base64Encoded: $0) }
        )
    }

    func save(displayName: String?, imageData: Data?) {
        let stored = StoredSenderProfile(
            displayName: displayName,
            imageDataBase64: imageData?.base64EncodedString()
        )

        guard let data = try? JSONEncoder().encode(stored) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

private final class SentCassetteStore {
    private let defaultsKey = "cassette_swap.sent_cassette_history"

    func load() -> [SentCassetteRecord] {
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let stored = try? JSONDecoder().decode([SentCassetteRecord].self, from: data) else {
            return []
        }

        return stored.sorted { $0.sentAt > $1.sentAt }
    }

    func save(_ records: [SentCassetteRecord]) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }

        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}
