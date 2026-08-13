import Foundation

private struct NgrokEndpointResponse: Decodable {
    let endpoints: [NgrokEndpoint]
}

struct NgrokEndpoint: Decodable, Equatable, Sendable {
    let url: String
    let upstream: NgrokEndpointUpstream
}

struct NgrokEndpointUpstream: Decodable, Equatable, Sendable {
    let url: String
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
    static func isValidResponse(from data: Data) -> Bool {
        (try? JSONDecoder().decode(NgrokEndpointResponse.self, from: data)) != nil
    }

    static func endpoints(from data: Data) -> [NgrokEndpoint]? {
        try? JSONDecoder().decode(NgrokEndpointResponse.self, from: data).endpoints
    }

    static func hasLiveHTTPS(from data: Data) -> Bool {
        guard let response = try? JSONDecoder().decode(NgrokEndpointResponse.self, from: data) else {
            return false
        }
        return response.endpoints.contains { endpoint in
            guard let url = URL(string: endpoint.url) else { return false }
            return url.scheme?.lowercased() == "https" && url.host != nil
        }
    }

    static func reconcile(
        from data: Data,
        matching target: String
    ) -> RemoteEndpointReconciliation {
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

        let publicURLs = matching.compactMap { endpoint -> URL? in
            guard let url = URL(string: endpoint.url),
                  url.scheme?.lowercased() == "https",
                  url.host != nil else {
                return nil
            }
            return url
        }
        guard publicURLs.count == matching.count else {
            return .invalidAgentAPIResponse
        }
        guard publicURLs.count == 1, let publicURL = publicURLs.first else {
            return .ambiguous
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
        components.query = nil
        components.fragment = nil
        return components.string ?? address
    }
}
