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
    private let geminiCacheURL: URL
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
        geminiCacheURL: URL = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".gemini/models_cache.json"),
        session: URLSession = .shared
    ) {
        self.codexCacheURL = codexCacheURL
        self.codexConfigURL = codexConfigURL
        self.geminiCacheURL = geminiCacheURL
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
            if let configured = configuredCodexModel() { return configured }
            return codexModels.first?.id ?? "gpt-5.6-sol"
        case .gemini:
            return geminiModels.first?.id ?? "gemini-3.8-flash"
        }
    }

    func loadInitialCatalogs() {
        self.codexModels = loadCodexFromCache() ?? Self.defaultCodexFallback
        self.geminiModels = Self.defaultGeminiFallback
    }

    func refreshModels(geminiKey: String? = nil, geminiOAuthToken: String? = nil, openAIKey: String? = nil) async {
        isRefreshing = true
        defer {
            isRefreshing = false
            lastRefreshedAt = Date()
        }

        if let liveModels = try? await CodexAppServerClient.shared.listModels(), !liveModels.isEmpty {
            self.codexModels = liveModels.map { m in
                AIModelInfo(
                    id: m.id,
                    displayName: m.displayName,
                    provider: .codex,
                    speedTier: m.speedTier,
                    supportsReasoningEffort: m.supportsReasoningEffort
                )
            }
        } else if let cached = loadCodexFromCache(), !cached.isEmpty {
            self.codexModels = cached
        }
    }

    // MARK: - Decodable DTOs
    private struct GeminiCatalogResponse: Decodable {
        struct ModelItem: Decodable {
            let name: String
            let displayName: String?
            let supportedGenerationMethods: [String]?
            let inputTokenLimit: Int?
            let description: String?
        }
        let models: [ModelItem]
    }

    private struct VertexCatalogResponse: Decodable {
        struct PublisherModel: Decodable {
            let name: String
        }
        let publisherModels: [PublisherModel]
    }

    private struct CodexCacheResponse: Decodable {
        struct CodexModelItem: Decodable {
            let slug: String
            let displayName: String?
            let supportedReasoningEfforts: [String]?
            let description: String?

            enum CodingKeys: String, CodingKey {
                case slug
                case displayName = "display_name"
                case supportedReasoningEfforts = "supported_reasoning_efforts"
                case description
            }
        }
        let models: [CodexModelItem]
    }

    nonisolated static func parseGeminiModels(data: Data) -> [AIModelInfo]? {
        guard let response = try? JSONDecoder().decode(GeminiCatalogResponse.self, from: data) else { return nil }

        var results: [AIModelInfo] = []
        for item in response.models {
            let methods = item.supportedGenerationMethods ?? []
            guard methods.contains("generateContent") else { continue }

            let modelID = item.name.replacingOccurrences(of: "models/", with: "")
            if modelID.contains("embedding") || modelID.contains("aqa") || modelID.contains("imagen") {
                continue
            }

            let displayName = item.displayName?.trimmingCharacters(in: .whitespacesAndNewlines)
            let finalName = (displayName?.isEmpty == false) ? displayName! : cleanGeminiDisplayName(from: modelID)
            let tier: ModelSpeedTier = modelID.contains("flash") ? .fast : (modelID.contains("pro") ? .deep : .standard)

            results.append(AIModelInfo(
                id: modelID,
                displayName: finalName,
                provider: .gemini,
                speedTier: tier,
                supportsReasoningEffort: false,
                contextWindow: item.inputTokenLimit,
                descriptionText: item.description
            ))
        }

        return results.sorted { m1, m2 in
            let score1 = modelScore(m1.id)
            let score2 = modelScore(m2.id)
            return score1 != score2 ? score1 > score2 : m1.id > m2.id
        }
    }

    nonisolated static func parseVertexGeminiModels(data: Data) -> [AIModelInfo]? {
        guard let response = try? JSONDecoder().decode(VertexCatalogResponse.self, from: data) else { return nil }

        var results: [AIModelInfo] = []
        for item in response.publisherModels where item.name.contains("gemini") {
            let modelID = item.name.replacingOccurrences(of: "publishers/google/models/", with: "")
            if modelID.contains("embedding") || modelID.contains("tts") || modelID.contains("robotics") ||
               modelID.contains("transcribe") || modelID.contains("translate") || modelID.contains("computer-use") ||
               modelID.contains("image") || modelID.contains("audio") { continue }

            let tier: ModelSpeedTier = modelID.contains("flash") ? .fast : (modelID.contains("pro") ? .deep : .standard)
            results.append(AIModelInfo(
                id: modelID,
                displayName: cleanGeminiDisplayName(from: modelID),
                provider: .gemini,
                speedTier: tier,
                supportsReasoningEffort: false
            ))
        }

        guard !results.isEmpty else { return nil }
        return results.sorted { m1, m2 in
            let score1 = modelScore(m1.id)
            let score2 = modelScore(m2.id)
            return score1 != score2 ? score1 > score2 : m1.id > m2.id
        }
    }

    private func loadCodexFromCache() -> [AIModelInfo]? {
        guard FileManager.default.fileExists(atPath: codexCacheURL.path),
              let data = try? Data(contentsOf: codexCacheURL) else { return nil }
        return Self.parseCodexCache(data: data)
    }

    nonisolated static func parseCodexCache(data: Data) -> [AIModelInfo]? {
        guard let response = try? JSONDecoder().decode(CodexCacheResponse.self, from: data) else { return nil }

        var results: [AIModelInfo] = []
        for item in response.models where !item.slug.isEmpty {
            let slug = item.slug
            let displayName = item.displayName ?? slug
            let supportedEfforts = item.supportedReasoningEfforts
            let supportsReasoning = (supportedEfforts != nil && !supportedEfforts!.isEmpty) || slug.hasPrefix("o") || slug.hasPrefix("gpt-5")
            let tier: ModelSpeedTier = slug.contains("mini") ? .fast : ((supportsReasoning || slug.contains("sol") || slug.hasPrefix("o1") || slug.hasPrefix("o3")) ? .deep : .standard)

            results.append(AIModelInfo(
                id: slug,
                displayName: displayName,
                provider: .codex,
                speedTier: tier,
                supportsReasoningEffort: supportsReasoning,
                descriptionText: item.description
            ))
        }
        return results.isEmpty ? nil : results
    }

    private func configuredCodexModel() -> String? {
        guard FileManager.default.fileExists(atPath: codexConfigURL.path),
              let content = try? String(contentsOf: codexConfigURL, encoding: .utf8) else { return nil }
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
        var vScore = 0
        if let regex = try? NSRegularExpression(pattern: #"gemini-(\d+)(?:\.(\d+))?"#),
           let match = regex.firstMatch(in: id, range: NSRange(id.startIndex..., in: id)) {
            if let majorRange = Range(match.range(at: 1), in: id), let major = Int(id[majorRange]) {
                vScore = major * 100
            }
            if match.numberOfRanges > 2, let minorRange = Range(match.range(at: 2), in: id), let minor = Int(id[minorRange]) {
                vScore += minor * 10
            }
        }
        var tierScore = 2
        if id.contains("pro") {
            tierScore = 5
        } else if id.contains("flash") && !id.contains("lite") {
            tierScore = 4
        } else if id.contains("flash-lite") {
            tierScore = 3
        }

        if id.contains("preview") {
            vScore = max(0, vScore - 1)
        }

        return vScore * 10 + tierScore
    }
}
