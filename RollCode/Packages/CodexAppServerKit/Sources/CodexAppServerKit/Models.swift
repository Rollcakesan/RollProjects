import Foundation

/// Token consumption metrics for an agent turn or thread.
public struct CodexTokenUsage: Equatable, Sendable, Codable {
    public var inputTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int

    public var totalTokens: Int {
        inputTokens + outputTokens
    }

    public init(inputTokens: Int = 0, cachedTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
    }

    /// Formatted short description (e.g. "1.2k tok").
    public var formattedTotal: String {
        if totalTokens >= 1_000_000 {
            return String(format: "%.1fM tok", Double(totalTokens) / 1_000_000.0)
        } else if totalTokens >= 1_000 {
            return String(format: "%.1fk tok", Double(totalTokens) / 1_000.0)
        } else {
            return "\(totalTokens) tok"
        }
    }
}

/// Speed and reasoning tier of an AI model.
public enum CodexModelSpeedTier: String, CaseIterable, Sendable, Codable {
    case fast = "Fast"
    case standard = "Standard"
    case deep = "Deep Thinking"

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

/// Metadata describing a model available on the Codex App Server.
public struct CodexAppServerModel: Identifiable, Equatable, Sendable, Codable {
    public let id: String
    public let displayName: String
    public let speedTier: CodexModelSpeedTier
    public let supportsReasoningEffort: Bool

    public init(
        id: String,
        displayName: String,
        speedTier: CodexModelSpeedTier,
        supportsReasoningEffort: Bool = false
    ) {
        self.id = id
        self.displayName = displayName
        self.speedTier = speedTier
        self.supportsReasoningEffort = supportsReasoningEffort
    }
}

/// Connection and execution lifecycle status of the Codex App Server daemon.
public enum CodexServerStatus: Equatable, Sendable {
    case stopped
    case starting
    case ready
    case failed(String)
}

/// Helper for finding the `codex` command line binary on macOS.
public enum CodexExecutableLocator {
    public static func locate(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        var candidates = [
            "/Applications/ChatGPT.app/Contents/Resources/codex",
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex"
        ]
        if let path = environment["PATH"] {
            candidates += path.split(separator: ":").map { "\($0)/codex" }
        }

        for path in candidates {
            let standardized = URL(fileURLWithPath: path).standardizedFileURL
            if FileManager.default.isExecutableFile(atPath: standardized.path) {
                return standardized
            }
        }
        return nil
    }
}
