import Foundation
#if canImport(CodexAppServerKit)
import CodexAppServerKit
#endif

/// Service adapter bridging the standalone `CodexAppServerKit` package to RollCode's domain models.
@MainActor
final class CodexAppServerService {
    static let shared = CodexAppServerService()
    private let client = CodexAppServerClient.shared

    typealias JSONDictionary = CodexAppServerClient.JSONDictionary

    var isReady: Bool { client.isReady }

    func startServerIfNeeded(executableURL: URL? = CodexExecutableLocator.locate()) async throws {
        try await client.startServerIfNeeded(executableURL: executableURL)
    }

    func stopServer() {
        client.stopServer()
    }

    func startThread(cwd: String, model: String?) async throws -> String {
        try await client.startThread(cwd: cwd, model: model)
    }

    func resumeThread(threadId: String, cwd: String) async throws {
        try await client.resumeThread(threadId: threadId, cwd: cwd)
    }

    func startTurn(
        threadId: String,
        prompt: String,
        model: String?,
        effort: String?,
        onDelta: @escaping (String) -> Void,
        onUsage: @escaping (AgentTokenUsage) -> Void,
        onComplete: @escaping (Bool, String?) -> Void
    ) async throws -> String {
        try await client.startTurn(
            threadId: threadId,
            prompt: prompt,
            model: model,
            effort: effort,
            onDelta: onDelta,
            onUsage: { usage in
                onUsage(AgentTokenUsage(inputTokens: usage.inputTokens, cachedTokens: usage.cachedTokens, outputTokens: usage.outputTokens))
            },
            onComplete: onComplete
        )
    }

    func interruptTurn(threadId: String, turnId: String) async throws {
        try await client.interruptTurn(threadId: threadId, turnId: turnId)
    }

    func listModels() async throws -> [AIModelInfo] {
        let models = try await client.listModels()
        return models.map { m in
            let tier: ModelSpeedTier = switch m.speedTier {
            case .fast: .fast
            case .standard: .standard
            case .deep: .deep
            }
            return AIModelInfo(
                id: m.id,
                displayName: m.displayName,
                provider: .codex,
                speedTier: tier,
                supportsReasoningEffort: m.supportsReasoningEffort
            )
        }
    }
}
