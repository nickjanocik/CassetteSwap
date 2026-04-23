import Foundation

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var nilIfBlank: String? {
        let value = trimmed
        guard value.isEmpty == false else {
            return nil
        }

        let normalized = value.lowercased()
        if normalized == "null" || normalized == "(null)" || normalized == "<null>" {
            return nil
        }

        return value
    }

    var condensedWhitespace: String {
        split { $0.isWhitespace }.joined(separator: " ")
    }

    var strippedHTML: String {
        guard let data = data(using: .utf8) else {
            return self.condensedWhitespace
        }

        let options: [NSAttributedString.DocumentReadingOptionKey: Any] = [
            .documentType: NSAttributedString.DocumentType.html,
            .characterEncoding: String.Encoding.utf8.rawValue
        ]

        if let attributed = try? NSAttributedString(data: data, options: options, documentAttributes: nil) {
            return attributed.string
                .replacingOccurrences(of: "\u{00a0}", with: " ")
                .condensedWhitespace
        }

        return replacingOccurrences(of: "<[^>]+>", with: " ", options: .regularExpression)
            .condensedWhitespace
    }

    var normalizedForMatching: String {
        var value = folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        value = value.replacingOccurrences(of: "&", with: " and ")
        value = value.replacingOccurrences(of: "[^a-z0-9]+", with: " ", options: .regularExpression)
        return value.condensedWhitespace
    }

    func truncated(to maximumLength: Int) -> String {
        String(prefix(maximumLength))
    }
}
