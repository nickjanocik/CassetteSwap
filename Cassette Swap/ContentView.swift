import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PlaylistTransferViewModel()
    @State private var sourceService: MusicService = .spotify

    // Pink/blue palette
    private let hotPink = Color(red: 1.0, green: 0.33, blue: 0.64)
    private let electricBlue = Color(red: 0.35, green: 0.65, blue: 1.0)
    private let darkBg = Color(red: 0.06, green: 0.04, blue: 0.12)
    private let cardBg = Color(red: 0.1, green: 0.08, blue: 0.18)
    private let fadedText = Color(red: 0.6, green: 0.55, blue: 0.7)

    private var accent: Color { hotPink }
    private var secondary: Color { electricBlue }

    private enum Page {
        case input
        case preview
    }

    private var currentPage: Page {
        if viewModel.snapshot != nil {
            return .preview
        }
        return .input
    }

    var body: some View {
        ZStack {
            darkBg.ignoresSafeArea()

            switch currentPage {
            case .input:
                inputPage
                    .transition(.opacity.combined(with: .move(edge: .leading)))
            case .preview:
                previewPage
                    .transition(.opacity.combined(with: .move(edge: .trailing)))
            }
        }
        .animation(.easeInOut(duration: 0.35), value: currentPage == .preview)
        .preferredColorScheme(.dark)
    }

    // MARK: - Input Page

    private var inputPage: some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 20)

                appTitle

                directionSwitch
                    .padding(.horizontal, 20)

                if sourceService == .spotify {
                    inputCard("Spotify Client ID") {
                        styledTextField("client id", text: $viewModel.spotifyClientID)
                        Text("Register a Spotify app with redirect URI\ncassette-swap://spotify-callback")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(fadedText)
                            .multilineTextAlignment(.center)
                    }
                    .padding(.horizontal, 20)
                }

                inputCard("Playlist URL") {
                    let hint = sourceService == .spotify ? "paste spotify link" : "paste apple music link"
                    styledTextField(hint, text: $viewModel.playlistURLText, axis: .vertical)
                }
                .padding(.horizontal, 20)

                actionButton("Preview", icon: "magnifyingglass", disabled: !viewModel.canInspect) {
                    viewModel.inspectPlaylist()
                }
                .padding(.horizontal, 40)

                if viewModel.isWorking && viewModel.snapshot == nil {
                    ProgressView()
                        .tint(hotPink)
                        .scaleEffect(1.2)
                        .padding(.top, 8)
                }

                if !viewModel.activityLog.isEmpty && viewModel.snapshot == nil {
                    logSection
                        .padding(.horizontal, 20)
                }

                Spacer(minLength: 60)
            }
        }
        .scrollDismissesKeyboard(.immediately)
    }

    // MARK: - Preview Page

    private var previewPage: some View {
        ScrollView {
            VStack(spacing: 20) {
                Color.clear
                    .frame(height: 12)

                if let snapshot = viewModel.snapshot {
                    // Artwork
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
                    .shadow(color: hotPink.opacity(0.3), radius: 20, y: 8)

                    // Title
                    Text(snapshot.name)
                        .font(.system(.title2, design: .rounded).bold())
                        .foregroundStyle(.white)
                        .multilineTextAlignment(.center)

                    // Direction badge
                    HStack(spacing: 6) {
                        Text(snapshot.sourceService.displayName)
                            .foregroundStyle(hotPink)
                        Image(systemName: "arrow.right")
                            .font(.caption2.bold())
                            .foregroundStyle(fadedText)
                        Text(snapshot.destinationService.displayName)
                            .foregroundStyle(electricBlue)
                    }
                    .font(.system(.caption, design: .rounded).bold())

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

                    // Track list
                    trackListCard(snapshot.tracks)
                        .padding(.horizontal, 20)

                    // Progress / status during transfer
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
                        .padding(.top, 4)
                    }

                    if !viewModel.activityLog.isEmpty {
                        logSection
                            .padding(.horizontal, 20)
                    }

                    if let result = viewModel.transferResult {
                        resultCard(result)
                            .padding(.horizontal, 20)
                    }

                    Color.clear
                        .frame(height: previewBottomInsetSpacing)
                }

                Color.clear
                    .frame(height: 24)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollDismissesKeyboard(.interactively)
        .safeAreaInset(edge: .bottom) {
            previewBottomBar
        }
    }

    // MARK: - App Title

    private var appTitle: some View {
        VStack(spacing: 2) {
            Text("cassette")
                .font(.system(size: 42, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [hotPink, hotPink.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                )
            Text("swap")
                .font(.system(size: 42, weight: .heavy, design: .rounded))
                .foregroundStyle(
                    LinearGradient(colors: [electricBlue, electricBlue.opacity(0.8)], startPoint: .leading, endPoint: .trailing)
                )

            // Decorative line
            HStack(spacing: 3) {
                ForEach(0..<20, id: \.self) { i in
                    Circle()
                        .fill(i % 2 == 0 ? hotPink.opacity(0.5) : electricBlue.opacity(0.5))
                        .frame(width: 4, height: 4)
                }
            }
            .padding(.top, 6)
        }
    }

    // MARK: - Direction Switch

    private var directionSwitch: some View {
        HStack(spacing: 0) {
            switchTab(.spotify)
            switchTab(.appleMusic)
        }
        .padding(4)
        .background(
            Capsule().fill(Color.white.opacity(0.06))
        )
    }

    private func switchTab(_ service: MusicService) -> some View {
        let isSelected = sourceService == service
        let label = service == .spotify ? "Spotify" : "Apple Music"
        let dest = service.otherService.displayName

        return Button {
            withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                sourceService = service
            }
            if viewModel.snapshot != nil {
                viewModel.clearState()
            }
        } label: {
            VStack(spacing: 2) {
                Text("\(label) \(Image(systemName: "arrow.right")) \(dest)")
                    .font(.system(.caption, design: .rounded).bold())
            }
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity)
            .foregroundStyle(isSelected ? .white : fadedText)
            .background(
                Capsule()
                    .fill(
                        isSelected
                            ? LinearGradient(colors: [hotPink.opacity(0.7), electricBlue.opacity(0.7)], startPoint: .leading, endPoint: .trailing)
                            : LinearGradient(colors: [.clear], startPoint: .leading, endPoint: .trailing)
                    )
            )
        }
    }

    // MARK: - Track List

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
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    // MARK: - Result Card

    private func resultCard(_ result: TransferResult) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(
                    LinearGradient(colors: [hotPink, electricBlue], startPoint: .topLeading, endPoint: .bottomTrailing)
                )

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

            if result.artworkCopied {
                Text("Artwork copied")
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(fadedText)
            }

            ForEach(result.notes, id: \.self) { note in
                Text(note)
                    .font(.system(.caption2, design: .rounded))
                    .foregroundStyle(fadedText)
                    .multilineTextAlignment(.center)
            }

            if !result.unmatched.isEmpty {
                VStack(spacing: 4) {
                    Text("Unmatched")
                        .font(.system(.caption2, design: .rounded).bold())
                        .foregroundStyle(hotPink.opacity(0.7))
                    ForEach(result.unmatched.prefix(5), id: \.id) { track in
                        Text("\(track.artistName) — \(track.title)")
                            .font(.system(.caption2, design: .rounded))
                            .foregroundStyle(fadedText)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity)
        .padding(18)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(
                            LinearGradient(colors: [hotPink.opacity(0.3), electricBlue.opacity(0.3)], startPoint: .topLeading, endPoint: .bottomTrailing),
                            lineWidth: 1
                        )
                )
        )
    }

    // MARK: - Log Section

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
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(cardBg)
        )
    }

    // MARK: - Components

    private func inputCard(_ title: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(spacing: 10) {
            Text(title.lowercased())
                .font(.system(.caption, design: .rounded).bold())
                .foregroundStyle(fadedText)

            content()
        }
        .frame(maxWidth: .infinity)
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(cardBg)
                .overlay(
                    RoundedRectangle(cornerRadius: 14, style: .continuous)
                        .stroke(Color.white.opacity(0.06), lineWidth: 1)
                )
        )
    }

    private func styledTextField(_ placeholder: String, text: Binding<String>, axis: Axis = .horizontal) -> some View {
        TextField(placeholder, text: text, axis: axis)
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

    private func actionButton(_ label: String, icon: String, disabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: icon)
                    .font(.system(.caption, design: .rounded).bold())
                Text(label)
                    .font(.system(.callout, design: .rounded).bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                Capsule()
                    .fill(
                        LinearGradient(colors: [hotPink, electricBlue], startPoint: .leading, endPoint: .trailing)
                    )
            )
            .shadow(color: hotPink.opacity(disabled ? 0 : 0.3), radius: 12, y: 4)
        }
        .disabled(disabled)
        .opacity(disabled ? 0.4 : 1)
    }

    private func cancelButton(label: String = "Cancel", action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.left")
                    .font(.system(.caption2, design: .rounded).bold())
                Text(label)
                    .font(.system(.callout, design: .rounded).bold())
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 14)
            .foregroundStyle(.white)
            .background(
                Capsule()
                    .fill(Color.white.opacity(0.08))
                    .overlay(
                        Capsule().stroke(Color.white.opacity(0.12), lineWidth: 1)
                    )
            )
        }
    }

    @ViewBuilder
    private var previewBottomBar: some View {
        if !viewModel.isWorking && viewModel.transferResult == nil {
            HStack(spacing: 16) {
                cancelButton {
                    withAnimation {
                        viewModel.clearState()
                    }
                }

                actionButton("Transform", icon: "wand.and.stars", disabled: !viewModel.canTransfer) {
                    viewModel.transferCurrentPlaylist()
                }
            }
            .padding(.horizontal, 20)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(bottomBarBackground)
        } else if viewModel.transferResult != nil {
            cancelButton(label: "Start Over") {
                withAnimation {
                    viewModel.clearState()
                }
            }
            .padding(.horizontal, 40)
            .padding(.top, 12)
            .padding(.bottom, 8)
            .background(bottomBarBackground)
        }
    }

    private var previewBottomInsetSpacing: CGFloat {
        viewModel.transferResult == nil ? 96 : 84
    }

    private var bottomBarBackground: some View {
        darkBg
            .opacity(0.96)
            .ignoresSafeArea()
    }

    private func progressBar(_ value: Double) -> some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.white.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: [hotPink, electricBlue], startPoint: .leading, endPoint: .trailing))
                    .frame(width: geo.size.width * value)
            }
        }
        .frame(height: 6)
    }
}
