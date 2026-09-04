# MCP Tool Specification: GitBridgeKit

> **Role**: Git CLI inspection, porcelain v1 status parsing, unified diff analysis, and staged commits.  
> **Concurrency**: Sync I/O invoking `/usr/bin/git`. Wrap in `Task.detached(priority: .utility)` when calling from `@MainActor`.  
> **Package**: `import GitBridgeKit`

---

## Tool Definitions

### `git_get_changes`
- **Method**: `GitBridgeService.changes(in rootURL: URL) throws -> [GitChange]`
- **Description**: Returns all modified, added, and untracked files scoped to `rootURL` with unified diff strings.
- **Parameters**:
  - `rootURL` (`URL`): Path to repository root or workspace subfolder.
- **Returns**: `[GitChange]`
  - `path` (`String`): Workspace-relative path.
  - `status` (`String`): Porcelain status code (e.g. `" M"`, `"M "`, `"??"`).
  - `diff` (`String`): Unified diff representation.

### `git_get_changed_paths`
- **Method**: `GitBridgeService.changedPaths(in rootURL: URL) throws -> [String]`
- **Description**: Returns a sorted list of relative paths for modified/untracked files.
- **Parameters**:
  - `rootURL` (`URL`): Path to workspace directory.
- **Returns**: `[String]` (relative paths)

### `git_diff_line_numbers`
- **Method**: `GitBridgeService.diffLineNumbers(for diff: String) -> (added: Set<Int>, modified: Set<Int>)`
- **Description**: Parses unified diff hunks into 1-based line numbers for editor gutter decorations.
- **Parameters**:
  - `diff` (`String`): Unified diff text.
- **Returns**: `(added: Set<Int>, modified: Set<Int>)`

### `git_commit`
- **Method**: `GitBridgeService.commit(in rootURL: URL, message: String) throws`
- **Description**: Stages all modifications scoped to `rootURL` (`git add -A`) and creates a commit. Automatically rolls back staging index snapshot on failure.
- **Parameters**:
  - `rootURL` (`URL`): Path to repository root or subfolder.
  - `message` (`String`): Non-empty commit message.
- **Throws**: `GitDiffError.commandFailed(String)`

---

## Constraints & Guardrails
1. **Scoping**: Subfolder workspaces are automatically resolved via `git rev-parse --show-toplevel`. Commits and status checks are restricted using pathspecs.
2. **Atomic Rollback**: If a commit hook fails, the previous `.git/index` binary state is atomically restored.
