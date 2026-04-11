import SwiftUI

struct ContentView: View {
    @StateObject private var viewModel = PlaylistTransferViewModel()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    Text("Cassette Swap")
                        .font(.largeTitle.bold())
                        .frame(maxWidth: .infinity, alignment: .leading)

                    setupSection
                    playlistSection

                    if let snapshot = viewModel.snapshot {
                        previewSection(snapshot)
                    }

                    statusSection

                    if !viewModel.activityLog.isEmpty {
                        activitySection
                    }

                    if let result = viewModel.transferResult {
                        resultSection(result)
                    }
                }
                .padding()
            }
            .background(Color(.systemGroupedBackground))
            .navigationTitle("Cassette Swap")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var setupSection: some View {
        card("Spotify Setup") {
            TextField("Spotify client ID", text: $viewModel.spotifyClientID)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            Text("Spotify requires OAuth even when the source playlist is public. Register a Spotify app and allow the redirect URI `cassette-swap://spotify-callback`.")
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
    }

    private var playlistSection: some View {
        card("Playlist") {
            TextField("Public Spotify or Apple Music playlist URL", text: $viewModel.playlistURLText, axis: .vertical)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .textFieldStyle(.roundedBorder)

            Button("Preview Playlist") {
                viewModel.inspectPlaylist()
            }
            .disabled(!viewModel.canInspect)

            if let snapshot = viewModel.snapshot {
                Button("Create on \(snapshot.destinationService.displayName)") {
                    viewModel.transferCurrentPlaylist()
                }
                .disabled(!viewModel.canTransfer)
            }
        }
    }

    private func previewSection(_ snapshot: PlaylistSnapshot) -> some View {
        card("Preview") {
            HStack(alignment: .top, spacing: 16) {
                AsyncImage(url: snapshot.artworkURL) { image in
                    image
                        .resizable()
                        .scaledToFill()
                } placeholder: {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(.quaternary)
                        Image(systemName: "music.note.list")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(width: 76, height: 76)
                .clipShape(RoundedRectangle(cornerRadius: 12))

                VStack(alignment: .leading, spacing: 6) {
                    Text(snapshot.name)
                        .font(.headline)
                    Text("\(snapshot.sourceService.displayName) -> \(snapshot.destinationService.displayName)")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("\(snapshot.tracks.count) tracks")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            if !snapshot.summary.isEmpty {
                Text(snapshot.summary)
            }

            if snapshot.destinationService == .spotify {
                Text("Spotify can create a public playlist and will try to copy the artwork when the source provides one.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            } else {
                Text("Apple Music only exposes library playlist creation here. MusicKit does not expose custom artwork upload or public-profile publishing for library playlists.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            ForEach(snapshot.tracks.prefix(8)) { track in
                VStack(alignment: .leading, spacing: 2) {
                    Text(track.title)
                    Text(track.artistName)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }

            if snapshot.tracks.count > 8 {
                Text("...and \(snapshot.tracks.count - 8) more tracks")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var statusSection: some View {
        card("Status") {
            Text(viewModel.statusMessage)

            if let progress = viewModel.progressValue {
                ProgressView(value: progress)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var activitySection: some View {
        card("Activity") {
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array(viewModel.activityLog.enumerated()), id: \.offset) { entry in
                    Text(entry.element)
                        .font(.system(.footnote, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func resultSection(_ result: TransferResult) -> some View {
        card("Result") {
            Text("Created on \(result.destinationService.displayName).")

            if let playlistURL = result.playlistURL {
                Link("Open Playlist", destination: playlistURL)
            }

            Text("\(result.matchedCount) tracks matched, \(result.unmatched.count) unmatched.")

            if result.artworkCopied {
                Text("Artwork copied.")
            }

            ForEach(result.notes, id: \.self) { note in
                Text(note)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if !result.unmatched.isEmpty {
                Text(result.unmatched.prefix(5).map { "\($0.artistName) - \($0.title)" }.joined(separator: "\n"))
                    .font(.footnote)
            }
        }
    }

    private func card<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding()
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color(.secondarySystemBackground))
        )
    }
}
