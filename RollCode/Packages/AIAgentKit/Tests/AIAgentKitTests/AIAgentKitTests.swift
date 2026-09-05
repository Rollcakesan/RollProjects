import Foundation
import Testing
@testable import AIAgentKit

@Suite("AIAgentKit Test Suite")
struct AIAgentKitTests {
    @Test("CodexEventParser reads thread started, messages, command execution, and file changes")
    func codexEventParserReadsThreadMessagesCommandsAndChanges() throws {
        let thread = try #require(CodexEventParser.parse(
            #"{"type":"thread.started","thread_id":"thread-123"}"#
        ))
        #expect(thread == .threadStarted("thread-123"))

        let message = try #require(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"Done"}}"#
        ))
        #expect(message == .message("Done"))

        let command = try #require(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"item-2","type":"command_execution","command":"swift test","aggregated_output":"ok","exit_code":0,"status":"completed"}}"#
        ))
        guard case .activity(let commandActivity, let commandFiles) = command else {
            Issue.record("Expected a command activity")
            return
        }
        #expect(commandActivity.title == "swift test")
        #expect(commandActivity.detail == "ok")
        #expect(commandActivity.state == .completed)
        #expect(commandFiles == [])

        let change = try #require(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"item-3","type":"file_change","changes":[{"path":"/tmp/App.swift","kind":"update"}],"status":"completed"}}"#
        ))
        guard case .activity(let changeActivity, let changedFiles) = change else {
            Issue.record("Expected a file change activity")
            return
        }
        #expect(changedFiles == ["/tmp/App.swift"])
        #expect(changeActivity.state == .completed)
    }

    @Test("CodexEventParser reads usage tokens and failure events")
    func codexEventParserReadsUsageAndFailures() throws {
        let completed = try #require(CodexEventParser.parse(
            #"{"type":"turn.completed","usage":{"input_tokens":20,"cached_input_tokens":10,"output_tokens":5}}"#
        ))
        #expect(completed == .usage("20 input · 10 cached · 5 output"))

        let failed = try #require(CodexEventParser.parse(
            #"{"type":"turn.failed","error":{"message":"Authentication required"}}"#
        ))
        #expect(failed == .error("Authentication required"))
    }

    @Test("CodexAuthService parses ChatGPT login mode and credentials")
    @MainActor
    func codexAuthServiceParsesChatGPTLogin() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let authFile = root.appending(path: "auth.json")
        let payload = """
        {"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20iLCJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9wbGFuX3R5cGUiOiJwbHVzIn19.signature","access_token":"mock"}}
        """
        try payload.write(to: authFile, atomically: true, encoding: .utf8)

        let service = CodexAuthService(authFileURL: authFile, isCLIAvailable: { true })
        #expect(service.status == .loggedIn(mode: "ChatGPT", email: "test@example.com", plan: "plus"))
        #expect(service.status.displayText == "test@example.com (Plus)")
    }

    @Test("AgentSession supports multiple threads and switching")
    @MainActor
    func agentSessionSupportsMultipleThreads() throws {
        let session = AgentSession(executableURL: nil)
        #expect(session.entries.isEmpty)
        #expect(session.threads.isEmpty)

        session.entries = [.message(AgentMessage(role: .user, text: "First question"))]
        let firstThreadID = session.activeThread.id

        session.newThread()
        #expect(session.entries.isEmpty)
        #expect(session.threads.count == 1)
        #expect(session.threads.first?.id == firstThreadID)

        session.entries = [.message(AgentMessage(role: .user, text: "Second question"))]

        let firstThread = session.threads.first!
        session.switchToThread(firstThread)
        #expect(session.activeThread.id == firstThreadID)
        #expect(session.entries.count == 1)
        #expect(session.threads.count == 2)
    }

    @Test("AgentTokenUsage parses token descriptions accurately")
    func agentTokenUsageParsesDescriptions() throws {
        let usage1 = try #require(AgentTokenUsage.parse(from: "20 input · 10 cached · 5 output"))
        #expect(usage1.inputTokens == 20)
        #expect(usage1.cachedTokens == 10)
        #expect(usage1.outputTokens == 5)
        #expect(usage1.totalTokens == 25)

        let usage2 = AgentTokenUsage.parse(from: "invalid string")
        #expect(usage2 == nil)
    }

    @Test("CodexAppServerClient JSONDictionary subscript and Sendable safety")
    @MainActor
    func codexAppServerServiceJSONDictionary() {
        let dict = CodexAppServerClient.JSONDictionary([
            "status": "ok",
            "count": 42,
            "nested": ["name": "gpt-5.6-sol"]
        ])
        #expect(dict["status"] as? String == "ok")
        #expect(dict["count"] as? Int == 42)
        #expect((dict["nested"] as? [String: Any])?["name"] as? String == "gpt-5.6-sol")
    }

    @Test("GeminiAuthService reads and returns unexpired OAuth access token")
    @MainActor
    func geminiAuthServiceReturnsValidOAuthToken() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let credsURL = root.appending(path: "oauth_creds.json")
        let futureExpiry = (Date().timeIntervalSince1970 + 3600) * 1000
        let payload = """
        {
          "access_token": "mock-access-token-123",
          "refresh_token": "mock-refresh-token",
          "expiry_date": \(futureExpiry)
        }
        """
        try payload.write(to: credsURL, atomically: true, encoding: .utf8)

        let service = GeminiAuthService(geminiDirURL: root, isCLIAvailable: { true })
        let token = await service.validOAuthAccessToken()
        #expect(token == "mock-access-token-123")
    }

    @Test("ModelCatalogService parses Vertex AI Gemini models and sorts latest model highest")
    @MainActor
    func modelCatalogServiceVertexGeminiParsing() throws {
        let json = """
        {
          "publisherModels": [
            { "name": "publishers/google/models/gemini-2.5-flash" },
            { "name": "publishers/google/models/gemini-3.8-flash" },
            { "name": "publishers/google/models/gemini-3.1-pro-preview" },
            { "name": "publishers/google/models/gemini-embedding-001" }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try #require(ModelCatalogService.parseVertexGeminiModels(data: json))
        #expect(parsed.count == 3)
        #expect(parsed[0].id == "gemini-3.8-flash")
        #expect(parsed[0].speedTier == .fast)
        #expect(parsed[1].id == "gemini-3.1-pro-preview")
        #expect(parsed[1].speedTier == .deep)
        #expect(parsed[2].id == "gemini-2.5-flash")
        #expect(parsed[2].speedTier == .fast)
    }
}
