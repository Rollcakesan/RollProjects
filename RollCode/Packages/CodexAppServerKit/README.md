# CodexAppServerKit

[![Swift 6.0](https://img.shields.io/badge/Swift-6.0-orange.svg)](https://swift.org)
[![macOS 14.0+](https://img.shields.io/badge/macOS-14.0+-blue.svg)](https://apple.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-green.svg)](LICENSE)

A lightweight, zero-dependency, pure-Swift client library for communicating with OpenAI's **Codex App Server** daemon (`codex app-server --stdio`) via **JSON-RPC 2.0**.

Designed for macOS IDEs, custom developer tools, menu bar apps, and autonomous coding agents that require ultra-low latency, persistent thread management, and token-by-token streaming.

---

## 🌟 Why CodexAppServerKit?

Prior to Codex App Server, integrating Codex into custom editors required executing `codex exec` as a subprocess for every message. This introduced a **~1.0 to 1.5-second cold-start penalty** (runtime initialization, environment checks, token validation) on every user turn.

`CodexAppServerKit` connects to `codex app-server --stdio` as a persistent background daemon:
- **Instant Response (< 50ms)**: Eliminates process startup overhead entirely.
- **Full-Duplex JSON-RPC 2.0**: Bidirectional event notifications, streaming text deltas, and tool approvals.
- **Automatic Tool Approvals**: Seamlessly handles server requests (file modifications, command executions) without blocking.
- **Live Model Catalog**: Queries live available models, reasoning support (`ReasoningEffort`), and latency tiers directly from Codex.
- **Zero External Dependencies**: Pure Swift utilizing macOS `Foundation` and `Process`.
- **Swift 6 Concurrency Ready**: Full thread safety, MainActor isolation, and `@Sendable` compliance.

---

## 📐 Architecture

```text
┌─────────────────────────────────────────────────────────────┐
│                    Your macOS App / IDE                     │
│               (e.g., RollCode, Menu Bar Tool)               │
└──────────────────────────────┬──────────────────────────────┘
                               │ Swift Async/Await
┌──────────────────────────────▼──────────────────────────────┐
│                     CodexAppServerClient                    │
│   - JSON-RPC 2.0 Dispatcher (Requests, Responses, Notifs)   │
│   - Thread & Turn Lifecycles                                │
│   - Token Usage Accumulator                                 │
└──────────────────────────────┬──────────────────────────────┘
                               │ Standard I/O (Pipes)
┌──────────────────────────────▼──────────────────────────────┐
│                 codex app-server --stdio                    │
│           (OpenAI Codex Background Daemon)                  │
└─────────────────────────────────────────────────────────────┘
```

---

## 📦 Installation

Add `CodexAppServerKit` to your `Package.swift` dependencies:

```swift
dependencies: [
    .package(url: "https://github.com/Rollcakesan/RollProjects.git", branch: "main") // or local path
],
targets: [
    .target(
        name: "YourApp",
        dependencies: ["CodexAppServerKit"]
    )
]
```

Or in Xcode: **File > Add Package Dependencies...** and specify the local or remote URL.

---

## 🚀 Quickstart

```swift
import CodexAppServerKit

@MainActor
func runAgent() async throws {
    let client = CodexAppServerClient.shared

    // 1. Initialize daemon connection (auto-locates codex in /opt/homebrew or PATH)
    try await client.startServerIfNeeded()

    // 2. Start a persistent thread in your workspace
    let threadId = try await client.startThread(
        cwd: "/path/to/my-project",
        model: "gpt-5.4-mini"
    )

    // 3. Start a turn with live text streaming and token updates
    let turnId = try await client.startTurn(
        threadId: threadId,
        prompt: "Write a Swift function to parse JSON safely.",
        model: "gpt-5.4-mini",
        effort: "medium",
        onDelta: { delta in
            // Called token-by-token in real-time
            print(delta, terminator: "")
        },
        onUsage: { usage in
            // Called when token usage updates
            print("\n[Tokens] \(usage.totalTokens) used (\(usage.cachedTokens) cached)")
        },
        onComplete: { success, error in
            if success {
                print("\nTurn finished successfully!")
            } else if let error {
                print("\nTurn failed with error: \(error)")
            }
        }
    )
}
```

---

## 📚 API Reference

### `CodexAppServerClient`

| Method | Description |
| :--- | :--- |
| `startServerIfNeeded(executableURL:) async throws` | Spawns `codex app-server --stdio` and executes the `initialize` handshake. |
| `stopServer()` | Gracefully terminates the background daemon and releases pipes. |
| `startThread(cwd:model:) async throws -> String` | Creates a new Codex thread in the specified working directory. Returns `threadId`. |
| `resumeThread(threadId:cwd:) async throws` | Resumes an existing conversation thread. |
| `startTurn(...) async throws -> String` | Starts an agent turn with streaming delta and token usage callbacks. |
| `interruptTurn(threadId:turnId:) async throws` | Interrupts an in-flight turn immediately (`turn/interrupt`). |
| `listModels() async throws -> [CodexAppServerModel]` | Fetches the live model catalog directly from the daemon. |

---

### Data Models

#### `CodexTokenUsage`
```swift
public struct CodexTokenUsage: Equatable, Sendable, Codable {
    public var inputTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int
    public var totalTokens: Int { inputTokens + outputTokens }
    public var formattedTotal: String // e.g. "1.2k tok"
}
```

#### `CodexAppServerModel`
```swift
public struct CodexAppServerModel: Identifiable, Equatable, Sendable, Codable {
    public let id: String                    // e.g. "gpt-5.6-sol"
    public let displayName: String           // e.g. "GPT-5.6-Sol"
    public let speedTier: CodexModelSpeedTier // .fast, .standard, .deep
    public let supportsReasoningEffort: Bool // true for models with thinking budgets
}
```

---

## 🔒 Automated Tool & Permission Approvals

During autonomous code generation, Codex may request permission to edit files (`item/fileChange/requestApproval`) or execute shell commands (`item/commandExecution/requestApproval`). 

`CodexAppServerClient` handles these server requests automatically by acknowledging `{"decision": "accept"}` with the corresponding request ID, enabling uninterrupted and seamless agent operations.

---

## 🧪 Testing

Run standalone package unit tests:

```bash
swift test
```

---

## 📄 License

MIT License. See [LICENSE](LICENSE) for details.
