import Foundation

/// Token refresh against Anthropic's OAuth endpoint. Uses the same client id
/// and semantics as Claude Code itself.
struct OAuthService {

    static let tokenURL = URL(string: "https://platform.claude.com/v1/oauth/token")!
    static let clientID = "9d1c250a-e61b-44d9-88ed-5944d1962f5e"

    enum RefreshError: LocalizedError {
        /// The refresh token lineage is dead — the account must be re-added.
        case invalidGrant
        case transient(String)

        var errorDescription: String? {
            switch self {
            case .invalidGrant:
                return "Session expired for good — log in with Claude Code and re-add the account."
            case let .transient(message):
                return "Token refresh failed: \(message)"
            }
        }
    }

    func refresh(_ credentials: OAuthCredentials) async throws -> OAuthCredentials {
        var request = URLRequest(url: Self.tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 15

        let body: [String: String] = [
            "grant_type": "refresh_token",
            "refresh_token": credentials.refreshToken,
            "client_id": Self.clientID,
        ]
        request.httpBody = try JSONSerialization.data(withJSONObject: body)

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw RefreshError.transient(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw RefreshError.transient("no HTTP response")
        }

        guard http.statusCode == 200 else {
            let bodyText = String(decoding: data, as: UTF8.self)
            // Only a definitive invalid_grant/invalid_client kills the lineage;
            // everything else is retryable.
            if [400, 401, 403].contains(http.statusCode),
               bodyText.contains("invalid_grant") || bodyText.contains("invalid_client") {
                throw RefreshError.invalidGrant
            }
            throw RefreshError.transient("HTTP \(http.statusCode)")
        }

        struct TokenResponse: Decodable {
            let accessToken: String
            let expiresIn: Double
            let refreshToken: String?
            let scope: String?

            enum CodingKeys: String, CodingKey {
                case accessToken = "access_token"
                case expiresIn = "expires_in"
                case refreshToken = "refresh_token"
                case scope
            }
        }

        let token: TokenResponse
        do {
            token = try JSONDecoder().decode(TokenResponse.self, from: data)
        } catch {
            throw RefreshError.transient("unexpected token response")
        }

        var updated = credentials
        updated.accessToken = token.accessToken
        updated.expiresAt = (Date().timeIntervalSince1970 + token.expiresIn) * 1000
        if let rotated = token.refreshToken {
            updated.refreshToken = rotated
        }
        if let scope = token.scope {
            updated.scopes = scope.split(separator: " ").map(String.init)
        }
        return updated
    }
}
