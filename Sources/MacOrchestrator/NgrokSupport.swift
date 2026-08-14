import Foundation

private struct NgrokEndpointResponse: Decodable {
    let endpoints: [NgrokEndpoint]
}

struct NgrokEndpoint: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: String
    let upstream: NgrokEndpointUpstream

    var description: String { "NgrokEndpoint" }
    var debugDescription: String { description }
}

struct NgrokEndpointUpstream: Decodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let url: String

    var description: String { "NgrokEndpointUpstream" }
    var debugDescription: String { description }
}

enum RemoteEndpointReconciliation: Equatable, Sendable {
    case current(publicURL: URL)
    case missing
    case foreign
    case ambiguous
    case agentAPIUnavailable
    case invalidAgentAPIResponse
}

enum NgrokEndpointParser {
    static let maximumResponseBytes = 1_048_576

    static func isValidResponse(from data: Data) -> Bool {
        guard data.count <= maximumResponseBytes else { return false }
        return (try? JSONDecoder().decode(NgrokEndpointResponse.self, from: data)) != nil
    }

    static func endpoints(from data: Data) -> [NgrokEndpoint]? {
        guard data.count <= maximumResponseBytes else { return nil }
        return try? JSONDecoder().decode(NgrokEndpointResponse.self, from: data).endpoints
    }

    static func hasLiveHTTPS(from data: Data) -> Bool {
        guard data.count <= maximumResponseBytes else { return false }
        guard let response = try? JSONDecoder().decode(NgrokEndpointResponse.self, from: data) else {
            return false
        }
        return response.endpoints.contains { endpoint in
            (try? RemotePublicOrigin(endpoint.url)) != nil
        }
    }

    static func reconcile(
        from data: Data,
        matching target: String
    ) -> RemoteEndpointReconciliation {
        guard data.count <= maximumResponseBytes else {
            return .invalidAgentAPIResponse
        }
        guard let response = try? JSONDecoder().decode(NgrokEndpointResponse.self, from: data) else {
            return .invalidAgentAPIResponse
        }
        return reconcile(endpoints: response.endpoints, matching: target)
    }

    static func reconcile(
        endpoints: [NgrokEndpoint],
        matching target: String
    ) -> RemoteEndpointReconciliation {
        guard !endpoints.isEmpty else {
            return .missing
        }

        let normalizedTarget = normalizedAddress(target)
        let matching = endpoints.filter { endpoint in
            normalizedAddress(endpoint.upstream.url) == normalizedTarget
        }
        guard !matching.isEmpty else {
            return .foreign
        }

        // Ambiguity is established from the complete exact-upstream match set
        // before validating public URLs. One malformed match must not make a
        // second exact match look like a unique current endpoint.
        guard matching.count == 1, let endpoint = matching.first else {
            return .ambiguous
        }
        guard let origin = try? RemotePublicOrigin(endpoint.url),
              let publicURL = URL(string: origin.value) else {
            return .invalidAgentAPIResponse
        }
        return .current(publicURL: publicURL)
    }

    static func publicURL(from data: Data, matching target: String) -> URL? {
        guard case let .current(publicURL) = reconcile(from: data, matching: target) else {
            return nil
        }
        return publicURL
    }

    private static func normalizedAddress(_ address: String) -> String {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        }
        components.scheme = components.scheme?.lowercased()
        components.host = components.host?.lowercased()
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return components.string ?? address
    }
}
