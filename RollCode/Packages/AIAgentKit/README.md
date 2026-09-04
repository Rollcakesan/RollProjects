# AIAgentKit

Unified AI Agent Orchestration, Communication, and State Management framework for macOS applications.

`AIAgentKit` brings together OpenAI Codex (CLI and Codex App Server via JSON-RPC) and Google Gemini (CLI and REST APIs) into a single, cohesive Swift package. It manages authentication, process life cycles, multi-thread session history, model catalogs with reasoning effort configurations, streaming events, and token tracking.

---

## Features

- **Multi-Provider Architecture**:
  - **Codex**: Full support for local `codex` CLI and long-running Codex App Server (`codex app-server`) with JSON-RPC stdio protocol.
  - **Gemini**: Full support for Google Gemini CLI with automated GCP Project ID resolution (`projects.json`), API Key fallbacks, and Google Generative Language Model Catalog integration.
- **Session & Thread Management**:
  - Multi-threaded conversation sessions (`AgentThread`), automatic persistence, thread switching, and past session resume.
  - Granular token usage tracking (`input`, `cached`, `output`, `total`).
- **Catalog & Reasoning Effort**:
  - Unified model registry (`AIModelInfo`) supporting speed tiers (Fast / Standard / Deep Thinking) and reasoning effort controls (`low`, `medium`, `high`).
- **Zero Heavy External Dependencies**:
  - Pure Swift concurrency (`async/await`, `@Observable`, `@MainActor`).
  - Seamless integration with `GitBridgeKit` for real-time workspace diff detection.

---

## Architecture

```
AIAgentKit/
├── Core/
│   ├── AgentModels.swift          # AgentMessage, AgentActivity, AgentThread, TokenUsage
│   └── ModelCatalogService.swift  # Model catalog, speed tiers, reasoning effort
├── Providers/
│   ├── Codex/
│   │   ├── CodexModels.swift          # JSON-RPC models & notifications
│   │   ├── CodexAppServerClient.swift # Process lifecycle & JSON-RPC communication
│   │   ├── CodexEventParser.swift     # Streaming event decoder
│   │   └── CodexAuthService.swift     # ChatGPT login & auth detector
│   └── Gemini/
│       ├── GeminiAuthService.swift    # ~/.gemini detector & projects.json resolver
│       └── GeminiExecutableLocator.swift # CLI path resolution
└── Engine/
    └── AgentSession.swift         # Multi-thread engine, provider dispatch & run loop
```

---

## Installation

Add `AIAgentKit` as a local package dependency in your `Package.swift`:

```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MyApp",
    dependencies: [
        .package(path: "../AIAgentKit")
    ],
    targets: [
        .target(
            name: "MyApp",
            dependencies: [
                .product(name: "AIAgentKit", package: "AIAgentKit")
            ]
        )
    ]
)
```

---

## Quick Start

### 1. Initialize `AgentSession`

```swift
import AIAgentKit

@MainActor
let agent = AgentSession()

// Select provider: .codex or .gemini
agent.selectProvider(.codex)

// Configure model and reasoning effort
agent.setModel("gpt-5.6-sol")
agent.setReasoningEffort(.high)
```

### 2. Send Prompts

```swift
let workspaceURL = URL(fileURLWithPath: "/path/to/my/project")

agent.send("Run unit tests and fix any failing assertions.", in: workspaceURL)
```

### 3. Observe Events & Streamed Messages

`AgentSession` is marked with `@Observable` and `@MainActor`, making it instantly reactive in SwiftUI:

```swift
import SwiftUI
import AIAgentKit

struct MyChatView: View {
    @Environment(AgentSession.self) private var agent

    var body: some View {
        List(agent.entries) { entry in
            switch entry {
            case .message(let msg):
                Text("\(msg.displayTitle): \(msg.text)")
            case .activity(let act):
                Text("[\(act.state.rawValue)] \(act.title)")
            case .changes(let files):
                Text("Modified: \(files.joined(separator: ", "))")
            case .usage(let tokens):
                Text("Tokens: \(tokens)")
            }
        }
    }
}
```

---

## Testing

Run the included unit test suite:

```bash
swift test --package-path Packages/AIAgentKit
```

---

## License

MIT License. See [LICENSE](LICENSE) for details.
