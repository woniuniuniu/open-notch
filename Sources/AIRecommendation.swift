import Foundation

enum AIRequestPhase: Equatable {
    case preparing
    case analyzing
    case finalizing

    var title: String {
        switch self {
        case .preparing: L("Preparing the latest scan")
        case .analyzing: L("AI is analyzing the menu bar")
        case .finalizing: L("Validating the generated layouts")
        }
    }
}

struct AIRecommendationItem: Codable, Equatable, Identifiable {
    let id: String
    let disposition: ItemDisposition
    let confidence: Double
    let reason: String
}

struct AIRecommendationPlan: Codable, Equatable, Identifiable {
    let id: String
    let title: String
    let summary: String
    let items: [AIRecommendationItem]
}

struct AIItemDescription: Codable, Equatable, Identifiable {
    let id: String
    let description: String
}

struct AIRecommendation: Codable, Equatable {
    let recommendedPlanID: String
    let plans: [AIRecommendationPlan]
    let descriptions: [AIItemDescription]
    let generatedAt: Date

    var recommendedPlan: AIRecommendationPlan? {
        plans.first { $0.id == recommendedPlanID } ?? plans.first
    }
}

private struct AIRecommendationRequest: Encodable {
    struct Item: Encodable {
        let id: String
        let name: String
        let bundleIdentifier: String
        let currentDisposition: String
        let isOneDrive: Bool
    }

    let installationID: String
    let locale: String
    let timeZoneOffsetMinutes: Int
    let appVersion: String
    let items: [Item]
}

private struct AIRecommendationResponse: Decodable {
    let recommendedPlanID: String
    let plans: [AIRecommendationPlan]
    let descriptions: [AIItemDescription]?
    let generatedAt: String?
    let retryAfterSeconds: Int?
    let error: String?
}

enum AIRecommendationError: LocalizedError {
    case unavailable
    case noItems
    case dailyLimit(Date)
    case server(String)
    case invalidResponse

    var errorDescription: String? {
        switch self {
        case .unavailable: return L("AI service is not configured")
        case .noItems: return L("No menu bar items are available for AI analysis")
        case let .dailyLimit(date):
            let seconds = max(0, Int(ceil(date.timeIntervalSinceNow)))
            let hours = seconds / 3_600
            let minutes = (seconds % 3_600 + 59) / 60
            if hours > 0 {
                return LF("Available again in %d hours %d minutes", hours, minutes)
            }
            return LF("Available again in %d minutes", max(1, minutes))
        case let .server(message): return message
        case .invalidResponse: return L("The AI service returned an invalid recommendation")
        }
    }
}

actor AIRecommendationService {
    static let shared = AIRecommendationService()

    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }()

    private let decoder = JSONDecoder()

    func request(
        items: [MenuBarItem],
        dispositions: [String: ItemDisposition],
        language: AppLanguage,
        installationID: String
    ) async throws -> AIRecommendation {
        guard !items.isEmpty else { throw AIRecommendationError.noItems }
        guard let endpoint = endpointURL else { throw AIRecommendationError.unavailable }

        let mappedItems = Array(items.prefix(80)).enumerated().map { index, item in
            AIRecommendationRequest.Item(
                id: "item-\(index)",
                name: String(item.displayName.prefix(100)),
                bundleIdentifier: String(item.semanticBundleIdentifier.prefix(180)),
                currentDisposition: (dispositions[item.id] ?? .visible).rawValue,
                isOneDrive: item.isOneDrive
            )
        }
        let requestBody = AIRecommendationRequest(
            installationID: installationID,
            locale: language.localeIdentifier,
            timeZoneOffsetMinutes: TimeZone.current.secondsFromGMT() / 60,
            appVersion: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown",
            items: mappedItems
        )

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = 45
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("OpenNotch/\(requestBody.appVersion)", forHTTPHeaderField: "User-Agent")
        request.httpBody = try encoder.encode(requestBody)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw AIRecommendationError.invalidResponse }
        let decoded = try? decoder.decode(AIRecommendationResponse.self, from: data)

        if http.statusCode == 429 {
            let seconds = decoded?.retryAfterSeconds ?? 86_400
            throw AIRecommendationError.dailyLimit(Date.now.addingTimeInterval(TimeInterval(seconds)))
        }
        guard (200...299).contains(http.statusCode) else {
            throw AIRecommendationError.server(decoded?.error ?? L("AI recommendation request failed"))
        }
        guard let decoded, decoded.plans.count >= 2 else { throw AIRecommendationError.invalidResponse }

        let allowedIDs = Set(mappedItems.map(\.id))
        let sanitizedPlans = decoded.plans.prefix(3).map { plan in
            AIRecommendationPlan(
                id: String(plan.id.prefix(40)),
                title: String(plan.title.prefix(60)),
                summary: String(plan.summary.prefix(240)),
                items: plan.items.filter { allowedIDs.contains($0.id) }.map {
                    AIRecommendationItem(
                        id: $0.id,
                        disposition: $0.disposition,
                        confidence: min(max($0.confidence, 0), 1),
                        reason: String($0.reason.prefix(180))
                    )
                }
            )
        }
        guard sanitizedPlans.allSatisfy({ !$0.items.isEmpty }) else { throw AIRecommendationError.invalidResponse }
        let sanitizedDescriptions: [AIItemDescription] = (decoded.descriptions ?? [])
            .filter { allowedIDs.contains($0.id) }
            .compactMap { itemDescription -> AIItemDescription? in
            let description = String(itemDescription.description.trimmingCharacters(in: .whitespacesAndNewlines).prefix(80))
            guard !description.isEmpty else { return nil }
            return AIItemDescription(id: itemDescription.id, description: description)
        }

        return AIRecommendation(
            recommendedPlanID: decoded.recommendedPlanID,
            plans: sanitizedPlans,
            descriptions: sanitizedDescriptions,
            generatedAt: ISO8601DateFormatter().date(from: decoded.generatedAt ?? "") ?? .now
        )
    }

    private var endpointURL: URL? {
        guard
            let value = Bundle.main.object(forInfoDictionaryKey: "OpenNotchAIEndpoint") as? String,
            value.hasPrefix("https://")
        else { return nil }
        return URL(string: value)
    }
}
