# MCP Tool Specification: WorkspaceIndexKit

> **Role**: Workspace file indexer, hierarchy tree walker, FSEvents file system watcher, fuzzy file locator, and regular expression text search/replace engine.  
> **Concurrency**: `FileWatcherService` uses `@MainActor`. `WorkspaceSearch` and `QuickOpenMatcher` are pure, synchronous `Sendable` utilities safe for background tasks.  
> **Package**: `import WorkspaceIndexKit`

---

## Tool Definitions

### `workspace_build_tree`
- **Method**: `FileNode.buildTree(at url: URL, fileManager: FileManager = .default) -> FileNode`
- **Description**: Recursively scans directory contents at `url`, excluding build artifacts and version control folders (`.git`, `.build`, `DerivedData`, `node_modules`, `Pods`). Returns sorted tree hierarchy with folders preceding files.
- **Parameters**:
  - `url` (`URL`): Root folder URL.
- **Returns**: `FileNode` root object containing nested `children`.

### `workspace_find_files`
- **Method**: `QuickOpenMatcher.score(query: String, candidate: String) -> Int?`
- **Description**: Calculates fuzzy matching score between search `query` and candidate file path. Prefers boundary characters (`/`, `-`, `_`, `.`) and contiguous character matches. Returns `nil` if candidate does not match query.
- **Parameters**:
  - `query` (`String`): User input search term.
  - `candidate` (`String`): Candidate file path or name.
- **Returns**: `Int?` (higher score = better match, `nil` = no match).

### `workspace_search_text`
- **Method**: `WorkspaceSearch.matches(for query: String, in files: [WorkspaceSearchFile], relativeTo rootURL: URL, limit: Int = 2000) -> [WorkspaceSearchMatch]`
- **Description**: Executes case-insensitive regular expression pattern search across in-memory file buffers, reporting 1-based line numbers, line preview snippets, and occurrence counts.
- **Parameters**:
  - `query` (`String`): Text or escaped regex pattern.
  - `files` (`[WorkspaceSearchFile]`): Array of file records (`url`, `text`).
  - `rootURL` (`URL`): Base directory for relative path resolution.
  - `limit` (`Int`): Maximum number of matches (default: 2,000).
- **Returns**: `[WorkspaceSearchMatch]` (`url`, `relativePath`, `line`, `preview`, `occurrences`).

### `workspace_replace_text`
- **Method**: `WorkspaceSearch.replacements(of query: String, with replacement: String, in files: [WorkspaceSearchFile]) -> [WorkspaceReplacement]`
- **Description**: Performs case-insensitive substitution on matching files, producing updated file strings and modification counts without writing to disk.
- **Parameters**:
  - `query` (`String`): Search term.
  - `replacement` (`String`): Substitution string.
  - `files` (`[WorkspaceSearchFile]`): Target file contents.
- **Returns**: `[WorkspaceReplacement]` (`url`, `text`, `occurrences`).

### `workspace_watch_changes`
- **Class**: `FileWatcherService(url: URL, onChange: @MainActor () -> Void)`
- **Description**: Starts a low-latency macOS `FSEventStream` monitoring file creation, modification, and deletion events under `url`. Calls `onChange` on the main queue with 0.5s debouncing.
- **Lifecycle**: Call `stopWatching()` or allow instance to deinitialize.

---

## Constraints & Guardrails
1. **Safety Limits**: `WorkspaceSearch.matches` caps search results at `limit` to prevent memory exhaustion on large repositories.
2. **Hidden & Ignored Directories**: `.git`, `.build`, `.swiftpm`, `DerivedData`, `node_modules`, and `Pods` are automatically excluded during tree indexing.
