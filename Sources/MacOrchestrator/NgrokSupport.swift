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

enum NgrokEndpointParser {
    static func publicURL(from data: Data, matching target: String) -> URL? {
        guard let response = try? JSONDecoder().decode(NgrokEndpointResponse.self, from: data),
              let endpoint = response.endpoints.first(where: {
                  normalizedAddress($0.upstream.url) == normalizedAddress(target)
              }),
              let url = URL(string: endpoint.url),
              url.scheme?.lowercased() == "https",
              url.host != nil else {
            return nil
        }
        return url
    }

    private static func normalizedAddress(_ address: String) -> String {
        guard var components = URLComponents(string: address.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            return address.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(
                in: CharacterSet(charactersIn: "/")
            )
        }
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        components.query = nil
        components.fragment = nil
        return components.string ?? address
    }
}
