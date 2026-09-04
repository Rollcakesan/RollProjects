# MCP Tool Specification: AIAgentKit

> **Role**: Unified AI agent orchestrator for OpenAI Codex (stdio JSON-RPC App Server & CLI) and Google Gemini (CLI & API).  
> **Concurrency**: Managed by `@MainActor` `@Observable` engine `AgentSession`. Background tasks stream events asynchronously.  
> **Package**: `import AIAgentKit`

---

## Tool Definitions

### `agent_send_prompt`
- **Method**: `AgentSession.send(_ prompt: String, in workspaceURL: URL, activeFileURL: URL? = nil)`
- **Description**: Submits a prompt turn to the currently selected provider (`codex` or `gemini`). Injects active file context, computes initial git changed paths, and starts event streaming.
- **Parameters**:
  - `prompt` (`String`): User task or instruction.
  - `workspaceURL` (`URL`): Target project / repository root path.
  - `activeFileURL` (`URL?`): Currently focused editor document URL for relative path context injection.
- **Side Effects**: Appends user message and streaming activity/message entries into `AgentSession.entries`.

### `agent_select_provider`
- **Method**: `AgentSession.selectProvider(_ provider: AgentProvider)`
- **Description**: Switches the active engine between `.codex` (OpenAI Codex) and `.gemini` (Google Gemini).
- **Parameters**:
  - `provider` (`AgentProvider`): `.codex` or `.gemini`.

### `agent_set_model`
- **Method**: `AgentSession.setModel(_ modelID: String)`
- **Description**: Updates the model identifier for the active provider and persists selection to user preferences and thread metadata.
- **Parameters**:
  - `modelID` (`String`): Model ID (e.g. `"gpt-5.6-sol"`, `"gemini-2.5-pro"`).

### `agent_set_reasoning_effort`
- **Method**: `AgentSession.setReasoningEffort(_ effort: ReasoningEffort)`
- **Description**: Sets the thinking depth tier for models supporting reasoning effort.
- **Parameters**:
  - `effort` (`ReasoningEffort`): `.low`, `.medium`, or `.high`.

### `agent_thread_management`
- **New Thread**: `AgentSession.newThread()` - Archives the active conversation and starts a fresh thread.
- **Switch Thread**: `AgentSession.switchToThread(_ thread: AgentThread)` - Restores previous message history, token tallies, and turn metrics.
- **Delete Thread**: `AgentSession.deleteThread(_ thread: AgentThread)` - Permanently removes a conversation thread.
- **Stop Execution**: `AgentSession.stop(resetThread: Bool = false)` - Cancels running turns or terminates active CLI/App Server sub-processes.

---

## Shared Models & State Representation

### `AgentEntry`
Discriminated union representing the linear thread conversation stream:
```swift
public enum AgentEntry: Identifiable, Sendable {
    case message(AgentMessage)     // User or Assistant text blocks
    case activity(AgentActivity)   // Real-time tool executions / reasoning status
    case changes([String])         // Modified workspace relative paths
    case usage(AgentTokenUsage)    // Turn token usage breakdown
}
```

### `AgentTokenUsage`
```swift
public struct AgentTokenUsage: Codable, Hashable, Sendable {
    public let input: Int
    public let cached: Int
    public let output: Int
    public let total: Int
}
```

---

## Constraints & Guardrails
1. **Thread Affiliation**: Switching providers preserves previous thread state separately (`codexLatestThread` vs `geminiLatestThread`).
2. **Git Awareness**: Auto-detects modified workspace paths between turn start and completion using `GitBridgeKit`.
3. **Cancellation**: Calling `stop()` guarantees process termination and cleans up stdin/stdout pipes.
