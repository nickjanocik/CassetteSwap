import Foundation

enum TrackMatcher {
    static func score(
        source: TransferTrack,
        candidateTitle: String,
        candidateArtist: String,
        candidateAlbum: String?,
        candidateISRC: String?
    ) -> Int {
        if let sourceISRC = source.isrc?.uppercased(),
           let candidateISRC = candidateISRC?.uppercased(),
           sourceISRC.isEmpty == false,
           sourceISRC == candidateISRC {
            return 1_000
        }

        let sourceTitle = source.title.normalizedForMatching
        let sourceArtist = source.artistName.normalizedForMatching
        let sourceAlbum = source.albumTitle?.normalizedForMatching

        let title = candidateTitle.normalizedForMatching
        let artist = candidateArtist.normalizedForMatching
        let album = candidateAlbum?.normalizedForMatching

        var score = 0

        if title == sourceTitle {
            score += 60
        } else if title.contains(sourceTitle) || sourceTitle.contains(title) {
            score += 35
        }

        if artist == sourceArtist {
            score += 35
        } else if artist.contains(sourceArtist) || sourceArtist.contains(artist) {
            score += 22
        }

        let sourceArtistTokens = Set(sourceArtist.split(separator: " ").map(String.init))
        let candidateArtistTokens = Set(artist.split(separator: " ").map(String.init))
        score += min(sourceArtistTokens.intersection(candidateArtistTokens).count * 6, 24)

        if let sourceAlbum, let album {
            if album == sourceAlbum {
                score += 12
            } else if album.contains(sourceAlbum) || sourceAlbum.contains(album) {
                score += 6
            }
        }

        return score
    }

    static func isGoodEnough(_ score: Int) -> Bool {
        score >= 55
    }
}
