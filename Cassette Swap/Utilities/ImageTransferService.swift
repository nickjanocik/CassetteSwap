import Foundation
import UIKit

enum ImageTransferService {
    static func spotifyJPEGBase64Body(from url: URL) async throws -> Data {
        let (data, response) = try await URLSession.shared.data(from: url)
        guard let httpResponse = response as? HTTPURLResponse, (200..<300).contains(httpResponse.statusCode) else {
            throw AppError.message("Could not download the source playlist artwork.")
        }

        guard let image = UIImage(data: data) else {
            throw AppError.message("The source playlist artwork could not be decoded.")
        }

        var dimension: CGFloat = 600
        while dimension >= 160 {
            let resized = image.resized(maxDimension: dimension)

            for quality in stride(from: 0.82, through: 0.25, by: -0.12) {
                guard let jpegData = resized.jpegData(compressionQuality: quality) else {
                    continue
                }

                if jpegData.count <= 256_000 {
                    return Data(jpegData.base64EncodedString().utf8)
                }
            }

            dimension -= 120
        }

        throw AppError.message("The source artwork was too large for Spotify's cover upload limit.")
    }
}

private extension UIImage {
    func resized(maxDimension: CGFloat) -> UIImage {
        let longestSide = max(size.width, size.height)
        guard longestSide > maxDimension else {
            return self
        }

        let scale = maxDimension / longestSide
        let targetSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: targetSize)

        return renderer.image { _ in
            draw(in: CGRect(origin: .zero, size: targetSize))
        }
    }
}
