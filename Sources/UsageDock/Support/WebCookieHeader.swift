import Foundation

/// A browser `Cookie` request header the user copied themselves. TokenRemain
/// never reads browser cookie stores; this only normalizes what was pasted —
/// a raw `a=b; c=d` value, a `Cookie:` header line (alone or inside a copied
/// block of request headers) or a "Copy as cURL" command — into one header.
enum WebCookieHeader {
    static let maxBytes = 32_768

    /// `name=value; …` with validated names, or nil when the text is not a
    /// usable Cookie header.
    static func normalized(_ raw: String) -> String? {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.lowercased().hasPrefix("cookie:") {
            text = String(text.dropFirst("cookie:".count)).trimmingCharacters(in: .whitespaces)
        }
        if text.count >= 2, let first = text.first, first == text.last, first == "'" || first == "\"" {
            text = String(text.dropFirst().dropLast())
        }
        guard !text.isEmpty, text.utf8.count <= maxBytes,
              !text.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
            return nil
        }
        var pairs: [String] = []
        for pair in text.split(separator: ";") {
            let trimmed = pair.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            let parts = trimmed.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            let name = parts[0].trimmingCharacters(in: .whitespaces)
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty,
                  name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "_-.".contains($0)) }) else {
                return nil
            }
            pairs.append("\(name)=\(value)")
        }
        return pairs.isEmpty ? nil : pairs.joined(separator: "; ")
    }

    /// Clipboard import: recognizes the three shapes browsers' developer tools
    /// produce and returns the normalized header. Unrelated text (including a
    /// lone API key) is rejected so it never lands in a Cookie field.
    static func extract(fromClipboard text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= maxBytes * 4 else { return nil }
        if trimmed.range(of: #"^curl\s"#, options: [.regularExpression, .caseInsensitive]) != nil {
            return fromCurl(trimmed)
        }
        // A copied block of request headers: take the `cookie:` line.
        let lines = trimmed.split(whereSeparator: \.isNewline)
        if lines.count > 1 {
            for line in lines {
                let candidate = line.trimmingCharacters(in: .whitespaces)
                if candidate.lowercased().hasPrefix("cookie:") {
                    return normalized(candidate)
                }
            }
            return nil
        }
        guard trimmed.contains("=") else { return nil }
        return normalized(trimmed)
    }

    /// Value of the `name` cookie, if present.
    static func value(named name: String, in header: String) -> String? {
        for pair in header.split(separator: ";") {
            let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, parts[0].trimmingCharacters(in: .whitespaces) == name else { continue }
            let value = parts[1].trimmingCharacters(in: .whitespaces)
            return value.isEmpty ? nil : value
        }
        return nil
    }

    private static func fromCurl(_ command: String) -> String? {
        // `-b '…'` / `--cookie '…'`, then `-H 'cookie: …'` (Chrome uses either).
        let patterns = [
            #"(?:^|\s)(?:-b|--cookie)\s+(?:\$)?'([^']*)'"#,
            #"(?:^|\s)(?:-b|--cookie)\s+"([^"]*)""#,
            #"(?:^|\s)(?:-H|--header)\s+(?:\$)?'[Cc][Oo][Oo][Kk][Ii][Ee]:\s*([^']*)'"#,
            #"(?:^|\s)(?:-H|--header)\s+"[Cc][Oo][Oo][Kk][Ii][Ee]:\s*([^"]*)""#
        ]
        for pattern in patterns {
            guard let regex = try? NSRegularExpression(pattern: pattern),
                  let match = regex.firstMatch(
                    in: command,
                    range: NSRange(command.startIndex..<command.endIndex, in: command)
                  ),
                  let range = Range(match.range(at: 1), in: command) else { continue }
            if let header = normalized(String(command[range])) { return header }
        }
        return nil
    }
}
