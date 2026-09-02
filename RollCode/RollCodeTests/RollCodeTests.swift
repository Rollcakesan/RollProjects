import XCTest
@testable import RollCode

final class RollCodeTests: XCTestCase {
    func testCodexEventParserReadsThreadMessagesCommandsAndChanges() throws {
        let thread = try XCTUnwrap(CodexEventParser.parse(
            #"{"type":"thread.started","thread_id":"thread-123"}"#
        ))
        XCTAssertEqual(thread, .threadStarted("thread-123"))

        let message = try XCTUnwrap(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"item-1","type":"agent_message","text":"Done"}}"#
        ))
        XCTAssertEqual(message, .message("Done"))

        let command = try XCTUnwrap(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"item-2","type":"command_execution","command":"swift test","aggregated_output":"ok","exit_code":0,"status":"completed"}}"#
        ))
        guard case .activity(let commandActivity, let commandFiles) = command else {
            return XCTFail("Expected an activity")
        }
        XCTAssertEqual(commandActivity.title, "swift test")
        XCTAssertEqual(commandActivity.detail, "ok")
        XCTAssertEqual(commandActivity.state, .completed)
        XCTAssertEqual(commandFiles, [])

        let change = try XCTUnwrap(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"item-3","type":"file_change","changes":[{"path":"/tmp/App.swift","kind":"update"}],"status":"completed"}}"#
        ))
        guard case .activity(let changeActivity, let changedFiles) = change else {
            return XCTFail("Expected a file change activity")
        }
        XCTAssertEqual(changedFiles, ["/tmp/App.swift"])
        XCTAssertEqual(changeActivity.state, .completed)
    }

    func testCodexEventParserReadsUsageAndFailures() throws {
        let completed = try XCTUnwrap(CodexEventParser.parse(
            #"{"type":"turn.completed","usage":{"input_tokens":20,"cached_input_tokens":10,"output_tokens":5}}"#
        ))
        XCTAssertEqual(completed, .usage("20 input · 10 cached · 5 output"))

        let failed = try XCTUnwrap(CodexEventParser.parse(
            #"{"type":"turn.failed","error":{"message":"Authentication required"}}"#
        ))
        XCTAssertEqual(failed, .error("Authentication required"))
    }

    func testCodexEventParserDecodesStructuredToolResults() throws {
        let event = try XCTUnwrap(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"tool-1","type":"mcp_tool_call","server":"files","tool":"read","result":{"ok":true,"count":2}}}"#
        ))
        guard case .activity(let activity, _) = event else {
            return XCTFail("Expected a tool activity")
        }
        XCTAssertEqual(activity.title, "files · read")
        XCTAssertTrue(activity.detail.contains("\"ok\":true"))
        XCTAssertTrue(activity.detail.contains("\"count\":2"))
    }

    func testWorkspaceSnapshotDetectsAddedChangedAndDeletedFiles() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let changed = root.appendingPathComponent("changed.txt")
        let deleted = root.appendingPathComponent("deleted.txt")
        try "before".write(to: changed, atomically: true, encoding: .utf8)
        try "delete".write(to: deleted, atomically: true, encoding: .utf8)
        let before = WorkspaceSnapshot.capture(at: root)

        try "after with a different size".write(to: changed, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: deleted)
        try "new".write(to: root.appendingPathComponent("added.txt"), atomically: true, encoding: .utf8)
        let after = WorkspaceSnapshot.capture(at: root)

        XCTAssertEqual(before.changedFiles(comparedTo: after), ["added.txt", "changed.txt", "deleted.txt"])
    }

    @MainActor
    func testAgentSessionStreamsCodexJSONLines() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let executable = root.appendingPathComponent("fake-codex")
        let script = """
        #!/bin/zsh
        printf '%s\\n' '{"type":"thread.started","thread_id":"fake-thread"}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"change","type":"file_change","changes":[{"path":"Sources/App.swift","kind":"update"}],"status":"completed"}}'
        printf '%s\\n' '{"type":"item.completed","item":{"id":"message","type":"agent_message","text":"Finished"}}'
        printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":3,"cached_input_tokens":1,"output_tokens":2}}'
        """
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

        let agent = AgentSession(executableURL: executable)
        agent.send("Do the work", in: root)
        for _ in 0..<40 where agent.isRunning {
            try await Task.sleep(nanoseconds: 50_000_000)
        }

        XCTAssertFalse(agent.isRunning)
        XCTAssertEqual(agent.threadID, "fake-thread")
        XCTAssertTrue(agent.entries.contains { entry in
            guard case .message(let message) = entry else { return false }
            return message.role == .assistant && message.text == "Finished"
        })
        XCTAssertTrue(agent.entries.contains(.changes(["Sources/App.swift"])))
        XCTAssertTrue(agent.entries.contains(.usage("3 input · 1 cached · 2 output")))
    }

    func testCodeLanguageDetection() {
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/App.swift")), .swift)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/view.tsx")), .typescript)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/README.md")), .markdown)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/main.rs")), .rust)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/config.yml")), .yaml)
        XCTAssertEqual(CodeLanguage(url: URL(fileURLWithPath: "/tmp/LICENSE")), .plainText)
    }

    func testTreeSortsDirectoriesBeforeFilesAndSkipsHeavyFolders() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
        try "let value = 1".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

        let tree = FileNode.buildTree(at: root)
        XCTAssertEqual(tree.children?.map(\.name), ["Sources", "main.swift"])
    }

    func testTreeFindsNestedFilesCaseInsensitively() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let sources = root.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try "".write(to: sources.appendingPathComponent("WorkspaceModel.swift"), atomically: true, encoding: .utf8)

        let matches = FileNode.buildTree(at: root).matchingFiles("workspace")
        XCTAssertEqual(matches.map(\.name), ["WorkspaceModel.swift"])
    }

    func testQuickOpenMatcherSupportsFuzzyPathsAndRanksTighterMatchesHigher() {
        let tight = QuickOpenMatcher.score(query: "wsm", candidate: "WorkspaceModel.swift")
        let loose = QuickOpenMatcher.score(query: "wsm", candidate: "Views/WorkspaceMenu.swift")

        XCTAssertNotNil(tight)
        XCTAssertNotNil(loose)
        XCTAssertGreaterThan(tight ?? 0, loose ?? 0)
        XCTAssertNil(QuickOpenMatcher.score(query: "xyz", candidate: "WorkspaceModel.swift"))
    }

    func testSmartEditingPairsAndWrapsCharacters() throws {
        let emptyPair = try XCTUnwrap(EditorSmartEditing.edit(for: "(", in: "", range: NSRange(location: 0, length: 0)))
        XCTAssertEqual(emptyPair.replacement, "()")
        XCTAssertEqual(emptyPair.selection, NSRange(location: 1, length: 0))

        let wrapped = try XCTUnwrap(EditorSmartEditing.edit(for: "{", in: "value", range: NSRange(location: 0, length: 5)))
        XCTAssertEqual(wrapped.replacement, "{value}")
        XCTAssertEqual(wrapped.selection, NSRange(location: 1, length: 5))

        let skipClosing = try XCTUnwrap(EditorSmartEditing.edit(for: ")", in: "()", range: NSRange(location: 1, length: 0)))
        XCTAssertEqual(skipClosing.replacement, "")
        XCTAssertEqual(skipClosing.selection.location, 2)
    }

    func testSmartEditingIndentsNewLinesAndExpandsEmptyBlocks() throws {
        let indented = try XCTUnwrap(EditorSmartEditing.edit(
            for: "\n",
            in: "    let value = {",
            range: NSRange(location: 17, length: 0)
        ))
        XCTAssertEqual(indented.replacement, "\n        ")

        let block = try XCTUnwrap(EditorSmartEditing.edit(
            for: "\n",
            in: "{}",
            range: NSRange(location: 1, length: 0)
        ))
        XCTAssertEqual(block.replacement, "\n    \n")
        XCTAssertEqual(block.selection.location, 6)

        let twoSpaces = try XCTUnwrap(EditorSmartEditing.edit(
            for: "\n",
            in: "{}",
            range: NSRange(location: 1, length: 0),
            tabWidth: 2
        ))
        XCTAssertEqual(twoSpaces.replacement, "\n  \n")
        XCTAssertEqual(twoSpaces.selection.location, 4)
    }

    @MainActor
    func testWorkspaceOpensAndSavesTextFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("note.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        let workspace = WorkspaceModel(restoresLastWorkspace: false)
        workspace.openFile(file)
        XCTAssertEqual(workspace.activeDocument?.text, "before")
        workspace.activeDocument?.text = "after"
        XCTAssertTrue(workspace.activeDocument?.isDirty == true)
        XCTAssertTrue(workspace.saveAllDocuments())
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "after")
    }

    @MainActor
    func testWorkspaceReloadsCleanFileChangedOnDisk() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("external.txt")
        try "before".write(to: file, atomically: true, encoding: .utf8)

        let workspace = WorkspaceModel(restoresLastWorkspace: false)
        workspace.openFile(file)
        try "after".write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(2)],
            ofItemAtPath: file.path
        )
        workspace.checkForExternalChanges()

        XCTAssertEqual(workspace.activeDocument?.text, "after")
        XCTAssertFalse(workspace.activeDocument?.isDirty == true)
    }

    @MainActor
    func testWorkspaceRenamesOpenFileAndUpdatesDocumentURL() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = root.appendingPathComponent("old.swift")
        let destination = root.appendingPathComponent("new.swift")
        try "let value = 1".write(to: source, atomically: true, encoding: .utf8)

        let workspace = WorkspaceModel(restoresLastWorkspace: false)
        workspace.openFile(source)
        try workspace.renameItem(at: source, to: "new.swift")

        XCTAssertFalse(FileManager.default.fileExists(atPath: source.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
        XCTAssertEqual(workspace.activeDocument?.url, destination)
    }

    @MainActor
    func testTerminalExecutesCommandInWorkspace() async throws {
        let directory = FileManager.default.temporaryDirectory
        let terminal = TerminalSession()
        terminal.start(in: directory)
        defer { terminal.stop() }
        XCTAssertTrue(terminal.isRunning)

        terminal.send("printf '%s\\n' \"$((40 + 2))\"")
        for _ in 0..<30 where !terminal.output.contains("\n42\n") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(terminal.output.contains("\n42\n"))
    }

    @MainActor
    func testTerminalInterruptsForegroundCommand() async throws {
        let terminal = TerminalSession()
        terminal.start(in: FileManager.default.temporaryDirectory)
        defer { terminal.stop() }

        terminal.send("sleep 5")
        try await Task.sleep(nanoseconds: 100_000_000)
        terminal.interrupt()
        terminal.send("printf '%s\\n' \"$((60 + 3))\"")

        for _ in 0..<40 where !terminal.output.contains("\n63\n") {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTAssertTrue(terminal.output.contains("\n63\n"))
    }

    @MainActor
    func testTerminalCommandHistoryMovesBackwardAndForward() {
        let terminal = TerminalSession()
        terminal.send("first")
        terminal.send("second")

        XCTAssertEqual(terminal.previousCommand(), "second")
        XCTAssertEqual(terminal.previousCommand(), "first")
        XCTAssertEqual(terminal.nextCommand(), "second")
        XCTAssertEqual(terminal.nextCommand(), "")
    }

    @MainActor
    func testWorkspacePersistsAndRestoresLastFolder() throws {
        let suiteName = "RollCodeTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let firstWorkspace = WorkspaceModel(defaults: defaults, restoresLastWorkspace: false)
        firstWorkspace.openWorkspace(root)
        let restoredWorkspace = WorkspaceModel(defaults: defaults)

        XCTAssertEqual(restoredWorkspace.rootURL, root.standardizedFileURL)
    }
}
