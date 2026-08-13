import Foundation

struct SensitiveDataRedactor: Sendable {
    private static let sensitiveFieldNames: Set<String> = [
        "token",
        "authtoken",
        "secret",
        "password",
        "authorization",
        "credential",
        "connectorurl",
        "chatid",
        "chatsecret",
        "apikey",
        "privatekey",
        "ngrokauthtoken",
        "webhooksecret",
        "capabilitytoken"
    ]

    private let exactSecrets: [String]
    private let homeDirectory: String?

    init(exactSecrets: [String], homeDirectory: String?) {
        self.exactSecrets = exactSecrets
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted { $0.count > $1.count }
        let normalizedHome = homeDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.homeDirectory = normalizedHome.flatMap { $0.isEmpty ? nil : $0 }
    }

    func redact(_ value: String) -> String {
        var redacted = replaceConnectorURLs(in: value)
        redacted = replaceExactSecrets(in: redacted)
        redacted = replaceSecretAssignments(in: redacted)
        return normalizeHomePaths(in: redacted)
    }

    func redactJSON(_ data: Data) -> Data? {
        guard let object = try? JSONSerialization.jsonObject(
            with: data,
            options: [.fragmentsAllowed]
        ) else {
            return nil
        }

        let redacted = redactJSONValue(object, fieldName: nil)
        return try? JSONSerialization.data(
            withJSONObject: redacted,
            options: [.sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        )
    }

    func redactedPath(_ path: String) -> String {
        var redacted = path
        if let homeDirectory,
           redacted == homeDirectory || redacted.hasPrefix(homeDirectory + "/") {
            redacted = "<home>" + redacted.dropFirst(homeDirectory.count)
        }
        redacted = replaceUserHomePath(in: redacted)
        redacted = replaceConnectorURLs(in: redacted)
        redacted = replaceExactSecrets(in: redacted)
        return replaceSecretAssignments(in: redacted)
    }

    private func replaceExactSecrets(in value: String) -> String {
        exactSecrets.reduce(value) { current, secret in
            current.replacingOccurrences(of: secret, with: "<redacted>")
        }
    }

    private func replaceConnectorURLs(in value: String) -> String {
        let redacted = replacingMatches(
            pattern: #"(?i)https?://[^\s"'<>]+"#,
            in: value,
            with: "<redacted>"
        )
        return replacingMatches(
            pattern: #"(?i)(?<![A-Za-z0-9_])(?:/[A-Za-z0-9._~%-]+)?/mcp(?:[/?#][^\s"'<>]*)?"#,
            in: redacted,
            with: "<redacted>"
        )
    }

    private func replaceSecretAssignments(in value: String) -> String {
        replacingMatches(
            pattern: #"(?i)(\b(?:token|bot[_-]?token|auth[_-]?token|access[_-]?token|refresh[_-]?token|capability[_-]?token|connector[_-]?(?:url|token|secret)|api[_-]?(?:key|token|secret)|ngrok[_-]?authtoken|chat[_-]?id|password|secret|authorization|credential|private[_-]?key|webhook[_-]?secret|client[_-]?secret)\b\s*[:=]\s*["']?(?:Bearer\s+)?)([^\s"'&,}\]]+)"#,
            in: value,
            with: "$1<redacted>"
        )
    }

    private func normalizeHomePaths(in value: String) -> String {
        var normalized = value
        if let homeDirectory {
            let escapedHome = NSRegularExpression.escapedPattern(for: homeDirectory)
            normalized = replacingMatches(
                pattern: "(?<![A-Za-z0-9_])\(escapedHome)(?=$|[/\\\\\\s\"'<>),;:{}])",
                in: normalized,
                with: "<home>"
            )
        }
        return replaceUserHomePath(in: normalized)
    }

    private func replaceUserHomePath(in value: String) -> String {
        replacingMatches(
            pattern: #"(?<![A-Za-z0-9_])/Users/[^/\s"'<>),;:{}]+"#,
            in: value,
            with: "<home>"
        )
    }

    private func redactJSONValue(_ value: Any, fieldName: String?) -> Any {
        if let fieldName, isSensitiveField(fieldName) {
            return "<redacted>"
        }
        if let dictionary = value as? [String: Any] {
            return dictionary.reduce(into: [String: Any]()) { result, entry in
                result[entry.key] = redactJSONValue(entry.value, fieldName: entry.key)
            }
        }
        if let array = value as? [Any] {
            return array.map { redactJSONValue($0, fieldName: nil) }
        }
        if let string = value as? String {
            return redact(string)
        }
        return value
    }

    private func isSensitiveField(_ fieldName: String) -> Bool {
        let normalized = fieldName
            .filter { $0.isLetter || $0.isNumber }
            .lowercased()
        if Self.sensitiveFieldNames.contains(normalized) {
            return true
        }
        return normalized.hasSuffix("token")
            || normalized.hasSuffix("secret")
            || normalized.hasSuffix("password")
            || normalized.hasSuffix("credential")
            || normalized.hasPrefix("authorization")
    }

    private func replacingMatches(pattern: String, in value: String, with replacement: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return value
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            range: range,
            withTemplate: replacement
        )
    }
}
