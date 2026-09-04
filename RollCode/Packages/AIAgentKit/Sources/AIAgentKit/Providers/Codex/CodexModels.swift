import Foundation

/// Token consumption metrics for an agent turn or thread (typealias to AgentTokenUsage).
public typealias CodexTokenUsage = AgentTokenUsage

/// Speed and reasoning tier of an AI model (typealias to ModelSpeedTier).
public typealias CodexModelSpeedTier = ModelSpeedTier


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
