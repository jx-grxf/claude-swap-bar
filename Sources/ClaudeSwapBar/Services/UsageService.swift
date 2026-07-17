import Foundation

/// Fetches rate-limit usage from Anthropic's OAuth usage endpoint.
///
/// The endpoint enforces roughly 28–30 requests per hour per access token, so
/// callers must cache results (AppState keeps snapshots and only refetches
/// stale ones) and back off hard on 429.
struct UsageService {

    static let usageURL = URL(string: "https://api.anthropic.com/api/oauth/usage")!
    static let betaHeader = "oauth-2025-04-20"

    enum UsageError: Error {
        case unauthorized
        case rateLimited(retryAfter: TimeInterval?)
        case network(String)

        var asProblem: UsageProblem {
            switch self {
            case .unauthorized:
                return .unauthorized
            case let .rateLimited(retryAfter):
                return .rateLimited(retryAt: retryAfter.map { Date().addingTimeInterval($0) })
            case let .network(message):
                return .network(message)
            }
        }
    }

    func fetchUsage(accessToken: String) async throws -> UsageSnapshot {
        var request = URLRequest(url: Self.usageURL)
        request.setValue("Bearer \(accessToken)", forHTTPHeaderField: "Authorization")
        request.setValue(Self.betaHeader, forHTTPHeaderField: "anthropic-beta")
        request.timeoutInterval = 10

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw UsageError.network(error.localizedDescription)
        }

        guard let http = response as? HTTPURLResponse else {
            throw UsageError.network("no HTTP response")
        }
        switch http.statusCode {
        case 200:
            break
        case 401, 403:
            throw UsageError.unauthorized
        case 429:
            let retryAfter = http.value(forHTTPHeaderField: "Retry-After").flatMap(TimeInterval.init)
            throw UsageError.rateLimited(retryAfter: retryAfter)
        default:
            throw UsageError.network("HTTP \(http.statusCode)")
        }

        struct Payload: Decodable {
            struct Window: Decodable {
                let utilization: Double?
                let resetsAt: String?

                enum CodingKeys: String, CodingKey {
                    case utilization
                    case resetsAt = "resets_at"
                }
            }
            struct Limit: Decodable {
                struct Scope: Decodable {
                    struct Model: Decodable { let displayName: String?
                        enum CodingKeys: String, CodingKey { case displayName = "display_name" }
                    }
                    let model: Model?
                }
                let scope: Scope?
                let percent: Double?
                let resetsAt: String?

                enum CodingKeys: String, CodingKey {
                    case scope, percent
                    case resetsAt = "resets_at"
                }
            }
            let fiveHour: Window?
            let sevenDay: Window?
            let limits: [Limit]?

            enum CodingKeys: String, CodingKey {
                case fiveHour = "five_hour"
                case sevenDay = "seven_day"
                case limits
            }
        }

        let payload: Payload
        do {
            payload = try JSONDecoder().decode(Payload.self, from: data)
        } catch {
            throw UsageError.network("unexpected usage response")
        }

        func window(_ raw: Payload.Window?) -> UsageWindow? {
            guard let raw, let utilization = raw.utilization else { return nil }
            return UsageWindow(utilization: utilization, resetsAt: raw.resetsAt.flatMap(Self.parseDate))
        }

        let scoped: [ScopedUsage] = (payload.limits ?? []).compactMap { limit in
            guard let name = limit.scope?.model?.displayName, let percent = limit.percent else { return nil }
            return ScopedUsage(
                name: name,
                window: UsageWindow(utilization: percent, resetsAt: limit.resetsAt.flatMap(Self.parseDate))
            )
        }

        return UsageSnapshot(
            fiveHour: window(payload.fiveHour),
            sevenDay: window(payload.sevenDay),
            scoped: scoped,
            fetchedAt: Date()
        )
    }

    private static func parseDate(_ string: String) -> Date? {
        let withFractional = ISO8601DateFormatter()
        withFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFractional.date(from: string) { return date }
        let plain = ISO8601DateFormatter()
        return plain.date(from: string)
    }
}
