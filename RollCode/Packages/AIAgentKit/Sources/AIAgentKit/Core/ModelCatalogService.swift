import Foundation
import Observation

public enum ModelSpeedTier: String, CaseIterable, Identifiable, Sendable, Codable {
    case fast = "Fast"
    case standard = "Standard"
    case deep = "Deep Thinking"

    public var id: String { rawValue }


    public var iconName: String {
        switch self {
        case .fast: "bolt.fill"
        case .standard: "scalemass"
        case .deep: "brain.head.profile"
        }
    }

    public var badgeEmoji: String {
        switch self {
        case .fast: "⚡️"
        case .standard: "⚖️"
        case .deep: "🧠"
        }
    }
}

enum ReasoningEffort: String, CaseIterable, Identifiable, Sendable, Codable {
    case low = "low"
    case medium = "medium"
    case high = "high"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .low: "Low (Faster)"
        case .medium: "Medium (Balanced)"
        case .high: "High (Deep Thinking)"
        }
    }

    var shortName: String {
        switch self {
        case .low: "Low"
        case .medium: "Medium"
        case .high: "High"
        }
    }
}

struct AIModelInfo: Identifiable, Equatable, Sendable, Codable {
    let id: String
    let displayName: String
    let provider: AgentProvider
    let speedTier: ModelSpeedTier
    let supportsReasoningEffort: Bool
    let contextWindow: Int?
    let descriptionText: String?

    init(
        id: String,
        displayName: String,
        provider: AgentProvider,
        speedTier: ModelSpeedTier,
        supportsReasoningEffort: Bool = false,
        contextWindow: Int? = nil,
        descriptionText: String? = nil
    ) {
        self.id = id
        self.displayName = displayName
        self.provider = provider
        self.speedTier = speedTier
        self.supportsReasoningEffort = supportsReasoningEffort
        self.contextWindow = contextWindow
        self.descriptionText = descriptionText
    }
}

@Observable
@MainActor
final class ModelCatalogService {
    private(set) var codexModels: [AIModelInfo] = []
    private(set) var geminiModels: [AIModelInfo] = []
    private(set) var isRefreshing = false
    private(set) var lastRefreshedAt: Date?

    private let codexCacheURL: URL
    private let codexConfigURL: URL
    private let session: URLSession

    static let defaultCodexFallback = [
        AIModelInfo(id: "gpt-5.6-sol", displayName: "GPT-5.6-Sol", provider: .codex, speedTier: .deep, supportsReasoningEffort: true),
        AIModelInfo(id: "gpt-5.5", displayName: "GPT-5.5", provider: .codex, speedTier: .standard, supportsReasoningEffort: true),
        AIModelInfo(id: "gpt-5.4", displayName: "GPT-5.4", provider: .codex, speedTier: .standard, supportsReasoningEffort: true),
        AIModelInfo(id: "gpt-5.4-mini", displayName: "GPT-5.4-Mini", provider: .codex, speedTier: .fast, supportsReasoningEffort: true),
        AIModelInfo(id: "o3-mini", displayName: "o3-mini", provider: .codex, speedTier: .fast, supportsReasoningEffort: true),
        AIModelInfo(id: "gpt-4o", displayName: "GPT-4o", provider: .codex, speedTier: .standard, supportsReasoningEffort: false),
        AIModelInfo(id: "gpt-4o-mini", displayName: "GPT-4o-Mini", provider: .codex, speedTier: .fast, supportsReasoningEffort: false)
    ]

    static let defaultGeminiFallback = [
        AIModelInfo(id: "gemini-2.5-pro", displayName: "Gemini 2.5 Pro", provider: .gemini, speedTier: .deep, supportsReasoningEffort: false),
        AIModelInfo(id: "gemini-2.5-flash", displayName: "Gemini 2.5 Flash", provider: .gemini, speedTier: .fast, supportsReasoningEffort: false),
        AIModelInfo(id: "gemini-2.0-flash", displayName: "Gemini 2.0 Flash", provider: .gemini, speedTier: .fast, supportsReasoningEffort: false),
        AIModelInfo(id: "gemini-1.5-pro", displayName: "Gemini 1.5 Pro", provider: .gemini, speedTier: .standard, supportsReasoningEffort: false),
        AIModelInfo(id: "gemini-1.5-flash", displayName: "Gemini 1.5 Flash", provider: .gemini, speedTier: .fast, supportsReasoningEffort: false)
    ]

    init(
        codexCacheURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/models_cache.json"),
        codexConfigURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".codex/config.toml"),
        session: URLSession = .shared
    ) {
        self.codexCacheURL = codexCacheURL
        self.codexConfigURL = codexConfigURL
        self.session = session
        loadInitialCatalogs()
    }

    func models(for provider: AgentProvider) -> [AIModelInfo] {
        provider == .codex ? codexModels : geminiModels
    }

    func findModel(id: String, provider: AgentProvider) -> AIModelInfo? {
        models(for: provider).first { $0.id == id }
    }

    func defaultModelID(for provider: AgentProvider) -> String {
        switch provider {
        case .codex:
            // Check ~/.codex/config.toml
            if let configured = configuredCodexModel() {
                return configured
            }
            return codexModels.first?.id ?? "gpt-5.6-sol"
        case .gemini:
            return "gemini-2.5-pro"
        }
    }

    func loadInitialCatalogs() {
        // Load Codex from cache if available
        if let cached = loadCodexFromCache(), !cached.isEmpty {
            self.codexModels = cached
        } else {
            self.codexModels = Self.defaultCodexFallback
        }

        // Gemini initially defaults to the curated catalog
        self.geminiModels = Self.defaultGeminiFallback
    }

    func refreshModels(geminiKey: String? = nil, openAIKey: String? = nil) async {
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshedAt = Date()
        }

        // Refresh Codex models
        if let liveModels = try? await CodexAppServerService.shared.listModels(), !liveModels.isEmpty {
            self.codexModels = liveModels
        } else if let cached = loadCodexFromCache(), !cached.isEmpty {
            self.codexModels = cached
        } else if let openAIKey, !openAIKey.isEmpty {
            if let fetched = await fetchOpenAIModels(apiKey: openAIKey), !fetched.isEmpty {
                self.codexModels = fetched
            }
        }

        // Refresh Gemini models via API if key is available
        if let key = geminiKey, !key.isEmpty {
            if let fetched = await fetchGeminiModels(apiKey: key), !fetched.isEmpty {
                self.geminiModels = fetched
            }
        }
    }

    func fetchGeminiModels(apiKey: String) async -> [AIModelInfo]? {
        let trimmedKey = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedKey.isEmpty,
              let url = URL(string: "https://generativelanguage.googleapis.com/v1beta/models?key=\(trimmedKey)") else {
            return nil
        }

        do {
            let (data, response) = try await session.data(from: url)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            return Self.parseGeminiModels(data: data)
        } catch {
            return nil
        }
    }

    nonisolated static func parseGeminiModels(data: Data) -> [AIModelInfo]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["models"] as? [[String: Any]] else {
            return nil
        }

        var results: [AIModelInfo] = []
        for item in modelsArray {
            guard let rawName = item["name"] as? String else { continue }
            let methods = item["supportedGenerationMethods"] as? [String] ?? []
            guard methods.contains("generateContent") else { continue }

            let modelID = rawName.replacingOccurrences(of: "models/", with: "")
            // Filter out non-chat / embedding / deprecated test models
            if modelID.contains("embedding") || modelID.contains("aqa") || modelID.contains("imagen") {
                continue
            }

            let displayName = (item["displayName"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = (displayName?.isEmpty == false) ? displayName! : cleanGeminiDisplayName(from: modelID)
            let inputTokens = item["inputTokenLimit"] as? Int
            let description = item["description"] as? String

            let tier: ModelSpeedTier
            if modelID.contains("flash") {
                tier = .fast
            } else if modelID.contains("pro") {
                tier = .deep
            } else {
                tier = .standard
            }

            results.append(AIModelInfo(
                id: modelID,
                displayName: finalName,
                provider: .gemini,
                speedTier: tier,
                supportsReasoningEffort: false,
                contextWindow: inputTokens,
                descriptionText: description
            ))
        }

        // Sort Pro and Flash to the top
        return results.sorted { m1, m2 in
            let score1 = modelScore(m1.id)
            let score2 = modelScore(m2.id)
            if score1 != score2 { return score1 > score2 }
            return m1.id > m2.id
        }
    }

    func fetchOpenAIModels(apiKey: String) async -> [AIModelInfo]? {
        guard let url = URL(string: "https://api.openai.com/v1/models") else { return nil }
        var request = URLRequest(url: url)
        request.setValue("Bearer \(apiKey.trimmingCharacters(in: .whitespacesAndNewlines))", forHTTPHeaderField: "Authorization")

        do {
            let (data, response) = try await session.data(for: request)
            guard let httpResponse = response as? HTTPURLResponse, (200...299).contains(httpResponse.statusCode) else {
                return nil
            }
            return Self.parseOpenAIModels(data: data)
        } catch {
            return nil
        }
    }

    nonisolated static func parseOpenAIModels(data: Data) -> [AIModelInfo]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let dataArray = json["data"] as? [[String: Any]] else {
            return nil
        }

        var results: [AIModelInfo] = []
        for item in dataArray {
            guard let id = item["id"] as? String else { continue }
            // Filter relevant code/chat models
            if !(id.hasPrefix("gpt-") || id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("o4") || id.hasPrefix("codex")) {
                continue
            }
            if id.contains("instruct") || id.contains("audio") || id.contains("realtime") || id.contains("embedding") || id.contains("moderation") {
                continue
            }

            let tier: ModelSpeedTier
            if id.contains("mini") || id.contains("flash") {
                tier = .fast
            } else if id.hasPrefix("o1") || id.hasPrefix("o3") || id.contains("sol") || id.contains("terra") {
                tier = .deep
            } else {
                tier = .standard
            }

            let reasoning = id.hasPrefix("o1") || id.hasPrefix("o3") || id.hasPrefix("gpt-5")
            results.append(AIModelInfo(
                id: id,
                displayName: id,
                provider: .codex,
                speedTier: tier,
                supportsReasoningEffort: reasoning
            ))
        }

        return results.sorted { $0.id > $1.id }
    }

    private func loadCodexFromCache() -> [AIModelInfo]? {
        guard FileManager.default.fileExists(atPath: codexCacheURL.path),
              let data = try? Data(contentsOf: codexCacheURL) else {
            return nil
        }
        return Self.parseCodexCache(data: data)
    }

    nonisolated static func parseCodexCache(data: Data) -> [AIModelInfo]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let modelsArray = json["models"] as? [[String: Any]] else {
            return nil
        }

        var results: [AIModelInfo] = []
        for item in modelsArray {
            guard let slug = item["slug"] as? String, !slug.isEmpty else { continue }
            let displayName = item["display_name"] as? String ?? slug
            let supportedEfforts = item["supported_reasoning_efforts"] as? [String]
            let supportsReasoning = (supportedEfforts != nil && !supportedEfforts!.isEmpty) || slug.hasPrefix("o") || slug.hasPrefix("gpt-5")

            let tier: ModelSpeedTier
            if slug.contains("mini") {
                tier = .fast
            } else if supportsReasoning || slug.contains("sol") || slug.hasPrefix("o1") || slug.hasPrefix("o3") {
                tier = .deep
            } else {
                tier = .standard
            }

            let description = item["description"] as? String

            results.append(AIModelInfo(
                id: slug,
                displayName: displayName,
                provider: .codex,
                speedTier: tier,
                supportsReasoningEffort: supportsReasoning,
                descriptionText: description
            ))
        }

        return results.isEmpty ? nil : results
    }

    private func configuredCodexModel() -> String? {
        guard FileManager.default.fileExists(atPath: codexConfigURL.path),
              let content = try? String(contentsOf: codexConfigURL, encoding: .utf8) else {
            return nil
        }
        // Match line `model = "..."`
        for line in content.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("model =") {
                let parts = trimmed.split(separator: "=")
                if parts.count >= 2 {
                    let val = parts[1].trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                    if !val.isEmpty { return val }
                }
            }
        }
        return nil
    }

    nonisolated static func cleanGeminiDisplayName(from id: String) -> String {
        let parts = id.split(separator: "-").map { $0.capitalized }
        return parts.joined(separator: " ")
    }

    nonisolated static func modelScore(_ id: String) -> Int {
        if id.contains("2.5-pro") { return 100 }
        if id.contains("2.5-flash") { return 90 }
        if id.contains("2.0-flash") { return 80 }
        if id.contains("1.5-pro") { return 70 }
        if id.contains("1.5-flash") { return 60 }
        return 10
    }
}
