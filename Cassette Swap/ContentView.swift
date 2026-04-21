import SwiftUI
import UIKit

struct ContentView: View {
    @StateObject private var viewModel = PlaylistTransferViewModel()

    private let hotPink = Color(red: 1.0, green: 0.33, blue: 0.64)
    private let electricBlue = Color(red: 0.35, green: 0.65, blue: 1.0)
    private let darkBg = Color(red: 0.06, green: 0.04, blue: 0.12)
    private let cardBg = Color(red: 0.1, green: 0.08, blue: 0.18)
    private let fadedText = Color(red: 0.6, green: 0.55, blue: 0.7)

    private enum Page {
        case signIn
        case library
        case preview
    }

    private var currentPage: Page {
        if viewModel.snapshot != nil {
            return .preview
        }
        if viewModel.needsSignIn {
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
            }
        }
        .animation(.easeInOut(duration: 0.3), value: currentPage)
        .preferredColorScheme(.dark)
        .onOpenURL { url in
            viewModel.handleIncomingURL(url)
        }
        .sheet(item: shareSheetBinding) { request in
            ActivityViewController(activityItems: request.items)
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

                signInButton(
                    title: "Continue with Apple Music",
                    subtitle: "Browse your library playlists with MusicKit.",
                    action: { viewModel.signIn(to: .appleMusic) }
                )
                .padding(.horizontal, 20)

                inputCard("Spotify Client ID") {
                    styledTextField("client id", text: $viewModel.spotifyClientID)
                    Text("Spotify still requires your app client ID with redirect URI `cassette-swap://spotify-callback`.")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(fadedText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)

                inputCard("Public Share Base URL") {
                    styledTextField("https://swap.yourdomain.com", text: $viewModel.shareBackendBaseURL)
                    Text("Optional Cloudflare Worker URL. If set, Transform creates a short public HTTPS link instead of embedding the full cassette payload in the custom scheme.")
                        .font(.system(.caption2, design: .rounded))
                        .foregroundStyle(fadedText)
                        .multilineTextAlignment(.center)
                }
                .padding(.horizontal, 20)

                signInButton(
                    title: "Continue with Spotify",
                    subtitle: "Browse the public playlists you own.",
                    action: { viewModel.signIn(to: .spotify) }
                )
                .padding(.horizontal, 20)

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
            Text(viewModel.signedInAccount?.service.displayName ?? "")
                .font(.system(.caption, design: .rounded).bold())
                .foregroundStyle(hotPink)
            Text(viewModel.signedInAccount?.displayName ?? "")
                .font(.system(.title3, design: .rounded).bold())
                .foregroundStyle(.white)
            Text("Choose a playlist to turn into a cassette.")
                .font(.system(.caption, design: .rounded))
                .foregroundStyle(fadedText)

            Button {
                viewModel.refreshOwnedPlaylists()
            } label: {
                Text("Refresh Playlists")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(electricBlue)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(18)
        .background(cardBackground)
    }

    @ViewBuilder
    private var incomingCassetteCard: some View {
        if let pendingCassette = viewModel.pendingCassette {
            VStack(spacing: 12) {
                Text("Incoming Cassette")
                    .font(.system(.caption, design: .rounded).bold())
                    .foregroundStyle(hotPink)

                Text(pendingCassette.name)
                    .font(.system(.headline, design: .rounded).bold())
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)

                Text("From \(pendingCassette.senderName ?? pendingCassette.sourceService.displayName)")
                    .font(.system(.caption, design: .rounded))
                    .foregroundStyle(fadedText)

                Button {
                    viewModel.acceptIncomingCassette()
                } label: {
                    Text(viewModel.needsSignIn ? "Sign In to Accept" : "Accept Cassette")
                        .font(.system(.callout, design: .rounded).bold())
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .foregroundStyle(.white)
                        .background(
                            Capsule()
                                .fill(LinearGradient(colors: [hotPink, electricBlue], startPoint: .leading, endPoint: .trailing))
                        )
                }
                .disabled(viewModel.needsSignIn || viewModel.isWorking)
                .opacity(viewModel.needsSignIn ? 0.5 : 1)
            }
            .frame(maxWidth: .infinity)
            .padding(16)
            .background(cardBackground)
        }
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
        HStack(spacing: 6) {
            Text(snapshot.sourceService.displayName)
                .foregroundStyle(hotPink)
            if let destination = viewModel.signedInAccount?.service {
                Image(systemName: "arrow.right")
                    .font(.caption2.bold())
                    .foregroundStyle(fadedText)
                Text(destination.displayName)
                    .foregroundStyle(electricBlue)
            }
        }
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
}

private struct ActivityViewController: UIViewControllerRepresentable {
    let activityItems: [Any]

    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: activityItems, applicationActivities: nil)
    }

    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
