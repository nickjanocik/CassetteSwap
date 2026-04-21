import Foundation

struct RemoteCassetteShare {
    let id: String
    let shareURL: URL
    let openURL: URL?
}

final class CassetteShareService {
    private let session = URLSession.shared

    func createShare(for payload: CassettePayload, baseURL: URL) async throws -> RemoteCassetteShare {
        let url = try Self.endpoint(baseURL: baseURL, path: "/cassette")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = try JSONEncoder().encode(payload)

        let (data, response) = try await session.data(for: request)
        let decoded: CreateCassetteResponse = try decode(response: response, data: data, fallback: "Could not create a public cassette link.")

        return RemoteCassetteShare(id: decoded.id, shareURL: decoded.shareURL, openURL: decoded.openURL)
    }

    func fetchCassette(id: String, baseURL: URL) async throws -> CassettePayload {
        let url = try Self.endpoint(baseURL: baseURL, path: "/cassette/\(id)")
        let (data, response) = try await session.data(from: url)
        let decoded: FetchCassetteResponse = try decode(response: response, data: data, fallback: "Could not load the shared cassette.")
        return decoded.payload
    }

    static func normalizedBaseURL(from rawValue: String) -> URL? {
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.isEmpty == false else {
            return nil
        }

        let candidate = URL(string: trimmed) ?? URL(string: "https://\(trimmed)")
        guard let candidate else {
            return nil
        }

        guard var components = URLComponents(url: candidate, resolvingAgainstBaseURL: false),
              let scheme = components.scheme?.lowercased(),
              ["http", "https"].contains(scheme),
              components.host != nil else {
            return nil
        }

        components.query = nil
        components.fragment = nil

        if components.path == "/" {
            components.path = ""
        }

        return components.url
    }

    private static func endpoint(baseURL: URL, path: String) throws -> URL {
        guard var components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false) else {
            throw AppError.message("Public share base URL is invalid.")
        }

        let basePath = components.path == "/" ? "" : components.path
        components.path = basePath + path
        components.query = nil
        components.fragment = nil

        guard let url = components.url else {
            throw AppError.message("Public share base URL is invalid.")
        }

        return url
    }

    private func decode<Response: Decodable>(response: URLResponse, data: Data, fallback: String) throws -> Response {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw AppError.message(fallback)
        }

        guard (200..<300).contains(httpResponse.statusCode) else {
            if let serviceError = try? JSONDecoder().decode(WorkerErrorResponse.self, from: data),
               let message = serviceError.error.nilIfBlank {
                throw AppError.message(message)
            }

            throw AppError.message(fallback)
        }

        do {
            return try JSONDecoder().decode(Response.self, from: data)
        } catch {
            throw AppError.message(fallback)
        }
    }
}

private struct CreateCassetteResponse: Decodable {
    let id: String
    let shareURL: URL
    let openURL: URL?

    enum CodingKeys: String, CodingKey {
        case id
        case shareURL = "shareUrl"
        case openURL = "openUrl"
    }
}

private struct FetchCassetteResponse: Decodable {
    let id: String
    let payload: CassettePayload
}

private struct WorkerErrorResponse: Decodable {
    let error: String?
}
