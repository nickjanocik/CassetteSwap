import PhotosUI
import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = PlaylistTransferViewModel()
    @State private var isShowingHome = true
    @State private var isShowingSentHistory = false
    @State private var selectedSenderPhotoItem: PhotosPickerItem?

    private let hotPink = Color(red: 1.0, green: 0.33, blue: 0.64)
    private let electricBlue = Color(red: 0.35, green: 0.65, blue: 1.0)
    private let darkBg = Color(red: 0.06, green: 0.04, blue: 0.12)
    private let cardBg = Color(red: 0.1, green: 0.08, blue: 0.18)
    private let fadedText = Color(red: 0.6, green: 0.55, blue: 0.7)

    private enum Page {
        case signIn
        case library
        case preview
        case transformLoading
        case incomingDecision
        case sentHistory
        case senderProfileSetup
    }

    private var currentPage: Page {
        if isShowingSentHistory {
            return .sentHistory
        }
        if viewModel.needsAppleMusicSenderProfileSetup {
            return .senderProfileSetup
        }
        if viewModel.pendingCassette != nil {
            return .incomingDecision
        }
        if viewModel.isPreparingShareLink {
            return .transformLoading
        }
        if viewModel.snapshot != nil {
            return .preview
        }
        if isShowingHome || viewModel.needsSignIn {
            return .signIn
        }
        return .library
    }

    var body: some View {
        ZStack {
            darkBg.ignoresSafeArea()

            switch currentPage {
            case .signIn:
                signInPage
            case .library:
                libraryPage
            case .preview:
                previewPage
            case .transformLoading:
                transformLoadingPage
            case .incomingDecision:
                incomingDecisionPage
            case .sentHistory:
                sentHistoryPage
            case .senderProfileSetup:
                senderProfileSetupPage
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentPage)
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            isShowingHome = true
            isShowingSentHistory = false
            viewModel.clearMostRecentlySentCassetteHighlight()
            viewModel.handleIncomingURL(url)
        }
        .onContinueUserActivity(NSUserActivityTypeBrowsingWeb) { userActivity in
            guard let url = userActivity.webpageURL else {
                return
            }

            isShowingHome = true
            isShowingSentHistory = false
            viewModel.clearMostRecentlySentCassetteHighlight()
            viewModel.handleIncomingURL(url)
        }
        .onChange(of: selectedSenderPhotoItem) { _, newItem in
            guard let newItem else {
                return
            }

            Task {
                await loadSenderPhoto(from: newItem)
            }
        }
        .sheet(item: shareSheetBinding) { request in
            ActivityViewController(activityItems: request.items) { completed in
                viewModel.handleShareSheetCompletion(completed: completed)
                if completed {
                    isShowingHome = false
                    isShowingSentHistory = true
                }
            }
        }
    }

    private var signInPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 24)
                appTitle
                Text("Sign in with the streaming account you want to use for sending or accepting cassettes.")
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(fadedText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)

                incomingCassetteCard
                    .padding(.horizontal, 20)

                if viewModel.pendingCassette == nil {
                    signInButton(
                        title: viewModel.buttonTitle(for: .appleMusic),
                        subtitle: viewModel.buttonSubtitle(for: .appleMusic),
                        action: {
                            isShowingHome = false
                            viewModel.continueWith(.appleMusic)
                        }
                    )
                    .padding(.horizontal, 20)

                    signInButton(
                        title: viewModel.buttonTitle(for: .spotify),
                        subtitle: viewModel.buttonSubtitle(for: .spotify),
                        action: {
                            isShowingHome = false
                            viewModel.continueWith(.spotify)
                        }
                    )
                    .padding(.horizontal, 20)
                }

                statusSection
                    .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }
        }
    }

    private var libraryPage: some View {
        ScrollView {
            VStack(spacing: 22) {
                Spacer(minLength: 16)

                headerCard
                    .padding(.horizontal, 20)

                incomingCassetteCard
                    .padding(.horizontal, 20)

                if let result = viewModel.transferResult {
                    resultCard(result)
                        .padding(.horizontal, 20)
                }

                if viewModel.isWorking {
                    ProgressView()
                        .tint(hotPink)
                        .scaleEffect(1.15)
                }

                if viewModel.playlists.isEmpty {
                    emptyPlaylistsCard
                        .padding(.horizontal, 20)
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 130), spacing: 16)], spacing: 16) {
                        ForEach(viewModel.playlists) { playlist in
                            Button {
                                viewModel.selectPlaylist(playlist)
                            } label: {
                                playlistTile(playlist)
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }

                statusSection
                    .padding(.horizontal, 20)

                Spacer(minLength: 30)
            }
        }
    }

    private var previewPage: some View {
        ScrollView {
            VStack(spacing: 20) {
                Color.clear.frame(height: 12)

                if let snapshot = viewModel.snapshot {
                    AsyncImage(url: snapshot.artworkURL) { image in
                        image.resizable().scaledToFill()
                    } placeholder: {
                        ZStack {
                            RoundedRectangle(cornerRadius: 16)
                                .fill(cardBg)
                            Image(systemName: "music.note.list")
                                .font(.system(size: 40))
                                .foregroundStyle(fadedText)
                        }
                    }
                    .frame(width: 180, height: 180)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(
                                LinearGradient(colors: [hotPink, electricBlue], startPoint: .topLeading, endPoint: .bottomTrailing),
                                lineWidth: 2
                            )
                    )

                    Text(snapshot.name)
                        .font(.system(.title2, design: .rounded).bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    sourceBadge(snapshot)

                    Text("\(snapshot.tracks.count) tracks")
                        .font(.system(.caption, design: .rounded))
                        .foregroundStyle(fadedText)

                    if !snapshot.summary.isEmpty {
                        Text(snapshot.summary)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(fadedText)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 30)
                    }

                    trackListCard(snapshot.tracks)
                        .padding(.horizontal, 20)

                    if viewModel.isWorking {
                        VStack(spacing: 10) {
                            ProgressView()
                                .tint(hotPink)

                            Text(viewModel.statusMessage)
                                .font(.system(.caption2, design: .rounded))
                                .foregroundStyle(fadedText)
                                .multilineTextAlignment(.center)

                            if let progress = viewModel.progressValue {
                                progressBar(progress)
                                    .padding(.horizontal, 40)
                            }
                        }
                    }

                    if let result = viewModel.transferResult {
                        resultCard(result)
                            .padding(.horizontal, 20)
                    }

                    if !viewModel.activityLog.isEmpty {
                        logSection
                            .padding(.horizontal, 20)
                    }

                    Color.clear.frame(height: 104)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .safeAreaInset(edge: .bottom) {
            previewBottomBar
        }
    }

    private var incomingDecisionPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 28)
                appTitle

                if let pendingCassette = viewModel.pendingCassette {
                    let senderLabel = pendingCassette.senderName ?? pendingCassette.sourceService.displayName

                    VStack(spacing: 18) {
                        Text("Incoming Cassette")
                            .font(.system(.caption, design: .rounded).bold())
                            .foregroundStyle(hotPink)

                        avatarView(
                            remoteURL: pendingCassette.senderImageURL,
                            imageData: pendingCassette.senderImageData,
                            size: 84,
                            fallbackText: senderLabel
                        )

                        Text("\(senderLabel) sent you a Cassette")
                            .font(.system(.title2, design: .rounded).bold())
                            .foregroundStyle(.white)
                            .multilineTextAlignment(.center)

                        Text(pendingCassette.name)
                            .font(.system(.headline, design: .rounded).bold())
                            .foregroundStyle(fadedText)
                            .multilineTextAlignment(.center)

                        Text("Choose where you want to play it.")
                            .font(.system(.callout, design: .rounded))
                            .foregroundStyle(fadedText)
                            .multilineTextAlignment(.center)

                        signInButton(
                            title: "Play on Spotify",
                            subtitle: "Open this cassette as a new Spotify playlist.",
                            action: {
                                isShowingHome = false
                                isShowingSentHistory = false
                                viewModel.acceptIncomingCassette(to: .spotify)
                            }
                        )

                        signInButton(
                            title: "Play on Apple Music",
                            subtitle: "Open this cassette as a new Apple Music playlist.",
                            action: {
                                isShowingHome = false
                                isShowingSentHistory = false
                                viewModel.acceptIncomingCassette(to: .appleMusic)
                            }
                        )

                        Button {
                            isShowingHome = viewModel.needsSignIn
                            isShowingSentHistory = false
                            viewModel.declineIncomingCassette()
                        } label: {
                            Text("Decline")
                                .font(.system(.callout, design: .rounded).bold())
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 14)
                                .foregroundStyle(.white)
                                .background(
                                    Capsule()
                                        .fill(Color.white.opacity(0.08))
                                )
                        }
                    }
                    .frame(maxWidth: .infinity)
                    .padding(22)
                    .background(cardBackground)
                    .padding(.horizontal, 20)
                }

                statusSection
                    .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }
        }
    }

    private var transformLoadingPage: some View {
        VStack(spacing: 20) {
            Spacer()

            ZStack {
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [hotPink.opacity(0.22), electricBlue.opacity(0.12)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 160, height: 160)
                    .blur(radius: 6)

                ProgressView()
                    .tint(.white)
                    .scaleEffect(1.7)
            }

            VStack(spacing: 8) {
                Text("Transforming")
                    .font(.system(.title2, design: .rounded).bold())
                    .foregroundStyle(.white)

                Text(viewModel.statusMessage)
                    .font(.system(.callout, design: .rounded))
                    .foregroundStyle(fadedText)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 32)
            }

            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var sentHistoryPage: some View {
        ScrollView {
            VStack(spacing: 20) {
                Spacer(minLength: 18)

                VStack(spacing: 12) {
                    Text("Sent!")
                        .font(.system(.largeTitle, design: .rounded).bold())
                        .foregroundStyle(.white)

                    Text("Your cassette is out in the world. Here’s everything you’ve shared so far.")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(fadedText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 24)

                if let mostRecent = viewModel.sentCassetteHistory.first(where: { $0.id == viewModel.mostRecentlySentCassetteID }) {
                    highlightedSentCard(mostRecent)
                        .padding(.horizontal, 20)
                }

                if viewModel.sentCassetteHistory.isEmpty {
                    VStack(spacing: 10) {
                        Text("No sent cassettes yet")
                            .font(.system(.headline, design: .rounded).bold())
                            .foregroundStyle(.white)

                        Text("Transform a playlist to start your shared cassette list.")
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(fadedText)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(20)
                    .background(cardBackground)
                    .padding(.horizontal, 20)
                } else {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Sent Cassettes")
                            .font(.system(.caption, design: .rounded).bold())
                            .foregroundStyle(fadedText)

                        ForEach(viewModel.sentCassetteHistory) { record in
                            sentCassetteRow(record)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
                    .background(cardBackground)
                    .padding(.horizontal, 20)
                }

                Button {
                    isShowingSentHistory = false
                    viewModel.clearMostRecentlySentCassetteHighlight()
                    if viewModel.needsSignIn {
                        isShowingHome = true
                    } else {
                        isShowingHome = false
                        viewModel.backToLibrary()
                    }
                } label: {
                    Text("Create Another")
                        .font(.system(.callout, design: .rounded).bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(
                            Capsule()
                                .fill(LinearGradient(colors: [hotPink, electricBlue], startPoint: .leading, endPoint: .trailing))
                        )
                }
                .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }
        }
    }

    private var senderProfileSetupPage: some View {
        ScrollView {
            VStack(spacing: 24) {
                Spacer(minLength: 28)
                appTitle

                VStack(spacing: 12) {
                    Text("Set Your Apple Music Sender Profile")
                        .font(.system(.title2, design: .rounded).bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    Text("This is what other people will see when you send them a cassette from Apple Music.")
                        .font(.system(.callout, design: .rounded))
                        .foregroundStyle(fadedText)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 24)
                }

                senderProfileCard
                    .padding(.horizontal, 20)

                Button {
                    viewModel.completeAppleMusicSenderProfileSetup()
                } label: {
                    Text("Continue")
                        .font(.system(.callout, design: .rounded).bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 14)
                        .foregroundStyle(.white)
                        .background(
                            Capsule()
                                .fill(LinearGradient(colors: [hotPink, electricBlue], startPoint: .leading, endPoint: .trailing))
                        )
                }
                .padding(.horizontal, 20)

                statusSection
                    .padding(.horizontal, 20)

                Spacer(minLength: 40)
            }
        }
    }

    private var appTitle: some View {
        VStack(spacing: 2) {
            Text("cassette")
                .font(.system(size: 42, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [hotPink, hotPink.opacity(0.8)], startPoint: .leading, endPoint: .trailing))
            Text("swap")
                .font(.system(size: 42, weight: .heavy, design: .rounded))
                .foregroundStyle(LinearGradient(colors: [electricBlue, electricBlue.opacity(0.8)], startPoint: .leading, endPoint: .trailing))

            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { index in
                    Circle()
                        .fill(index.isMultiple(of: 2) ? hotPink.opacity(0.5) : electricBlue.opacity(0.5))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.top, 6)
        }
    }

    private var headerCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button {
                    viewModel.returnToHome()
                    isShowingHome = true
                    isShowingSentHistory = false
                    viewModel.clearMostRecentlySentCassetteHighlight()
                } label: {
                    Label("Home", systemImage: "chevron.left")
                        .font(.system(.caption, design: .rounded).bold())
                        .foregroundStyle(electricBlue)
                }

                Spacer()

                Text(viewModel.signedInAccount?.service.displayName ?? "")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(hotPink)
            }
            if let service = viewModel.signedInAccount?.service {
                Text(viewModel.displayName(for: service))
                    .font(.system(.title3, design: .rounded).bold())
                    .foregroundStyle(.white)
            }
            Text("Choose a playlist to turn into a cassette.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(fadedText)

            HStack {
                Button {
                    viewModel.refreshOwnedPlaylists()
                } label: {
                    Text("Refresh Playlists")
                        .font(.system(.caption, design: .rounded).bold())
                        .foregroundStyle(electricBlue)
                }

                if viewModel.signedInAccount?.service == .appleMusic {
                    Button {
                        viewModel.editAppleMusicSenderProfile()
                    } label: {
                        Text("Edit Profile")
                            .font(.system(.caption, design: .rounded).bold())
                            .foregroundStyle(.white)
                    }
                }

                Spacer()

                Button {
                    isShowingHome = false
                    isShowingSentHistory = true
                    viewModel.clearMostRecentlySentCassetteHighlight()
                } label: {
                    Text("Sent")
                        .font(.system(.caption, design: .rounded).bold())
                        .foregroundStyle(hotPink)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardBackground)
    }

    @ViewBuilder
    private var incomingCassetteCard: some View {
        if let pendingCassette = viewModel.pendingCassette {
            let senderLabel = pendingCassette.senderName ?? pendingCassette.sourceService.displayName

            VStack(spacing: 12) {
                Text("Incoming Cassette")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(hotPink)

                avatarView(
                    remoteURL: pendingCassette.senderImageURL,
                    imageData: pendingCassette.senderImageData,
                    size: 72,
                    fallbackText: senderLabel
                )

                Text("\(senderLabel) sent you a Cassette!")
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text(pendingCassette.name)
                    .font(.system(.subheadline, design: .rounded).bold())
                    .foregroundStyle(fadedText)
                    .multilineTextAlignment(.center)

                Text("Choose where to recreate this cassette.")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(fadedText)

                signInButton(
                    title: "Create on Apple Music",
                    subtitle: "Sign in or switch if needed, then build it in Apple Music.",
                    action: {
                        isShowingHome = false
                        viewModel.acceptIncomingCassette(to: .appleMusic)
                    }
                )

                signInButton(
                    title: "Create on Spotify",
                    subtitle: "Sign in or switch if needed, then build it in Spotify.",
                    action: {
                        isShowingHome = false
                        viewModel.acceptIncomingCassette(to: .spotify)
                    }
                )

                Button {
                    viewModel.declineIncomingCassette()
                } label: {
                    Text("Decline")
                        .font(.system(.callout, design: .rounded).bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(
                            Capsule()
                                .fill(Color.white.opacity(0.08))
                        )
                }
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(cardBackground)
        }
    }

    private var senderProfileCard: some View {
        let hasSenderProfileImage = viewModel.senderProfileImageData != nil

        return VStack(alignment: .leading, spacing: 14) {
            Text("sender profile")
                .font(.system(.caption2, design: .rounded).bold())
                .foregroundStyle(fadedText)

            Text("Apple Music does not expose a usable account name or profile photo here. Set a fallback once and Cassette Swap will reuse it for Apple Music shares.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(fadedText)

            HStack(alignment: .center, spacing: 14) {
                avatarView(
                    remoteURL: nil,
                    imageData: viewModel.senderProfileImageData,
                    size: 72,
                    fallbackText: viewModel.senderProfileName.nilIfBlank ?? "You"
                )

                VStack(alignment: .leading, spacing: 10) {
                    TextField("Name to show on Apple Music cassettes", text: $viewModel.senderProfileName)
                        .font(.system(.callout, design: .rounded))
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.04))
                                .overlay(
                                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                                        .stroke(Color.white.opacity(0.08), lineWidth: 1)
                                )
                        )
                        .foregroundStyle(.white)

                    HStack(spacing: 10) {
                        PhotosPicker(selection: $selectedSenderPhotoItem, matching: .images) {
                            Label(hasSenderProfileImage ? "Change Photo" : "Choose Photo", systemImage: "photo")
                                .font(.system(.caption, design: .rounded).bold())
                                .foregroundStyle(electricBlue)
                        }

                        if hasSenderProfileImage {
                            Button {
                                viewModel.clearSenderProfileImage()
                                selectedSenderPhotoItem = nil
                            } label: {
                                Label("Remove", systemImage: "trash")
                                    .font(.system(.caption, design: .rounded).bold())
                                    .foregroundStyle(hotPink)
                            }
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(cardBackground)
    }

    private var emptyPlaylistsCard: some View {
        VStack(spacing: 8) {
            Text("No playlists yet")
                .font(.system(.headline, design: .rounded).bold())
                .foregroundStyle(.white)
            Text(viewModel.statusMessage)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(fadedText)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(20)
        .background(cardBackground)
    }

    private func playlistTile(_ playlist: UserPlaylist) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            GeometryReader { geometry in
                let side = geometry.size.width

                AsyncImage(url: playlist.artworkURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                        .frame(width: side, height: side)
                        .clipped()
                } placeholder: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 16)
                            .fill(Color.white.opacity(0.06))
                        Image(systemName: "music.note.list")
                            .font(.system(size: 28))
                            .foregroundStyle(fadedText)
                    }
                    .frame(width: side, height: side)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 16))

            Text(playlist.name)
                .font(.system(.callout, design: .rounded).bold())
                .foregroundStyle(.white)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 42, alignment: .topLeading)

            Text(playlist.summary.nilIfBlank ?? "Owned playlist")
                .font(.system(.caption2, design: .rounded))
                .foregroundStyle(fadedText)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 32, alignment: .topLeading)

            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 0, maxHeight: .infinity, alignment: .topLeading)
        .background(cardBackground)
    }

    private func sourceBadge(_ snapshot: PlaylistSnapshot) -> some View {
        Text(snapshot.sourceService.displayName)
            .foregroundStyle(hotPink)
        .font(.system(.caption, design: .rounded).bold())
    }

    private func trackListCard(_ tracks: [TransferTrack]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(tracks.prefix(10).enumerated()), id: \.element.id) { index, track in
                HStack(spacing: 12) {
                    Text("\(index + 1)")
                        .font(.system(.caption2, design: .rounded).bold())
                        .foregroundStyle(hotPink.opacity(0.5))
                        .frame(width: 18, alignment: .trailing)

                    VStack(alignment: .leading, spacing: 1) {
                        Text(track.title)
                            .font(.system(.caption, design: .rounded))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        Text(track.artistName)
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(fadedText)
                            .lineLimit(1)
                    }

                    Spacer()
                }
                .padding(.vertical, 6)

                if index < min(tracks.count, 10) - 1 {
                    Divider().overlay(Color.white.opacity(0.05))
                }
            }

            if tracks.count > 10 {
                Text("+ \(tracks.count - 10) more")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(fadedText)
                    .frame(maxWidth: .infinity)
                    .padding(.top, 8)
            }
        }
        .padding(14)
        .background(cardBackground)
    }

    private func resultCard(_ result: TransferResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(LinearGradient(colors: [hotPink, electricBlue], startPoint: .topLeading, endPoint: .bottomTrailing))

            Text("Created on \(result.destinationService.displayName)")
                .font(.system(.subheadline, design: .rounded).bold())
                .foregroundStyle(.white)

            if let playlistURL = result.playlistURL {
                Link(destination: playlistURL) {
                    HStack(spacing: 6) {
                        Image(systemName: "arrow.up.right")
                        Text("Open Playlist")
                    }
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(electricBlue)
                }
            }

            Text("\(result.matchedCount) matched, \(result.unmatched.count) unmatched")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(fadedText)

            ForEach(result.notes, id: \.self) { note in
                Text(note)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(fadedText)
                    .multilineTextAlignment(.center)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(cardBackground)
    }

    private var statusSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("status")
                .font(.system(.caption2, design: .rounded).bold())
                .foregroundStyle(fadedText)

            Text(viewModel.statusMessage)
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(.white)

            if !viewModel.activityLog.isEmpty {
                ForEach(Array(viewModel.activityLog.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(fadedText)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(cardBackground)
    }

    private var logSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("activity")
                .font(.system(.caption2, design: .rounded).bold())
                .foregroundStyle(fadedText)
                .frame(maxWidth: .infinity, alignment: .center)
                .padding(.bottom, 4)

            ForEach(Array(viewModel.activityLog.enumerated()), id: \.offset) { entry in
                Text(entry.element)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(fadedText)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(12)
        .background(cardBackground)
    }

    private func inputCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            Text(title.lowercased())
                .font(.system(.caption, design: .rounded).bold())
                .foregroundStyle(fadedText)
            content()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(cardBackground)
    }

    private func signInButton(title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Text(title)
                    .font(.system(.callout, design: .rounded).bold())
                Text(subtitle)
                    .font(.system(.caption2, design: .rounded))
                    .multilineTextAlignment(.center)
                    .opacity(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .foregroundStyle(.white)
            .background(
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(LinearGradient(colors: [hotPink, electricBlue], startPoint: .topLeading, endPoint: .bottomTrailing))
            )
        }
        .disabled(viewModel.isWorking)
        .opacity(viewModel.isWorking ? 0.6 : 1)
    }

    private func styledTextField(_ placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.system(.callout, design: .rounded))
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .multilineTextAlignment(.center)
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.white.opacity(0.04))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.white.opacity(0.08), lineWidth: 1)
                    )
            )
            .foregroundStyle(.white)
    }

    @ViewBuilder
    private var previewBottomBar: some View {
        HStack(spacing: 16) {
            Button {
                viewModel.backToLibrary()
            } label: {
                Text("Back")
                    .font(.system(.callout, design: .rounded).bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(
                        Capsule()
                            .fill(Color.white.opacity(0.08))
                    )
            }

            Button {
                viewModel.transformCurrentPlaylist()
            } label: {
                Text("Transform")
                    .font(.system(.callout, design: .rounded).bold())
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .foregroundStyle(.white)
                    .background(
                        Capsule()
                            .fill(LinearGradient(colors: [hotPink, electricBlue], startPoint: .leading, endPoint: .trailing))
                    )
            }
            .disabled(!viewModel.canTransform)
            .opacity(viewModel.canTransform ? 1 : 0.5)
        }
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 8)
        .background(darkBg.opacity(0.96).ignoresSafeArea())
    }

    private var cardBackground: some View {
        RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(cardBg)
            .overlay(
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .stroke(Color.white.opacity(0.06), lineWidth: 1)
            )
    }

    private func progressBar(_ value: Double) -> some View {
        GeometryReader { geometry in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [hotPink, electricBlue], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geometry.size.width * value)
            }
        }
        .frame(height: 6)
    }

    private func highlightedSentCard(_ record: SentCassetteRecord) -> some View {
        VStack(spacing: 10) {
            Text("Latest Share")
                .font(.system(.caption, design: .rounded).bold())
                .foregroundStyle(hotPink)

            Text(record.name)
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)

            Text("\(record.trackCount) tracks • \(record.sourceService.displayName)")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(fadedText)

            Link(destination: record.shareURL) {
                Label("Open Share Link", systemImage: "arrow.up.right")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(electricBlue)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(cardBackground)
    }

    private func sentCassetteRow(_ record: SentCassetteRecord) -> some View {
        HStack(spacing: 14) {
            AsyncImage(url: record.artworkURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                    .overlay(
                        Image(systemName: "music.note.list")
                            .foregroundStyle(fadedText)
                    )
            }
            .frame(width: 60, height: 60)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))

            VStack(alignment: .leading, spacing: 4) {
                Text(record.name)
                    .font(.system(.callout, design: .rounded).bold())
                    .foregroundStyle(.white)
                    .lineLimit(2)

                Text(record.summary.nilIfBlank ?? "\(record.trackCount) tracks")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(fadedText)
                    .lineLimit(2)

                Text(record.sentAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(hotPink.opacity(0.8))
            }

            Spacer()

            Link(destination: record.shareURL) {
                Image(systemName: "arrow.up.right")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(electricBlue)
                    .frame(width: 34, height: 34)
                    .background(
                        Circle()
                            .fill(Color.white.opacity(0.06))
                    )
            }
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(Color.white.opacity(0.03))
        )
    }

    private var shareSheetBinding: Binding<ShareSheetRequest?> {
        Binding(
            get: { viewModel.shareSheetRequest },
            set: { newValue in
                if newValue == nil {
                    viewModel.clearShareSheetRequest()
                }
            }
        )
    }

    @ViewBuilder
    private func avatarView(remoteURL: URL?, imageData: Data?, size: CGFloat, fallbackText: String) -> some View {
        if let remoteURL {
            AsyncImage(url: remoteURL) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                avatarFallback(size: size, fallbackText: fallbackText)
            }
            .frame(width: size, height: size)
            .clipShape(Circle())
            .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 2))
        } else if let imageData, let uiImage = UIImage(data: imageData) {
            Image(uiImage: uiImage)
                .resizable()
                .scaledToFill()
                .frame(width: size, height: size)
                .clipShape(Circle())
                .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 2))
        } else {
            avatarFallback(size: size, fallbackText: fallbackText)
        }
    }

    private func avatarFallback(size: CGFloat, fallbackText: String) -> some View {
        let initial = String(fallbackText.trimmingCharacters(in: .whitespacesAndNewlines).prefix(1)).uppercased().nilIfBlank ?? "C"

        return ZStack {
            Circle()
                .fill(LinearGradient(colors: [hotPink, electricBlue], startPoint: .topLeading, endPoint: .bottomTrailing))

            Text(initial)
                .font(.system(size: max(20, size * 0.34), weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .overlay(Circle().stroke(Color.white.opacity(0.12), lineWidth: 2))
    }

    @MainActor
    private func loadSenderPhoto(from item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let normalizedData = normalizedSenderPhotoData(from: data) else {
            return
        }

        viewModel.setSenderProfileImageData(normalizedData)
    }

    private func normalizedSenderPhotoData(from data: Data) -> Data? {
        guard let image = UIImage(data: data) else {
            return nil
        }

        let thumbnail = image.preparingThumbnail(of: CGSize(width: 512, height: 512)) ?? image
        return thumbnail.jpegData(compressionQuality: 0.82)
    }
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]
    let onComplete: (Bool) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onComplete: onComplete)
    }

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, completed, _, _ in
            context.coordinator.onComplete(completed)
        }
        return controller
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}

    final class Coordinator {
        let onComplete: (Bool) -> Void

        init(onComplete: @escaping (Bool) -> Void) {
            self.onComplete = onComplete
        }
    }
}
