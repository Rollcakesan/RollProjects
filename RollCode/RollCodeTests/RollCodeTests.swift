import Foundation
import Testing
#if canImport(GitBridgeKit)
import GitBridgeKit
#endif
#if canImport(AIAgentKit)
import AIAgentKit
#endif
@testable import RollCode

@Suite("RollCode Test Suite")
struct RollCodeTests {
    // CodexEventParser がスレッド開始、メッセージ、コマンド実行、ファイル変更イベントを正しく読み取るかを検証
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

    // CodexEventParser がトークン使用量および失敗イベントを正しく読み取るかを検証
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

    // CodexEventParser が構造化された JSON ツール呼び出し結果をデコードできるかを検証
    @Test("CodexEventParser decodes structured JSON tool call results")
    func codexEventParserDecodesStructuredToolResults() throws {
        let event = try #require(CodexEventParser.parse(
            #"{"type":"item.completed","item":{"id":"tool-1","type":"mcp_tool_call","server":"files","tool":"read","result":{"ok":true,"count":2}}}"#
        ))
        guard case .activity(let activity, _) = event else {
            Issue.record("Expected a tool activity")
            return
        }
        #expect(activity.title == "files · read")
        #expect(activity.detail.contains("\"ok\":true"))
        #expect(activity.detail.contains("\"count\":2"))
    }

    // AgentSession が Codex JSON Lines をストリーミングし状態遷移を追跡できるかを検証
    @Test("AgentSession streams Codex JSON Lines and tracks state changes")
    @MainActor
    func agentSessionStreamsCodexJSONLines() async throws {
        try await withTemporaryDirectory { root in
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

            let agent = AgentSession(executableURL: executable, defaults: testAgentDefaults())
            agent.send("Do the work", in: root)
            for _ in 0..<40 where agent.isRunning {
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            #expect(!agent.isRunning)
            #expect(agent.threadID == "fake-thread")
            #expect(agent.entries.contains { entry in
                guard case .message(let message) = entry else { return false }
                return message.role == .assistant && message.text == "Finished"
            })
            #expect(agent.entries.contains(.changes(["Sources/App.swift"])))
            #expect(agent.entries.contains(.usage("3 input · 1 cached · 2 output")))
        }
    }

    // ファイル拡張子からのプログラミング言語判定機能を検証
    @Test(
        "Code language detection from file extension",
        arguments: [
            ("/tmp/App.swift", CodeLanguage.swift),
            ("/tmp/view.tsx", CodeLanguage.typescript),
            ("/tmp/README.md", CodeLanguage.markdown),
            ("/tmp/main.rs", CodeLanguage.rust),
            ("/tmp/config.yml", CodeLanguage.yaml),
            ("/tmp/LICENSE", CodeLanguage.plainText),
        ]
    )
    func codeLanguageDetection(path: String, expected: CodeLanguage) {
        #expect(CodeLanguage(url: URL(fileURLWithPath: path)) == expected)
    }

    // FileNode.buildTree がディレクトリをファイルより先にソートし除外対象フォルダをスキップするかを検証
    @Test("FileNode.buildTree sorts directories before files and skips ignored folders")
    func treeSortsDirectoriesBeforeFilesAndSkipsHeavyFolders() throws {
        try withTemporaryDirectory { root in
            try FileManager.default.createDirectory(at: root.appendingPathComponent("Sources"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: root.appendingPathComponent("node_modules"), withIntermediateDirectories: true)
            try "let value = 1".write(to: root.appendingPathComponent("main.swift"), atomically: true, encoding: .utf8)

            let tree = FileNode.buildTree(at: root)
            #expect(tree.children?.map(\.name) == ["Sources", "main.swift"])
        }
    }

    // FileNode.matchingFiles が階層内のファイルを大文字小文字を区別せず検索できるかを検証
    @Test("FileNode.matchingFiles finds nested files case-insensitively")
    func treeFindsNestedFilesCaseInsensitively() throws {
        try withTemporaryDirectory { root in
            let sources = root.appendingPathComponent("Sources")
            try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
            try "".write(to: sources.appendingPathComponent("WorkspaceModel.swift"), atomically: true, encoding: .utf8)

            let matches = FileNode.buildTree(at: root).matchingFiles("workspace")
            #expect(matches.map(\.name) == ["WorkspaceModel.swift"])
        }
    }

    // QuickOpenMatcher がより一致度の高いあいまいマッチ候補を上位にランク付けするかを検証
    @Test("QuickOpenMatcher ranks tighter fuzzy matches higher")
    func quickOpenMatcherSupportsFuzzyPathsAndRanksTighterMatchesHigher() {
        let tight = QuickOpenMatcher.score(query: "wsm", candidate: "WorkspaceModel.swift")
        let loose = QuickOpenMatcher.score(query: "wsm", candidate: "Views/WorkspaceMenu.swift")

        #expect(tight != nil)
        #expect(loose != nil)
        #expect((tight ?? 0) > (loose ?? 0))
        #expect(QuickOpenMatcher.score(query: "xyz", candidate: "WorkspaceModel.swift") == nil)
    }

    // EditorSmartEditing が括弧などのペアを自動補完し選択範囲を囲めるかを検証
    @Test("EditorSmartEditing auto-closes pairs and wraps selected ranges")
    func smartEditingPairsAndWrapsCharacters() throws {
        let emptyPair = try #require(EditorSmartEditing.edit(for: "(", in: "", range: NSRange(location: 0, length: 0)))
        #expect(emptyPair.replacement == "()")
        #expect(emptyPair.selection == NSRange(location: 1, length: 0))

        let wrapped = try #require(EditorSmartEditing.edit(for: "{", in: "value", range: NSRange(location: 0, length: 5)))
        #expect(wrapped.replacement == "{value}")
        #expect(wrapped.selection == NSRange(location: 1, length: 5))

        let skipClosing = try #require(EditorSmartEditing.edit(for: ")", in: "()", range: NSRange(location: 1, length: 0)))
        #expect(skipClosing.replacement == "")
        #expect(skipClosing.selection.location == 2)
    }

    // EditorSmartEditing が改行時の自動インデントおよび空ブロック展開を正しく処理するかを検証
    @Test("EditorSmartEditing automatically indents new lines and expands empty blocks")
    func smartEditingIndentsNewLinesAndExpandsEmptyBlocks() throws {
        let indented = try #require(EditorSmartEditing.edit(
            for: "\n",
            in: "    let value = {",
            range: NSRange(location: 17, length: 0)
        ))
        #expect(indented.replacement == "\n        ")

        let block = try #require(EditorSmartEditing.edit(
            for: "\n",
            in: "{}",
            range: NSRange(location: 1, length: 0)
        ))
        #expect(block.replacement == "\n    \n")
        #expect(block.selection.location == 6)

        let twoSpaces = try #require(EditorSmartEditing.edit(
            for: "\n",
            in: "{}",
            range: NSRange(location: 1, length: 0),
            tabWidth: 2
        ))
        #expect(twoSpaces.replacement == "\n  \n")
        #expect(twoSpaces.selection.location == 4)
    }

    // 閉じ波括弧の自動アンインデント、Tab/Shift+Tabによる複数行インデント/アンインデント、ソフトバックスペースを検証
    @Test("EditorSmartEditing auto-dedents closing brace and performs line indent/dedent and soft backspace")
    func editorSmartEditingIndentFeatures() throws {
        // 1. Auto-dedent on '}'
        let dedentBrace = try #require(EditorSmartEditing.edit(
            for: "}",
            in: "    ",
            range: NSRange(location: 4, length: 0),
            tabWidth: 4
        ))
        #expect(dedentBrace.replacement == "}")
        #expect(dedentBrace.replacementRange?.location == 0)
        #expect(dedentBrace.replacementRange?.length == 4)

        // 2. Soft tab backspace (deletes 4 spaces in indentation)
        let backspace = try #require(EditorSmartEditing.backspaceEdit(
            in: "        code",
            range: NSRange(location: 8, length: 0),
            tabWidth: 4
        ))
        #expect(backspace.replacementRange?.location == 4)
        #expect(backspace.replacementRange?.length == 4)

        // 3. Multi-line indent with Tab
        let source: NSString = "first\nsecond"
        let indented = EditorSmartEditing.indentLines(in: source, range: NSRange(location: 0, length: source.length), tabWidth: 4)
        #expect(indented.replacement == "    first\n    second")

        // 4. Multi-line dedent with Shift+Tab
        let indentedSource: NSString = "    first\n    second"
        let dedented = EditorSmartEditing.dedentLines(in: indentedSource, range: NSRange(location: 0, length: indentedSource.length), tabWidth: 4)
        #expect(dedented.replacement == "first\nsecond")
    }

    // WorkspaceSearch が行単位での大文字小文字を区別しない一致検索と文字列置換を実行できるかを検証
    @Test("WorkspaceSearch finds case-insensitive matches by line and replaces literal text")
    func workspaceSearchFindsAndReplacesLiteralText() throws {
        let root = URL(fileURLWithPath: "/tmp/project", isDirectory: true)
        let first = WorkspaceSearchFile(
            url: root.appendingPathComponent("Sources/App.swift"),
            text: "let value = RollCode\n// rollcode and RollCode"
        )
        let second = WorkspaceSearchFile(
            url: root.appendingPathComponent("README.md"),
            text: "Nothing here"
        )

        let matches = WorkspaceSearch.matches(for: "rollcode", in: [first, second], relativeTo: root)
        #expect(matches.map(\.line) == [1, 2])
        #expect(matches.map(\.occurrences) == [1, 2])
        #expect(matches.first?.relativePath == "Sources/App.swift")

        let replacements = WorkspaceSearch.replacements(
            of: "RollCode",
            with: "$EDITOR\\name",
            in: [first, second]
        )
        let replacement = try #require(replacements.first)
        #expect(replacement.occurrences == 3)
        #expect(replacement.text == "let value = $EDITOR\\name\n// $EDITOR\\name and $EDITOR\\name")
    }

    // GitBridgeService が追跡対象 (tracked) および未追跡 (untracked) の変更差分を正しく取得できるかを検証
    @Test("GitBridgeService returns tracked and untracked changes")
    func gitDiffServiceReturnsWorkingTreeChanges() throws {
        try withTemporaryDirectory { root in
            try runGit(["init", "--quiet"], in: root)
            try runGit(["config", "user.email", "rollcode@example.com"], in: root)
            try runGit(["config", "user.name", "RollCode Tests"], in: root)

            let tracked = root.appendingPathComponent("tracked.txt")
            try "before\n".write(to: tracked, atomically: true, encoding: .utf8)
            try runGit(["add", "tracked.txt"], in: root)
            try runGit(["commit", "--quiet", "-m", "Initial"], in: root)

            try "after\n".write(to: tracked, atomically: true, encoding: .utf8)
            try "new\n".write(to: root.appendingPathComponent("new.txt"), atomically: true, encoding: .utf8)

            let changes = try GitBridgeService.changes(in: root)
            #expect(changes.map(\.path) == ["new.txt", "tracked.txt"])
            #expect(changes.first(where: { $0.path == "tracked.txt" })?.diff.contains("+after") == true)
            #expect(changes.first(where: { $0.path == "new.txt" })?.diff.contains("new file mode") == true)
        }
    }

    // 初回コミット前（HEAD 未作成状態）でもステージングされたファイルを表示できるかを検証
    @Test("GitBridgeService shows staged files before the first commit")
    func gitDiffServiceSupportsRepositoryWithoutHead() throws {
        try withTemporaryDirectory { root in
            try runGit(["init", "--quiet"], in: root)
            let file = root.appending(path: "first.txt")
            try "first".write(to: file, atomically: true, encoding: .utf8)
            try runGit(["add", "first.txt"], in: root)

            let changes = try GitBridgeService.changes(in: root)
            #expect(changes.map(\.path) == ["first.txt"])
            #expect(changes.first?.diff.contains("+first") == true)
        }
    }

    // WorkspaceModel がテキストファイルを開き、編集し、保存できるかを検証
    @Test("WorkspaceModel opens, modifies, and saves text files")
    @MainActor
    func workspaceOpensAndSavesTextFile() throws {
        try withTemporaryDirectory { root in
            let file = root.appendingPathComponent("note.txt")
            try "before".write(to: file, atomically: true, encoding: .utf8)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(file)
            #expect(workspace.activeDocument?.text == "before")
            workspace.activeDocument?.text = "after"
            #expect(workspace.activeDocument?.isDirty == true)
            #expect(workspace.saveAllDocuments())
            #expect(try String(contentsOf: file, encoding: .utf8) == "after")
        }
    }

    // 外部プロセスによってディスク上で変更された未編集ファイルを自動再読込するかを検証
    @Test("WorkspaceModel reloads clean files changed externally on disk")
    @MainActor
    func workspaceReloadsCleanFileChangedOnDisk() throws {
        try withTemporaryDirectory { root in
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

            #expect(workspace.activeDocument?.text == "after")
            #expect(workspace.activeDocument?.isDirty == false)
        }
    }

    // 開いているファイルの名前変更時にドキュメント URL が型付きスローとともに更新されるかを検証
    @Test("WorkspaceModel renames open file and updates document URL with Typed Throws")
    @MainActor
    func workspaceRenamesOpenFileAndUpdatesDocumentURL() throws {
        try withTemporaryDirectory { root in
            let source = root.appendingPathComponent("old.swift")
            let destination = root.appendingPathComponent("new.swift")
            try "let value = 1".write(to: source, atomically: true, encoding: .utf8)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(source)
            try workspace.renameItem(at: source, to: "new.swift")

            #expect(!FileManager.default.fileExists(atPath: source.path))
            #expect(FileManager.default.fileExists(atPath: destination.path))
            #expect(workspace.activeDocument?.url == destination)
        }
    }

    // TerminalSession がワークスペース内でコマンドを実行し標準出力を受信できるかを検証
    @Test("TerminalSession executes command and delivers output in workspace")
    @MainActor
    func terminalExecutesCommandInWorkspace() async throws {
        try await withTemporaryDirectory { directory in
            let terminal = TerminalSession()
            terminal.start(in: directory)
            defer { terminal.stop() }
            #expect(terminal.isRunning)

            terminal.send("printf '%s\\n' \"$((40 + 2))\"")
            for _ in 0..<30 where !terminal.output.contains("42") {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            #expect(terminal.output.contains("42"))
        }
    }

    // TerminalSession のコマンド履歴の前進・後退ナビゲーションを検証
    @Test("TerminalSession command history moves backward and forward")
    @MainActor
    func terminalCommandHistoryMovesBackwardAndForward() {
        let terminal = TerminalSession()
        terminal.send("first")
        terminal.send("second")

        #expect(terminal.previousCommand() == "second")
        #expect(terminal.previousCommand() == "first")
        #expect(terminal.nextCommand() == "second")
        #expect(terminal.nextCommand() == "")
    }

    // 最後に開いていたワークスペースフォルダが UserDefaults に保存され復元されるかを検証
    @Test("WorkspaceModel persists and restores last opened folder")
    @MainActor
    func workspacePersistsAndRestoresLastFolder() throws {
        let suiteName = "RollCodeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        try withTemporaryDirectory { root in
            let firstWorkspace = WorkspaceModel(defaults: defaults, restoresLastWorkspace: false)
            firstWorkspace.openWorkspace(root)
            let restoredWorkspace = WorkspaceModel(defaults: defaults)

            #expect(restoredWorkspace.rootURL == root.standardizedFileURL)
        }
    }

    // エディタのフォントサイズズームおよびプリセット倍率の管理・永続化を検証
    @Test("WorkspaceModel manages and persists font size zoom levels")
    @MainActor
    func workspaceManagesFontSizeZoom() throws {
        let suiteName = "RollCodeTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }

        let workspace = WorkspaceModel(defaults: defaults, restoresLastWorkspace: false)
        #expect(workspace.fontSize == 14.5)
        #expect(workspace.editorFontScale == .medium)

        workspace.zoomIn()
        #expect(workspace.fontSize == 15.5)

        workspace.zoomOut()
        workspace.zoomOut()
        #expect(workspace.fontSize == 13.5)

        workspace.resetZoom()
        #expect(workspace.fontSize == 14.5)
        #expect(workspace.editorFontScale == .medium)

        workspace.setEditorFontScale(.small)
        #expect(workspace.fontSize == 12.5)
        #expect(workspace.editorFontScale == .small)

        workspace.setEditorFontScale(.large)
        #expect(workspace.fontSize == 16.5)
        #expect(workspace.editorFontScale == .large)

        workspace.setFontSize(35)
        #expect(workspace.fontSize == 32)

        workspace.setFontSize(5)
        #expect(workspace.fontSize == 9)

        let restored = WorkspaceModel(defaults: defaults, restoresLastWorkspace: false)
        #expect(restored.fontSize == 9)
    }

    // ファイルやフォルダの新規作成およびゴミ箱への移動削除を検証
    @Test("WorkspaceModel creates files and folders and moves to Trash")
    @MainActor
    func workspaceCreatesAndDeletesItems() throws {
        try withTemporaryDirectory { root in
            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openWorkspace(root)

            workspace.requestCreateFile(in: root)
            workspace.creatingItemName = "test.swift"
            workspace.confirmCreateItem()

            let createdFile = root.appendingPathComponent("test.swift")
            #expect(FileManager.default.fileExists(atPath: createdFile.path))
            #expect(workspace.activeDocument?.url == createdFile)

            workspace.requestCreateFolder(in: root)
            workspace.creatingItemName = "Subfolder"
            workspace.confirmCreateItem()

            let createdFolder = root.appendingPathComponent("Subfolder")
            var isDir: ObjCBool = false
            #expect(FileManager.default.fileExists(atPath: createdFolder.path, isDirectory: &isDir) && isDir.boolValue)

            workspace.deleteItem(at: createdFile)
            #expect(!FileManager.default.fileExists(atPath: createdFile.path))
            #expect(workspace.activeDocument == nil)
        }
    }

    // GitBridgeService が変更をコミットしステータスをクリーンに更新できるかを検証
    @Test("GitBridgeService commits changes and updates status")
    func gitDiffServiceCommitsChanges() throws {
        try withTemporaryDirectory { root in
            try runGit(["init"], in: root)
            try runGit(["config", "user.email", "tester@example.com"], in: root)
            try runGit(["config", "user.name", "Tester"], in: root)

            let testFile = root.appendingPathComponent("file.txt")
            try "hello".write(to: testFile, atomically: true, encoding: .utf8)

            let changesBefore = try GitBridgeService.changes(in: root)
            #expect(!changesBefore.isEmpty)

            try GitBridgeService.commit(in: root, message: "Initial commit")

            let changesAfter = try GitBridgeService.changes(in: root)
            #expect(changesAfter.isEmpty)
        }
    }

    // Git 操作の範囲を開いているサブフォルダ内に正しく限定できるかを検証
    @Test("GitBridgeService limits changes and commits to an opened repository subfolder")
    func gitDiffServiceScopesOperationsToWorkspace() throws {
        try withTemporaryDirectory { root in
            try runGit(["init", "--quiet"], in: root)
            try runGit(["config", "user.email", "tester@example.com"], in: root)
            try runGit(["config", "user.name", "Tester"], in: root)
            let subfolder = root.appending(path: "Subproject")
            try FileManager.default.createDirectory(at: subfolder, withIntermediateDirectories: true)
            let outside = root.appending(path: "outside.txt")
            let inside = subfolder.appending(path: "inside.txt")
            try "base".write(to: outside, atomically: true, encoding: .utf8)
            try "base".write(to: inside, atomically: true, encoding: .utf8)
            try runGit(["add", "-A"], in: root)
            try runGit(["commit", "--quiet", "-m", "Base"], in: root)

            try "outside change".write(to: outside, atomically: true, encoding: .utf8)
            try "inside change".write(to: inside, atomically: true, encoding: .utf8)

            let changes = try GitBridgeService.changes(in: subfolder)
            #expect(changes.map(\.path) == ["inside.txt"])
            #expect(changes.first?.diff.contains("+inside change") == true)

            try GitBridgeService.commit(in: subfolder, message: "Update subproject")
            #expect(try GitBridgeService.changes(in: subfolder).isEmpty)
            #expect(try GitBridgeService.changedPaths(in: root) == ["outside.txt"])
            #expect(try runGitOutput(["show", "--pretty=format:", "--name-only", "HEAD"], in: root).trimmed == "Subproject/inside.txt")
        }
    }

    // WorkspaceModel が確認ダイアログなしでドキュメントを直接閉じられるかを検証
    @Test("WorkspaceModel closes document directly without safety dialog")
    @MainActor
    func workspaceClosesDocumentDirectly() throws {
        try withTemporaryDirectory { root in
            let file = root.appending(path: "dirty.txt")
            try "initial".write(to: file, atomically: true, encoding: .utf8)

            let workspace = WorkspaceModel(restoresLastWorkspace: false)
            workspace.openFile(file)
            let doc = try #require(workspace.activeDocument)
            doc.text = "modified"

            workspace.closeDocument(doc)
            #expect(workspace.documents.isEmpty)
        }
    }

    // CodexAuthService が ChatGPT ログインモードとトークン情報を解析できるかを検証
    @Test("CodexAuthService parses ChatGPT login mode and credentials")
    @MainActor
    func codexAuthServiceParsesChatGPTLogin() throws {
        try withTemporaryDirectory { root in
            let authFile = root.appending(path: "auth.json")
            let payload = """
            {"auth_mode":"chatgpt","OPENAI_API_KEY":null,"tokens":{"id_token":"eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6InRlc3RAZXhhbXBsZS5jb20iLCJodHRwczovL2FwaS5vcGVuYWkuY29tL2F1dGgiOnsiY2hhdGdwdF9wbGFuX3R5cGUiOiJwbHVzIn19.signature","access_token":"mock"}}
            """
            try payload.write(to: authFile, atomically: true, encoding: .utf8)

            let service = CodexAuthService(authFileURL: authFile, isCLIAvailable: { true })
            #expect(service.status == .loggedIn(mode: "ChatGPT", email: "test@example.com", plan: "plus"))
            #expect(service.status.displayText == "test@example.com (Plus)")
        }
    }

    // CodexAuthService が API キー認証を検出できるかを検証
    @Test("CodexAuthService detects API key authentication")
    @MainActor
    func codexAuthServiceDetectsAPIKey() throws {
        try withTemporaryDirectory { root in
            let authFile = root.appending(path: "auth.json")
            let payload = """
            {"OPENAI_API_KEY":"sk-proj-test1234"}
            """
            try payload.write(to: authFile, atomically: true, encoding: .utf8)

            let service = CodexAuthService(authFileURL: authFile, isCLIAvailable: { true })
            #expect(service.status == .apiKey)
            #expect(service.status.displayText == "API Key")
        }
    }

    // AgentSession が複数スレッドとスレッド切り替えを正しく処理できるかを検証
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

    // 過去の Codex セッション概要から新しいスレッドとして復元・再開できるかを検証
    @Test("AgentSession resumes past Codex session into new thread")
    @MainActor
    func agentSessionResumesPastCodexSession() throws {
        let session = AgentSession(executableURL: nil)
        let past = CodexSessionSummary(id: "test-thread-123", threadName: "Past Discussion", updatedAt: Date())
        session.resumePastCodexSession(past)

        #expect(session.threadID == "test-thread-123")
        #expect(session.activeThreadTitle == "Past Discussion")
        #expect(session.entries.count == 1)
    }

    // Codex と Gemini の最新スレッド間を独立して相互にトグル切り替えできるかを検証
    @Test("AgentSession toggles between latest Codex and Gemini threads independently")
    @MainActor
    func agentSessionTogglesBetweenProviders() throws {
        let session = AgentSession(executableURL: nil, geminiExecutableURL: nil, defaults: testAgentDefaults())
        #expect(session.selectedProvider == .codex)

        session.entries = [.message(AgentMessage(role: .user, text: "Codex prompt"))]
        #expect(session.entries.count == 1)

        session.selectProvider(.gemini)
        #expect(session.selectedProvider == .gemini)
        #expect(session.entries.isEmpty)

        session.entries = [.message(AgentMessage(role: .user, text: "Gemini prompt"))]
        #expect(session.entries.count == 1)

        session.selectProvider(.codex)
        #expect(session.selectedProvider == .codex)
        #expect(session.entries.count == 1)
        if case .message(let msg) = session.entries.first {
            #expect(msg.text == "Codex prompt")
        } else {
            Issue.record("Expected Codex message")
        }

        session.selectProvider(.gemini)
        #expect(session.entries.count == 1)
        if case .message(let msg) = session.entries.first {
            #expect(msg.text == "Gemini prompt")
        } else {
            Issue.record("Expected Gemini message")
        }
    }

    // プロバイダーをまたいで特定のスレッドインスタンスへ正確に切り替えられるかを検証
    @Test("AgentSession switches to the exact thread across providers")
    @MainActor
    func agentSessionSwitchesToExactCrossProviderThread() throws {
        let session = AgentSession(executableURL: nil, geminiExecutableURL: nil, defaults: testAgentDefaults())
        session.entries = [.message(AgentMessage(role: .user, text: "Codex thread"))]
        let codexThread = session.activeThread

        session.selectProvider(.gemini)
        session.entries = [.message(AgentMessage(role: .user, text: "Gemini thread"))]
        let geminiThread = session.activeThread

        session.switchToThread(codexThread)
        #expect(session.activeThread.id == codexThread.id)
        #expect(session.activeThread.provider == .codex)
        #expect(session.selectedProvider == .codex)
        #expect(session.entries == codexThread.entries)

        session.switchToThread(geminiThread)
        #expect(session.activeThread.id == geminiThread.id)
        #expect(session.activeThread.provider == .gemini)
        #expect(session.selectedProvider == .gemini)
        #expect(session.entries == geminiThread.entries)
    }

    // エージェントの実行中 (turn 進行中) にプロバイダーやスレッドの切り替え要求を安全に拒絶するかを検証
    @Test("AgentSession rejects provider and thread switches while a turn is running")
    @MainActor
    func agentSessionRejectsSwitchesDuringTurn() async throws {
        try await withTemporaryDirectory { root in
            let executable = root.appendingPathComponent("slow-agent")
            let script = """
            #!/bin/zsh
            sleep 0.3
            printf '%s\\n' '{"type":"item.completed","item":{"id":"message","type":"agent_message","text":"Codex result"}}'
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let session = AgentSession(
                executableURL: executable,
                geminiExecutableURL: executable,
                defaults: testAgentDefaults(),
                useAppServer: false
            )
            session.send("Codex request", in: root)
            let runningThreadID = session.activeThread.id
            let otherThread = AgentThread(provider: .gemini)

            #expect(session.isRunning)
            session.selectProvider(.gemini)
            session.switchToThread(otherThread)
            #expect(session.selectedProvider == .codex)
            #expect(session.activeThread.id == runningThreadID)

            for _ in 0..<40 where session.isRunning {
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            #expect(!session.isRunning)
            #expect(session.selectedProvider == .codex)
            #expect(session.entries.contains { entry in
                guard case .message(let message) = entry else { return false }
                return message.senderName == "CODEX" && message.text == "Codex result"
            })

            session.selectProvider(.gemini)
            #expect(session.selectedProvider == .gemini)
        }
    }

    // Codex と Gemini の会話履歴がそれぞれ独立して復元されるかを検証
    @Test("AgentSession restores Codex and Gemini conversations independently")
    @MainActor
    func agentSessionRestoresProviderThreadsIndependently() throws {
        try withTemporaryDirectory { root in
            let defaults = testAgentDefaults()
            let firstSession = AgentSession(
                executableURL: nil,
                geminiExecutableURL: nil,
                defaults: defaults
            )
            firstSession.loadThreads(for: root)
            firstSession.entries = [.message(AgentMessage(role: .user, text: "Saved Codex conversation"))]
            firstSession.selectProvider(.gemini)
            firstSession.entries = [.message(AgentMessage(role: .user, text: "Saved Gemini conversation"))]
            firstSession.saveCurrentThreads()

            let restoredSession = AgentSession(
                executableURL: nil,
                geminiExecutableURL: nil,
                defaults: defaults
            )
            restoredSession.loadThreads(for: root)

            #expect(restoredSession.selectedProvider == .gemini)
            #expect(restoredSession.activeThread.provider == .gemini)
            #expect(restoredSession.entries.contains { entry in
                guard case .message(let message) = entry else { return false }
                return message.text == "Saved Gemini conversation"
            })

            restoredSession.selectProvider(.codex)
            #expect(restoredSession.activeThread.provider == .codex)
            #expect(restoredSession.entries.contains { entry in
                guard case .message(let message) = entry else { return false }
                return message.text == "Saved Codex conversation"
            })
        }
    }

    // CodexEventParser が非推奨警告 (deprecation warning) のエラー項目を無視するかを検証
    @Test("CodexEventParser ignores deprecation warning error items")
    func codexEventParserIgnoresDeprecationWarnings() {
        let line = """
        {"type":"item.completed","item":{"id":"item_0","type":"error","message":"`[features].web_search_request` is deprecated because web search is enabled by default."}}
        """
        let event = CodexEventParser.parse(line)
        #expect(event == nil)
    }

    // 前回ワークスペース復元設定 (restoreLastWorkspace) の設定保存および起動時復元を検証
    @Test("WorkspaceModel manages restoreLastWorkspace preference and restores workspace on launch")
    @MainActor
    func workspaceRestoresLastWorkspacePreference() throws {
        try withTemporaryDirectory { root in
            let defaults = UserDefaults(suiteName: "TestWorkspaceDefaults_\(UUID().uuidString)")!
            let workspace = WorkspaceModel(defaults: defaults, restoresLastWorkspace: true)
            #expect(workspace.restoresLastWorkspace == true)

            workspace.openWorkspace(root)
            #expect(workspace.lastWorkspacePath == root.standardizedFileURL.path)

            workspace.setRestoresLastWorkspace(false)
            #expect(workspace.restoresLastWorkspace == false)

            // When disabled, a new instance should not reopen
            let reopenedDisabled = WorkspaceModel(defaults: defaults, restoresLastWorkspace: true)
            #expect(reopenedDisabled.rootURL == nil)

            // When re-enabled, a new instance should reopen the last project
            reopenedDisabled.setRestoresLastWorkspace(true)
            let reopenedEnabled = WorkspaceModel(defaults: defaults, restoresLastWorkspace: true)
            #expect(reopenedEnabled.rootURL?.path == root.standardizedFileURL.path)
        }
    }

    // ワークスペースごとの会話スレッドがセッションをまたいで永続化・復元されるかを検証
    @Test("AgentSession persists and restores conversation threads for a workspace")
    @MainActor
    func agentSessionPersistsThreadsAcrossSessions() throws {
        try withTemporaryDirectory { root in
            let session1 = AgentSession(executableURL: nil, geminiExecutableURL: nil)
            session1.loadThreads(for: root)
            #expect(session1.entries.isEmpty)

            session1.entries.append(.message(AgentMessage(role: .user, text: "Hello AI")))
            session1.entries.append(.message(AgentMessage(role: .assistant, text: "Hello User")))
            session1.saveCurrentThreads()

            let session2 = AgentSession(executableURL: nil, geminiExecutableURL: nil)
            session2.loadThreads(for: root)
            #expect(session2.entries.count == 2)
            if case .message(let userMsg) = session2.entries.first {
                #expect(userMsg.text == "Hello AI")
            }
            if case .message(let botMsg) = session2.entries.last {
                #expect(botMsg.text == "Hello User")
            }
        }
    }

    // 読み込み時に破損した永続化スレッド（プロバイダー属性不整合など）を自動修復できるかを検証
    @Test("AgentSession heals corrupted persisted threads on load")
    @MainActor
    func agentSessionHealsCorruptedPersistedThreadsOnLoad() throws {
        try withTemporaryDirectory { root in
            let session = AgentSession(executableURL: nil, geminiExecutableURL: nil)
            let storageURL = session.storageFileURL(for: root)
            try FileManager.default.createDirectory(at: storageURL.deletingLastPathComponent(), withIntermediateDirectories: true)

            // Write a corrupt thread to disk: marked as Gemini, but with codexThreadID and gpt-5.6-sol model
            let corruptJSON = """
            [
              {
                "id": "11111111-1111-1111-1111-111111111111",
                "title": "Corrupt Codex Thread",
                "updatedAt": "2026-09-07T12:00:00Z",
                "model": "gpt-5.6-sol",
                "provider": "Gemini",
                "codexThreadID": "01a06ece-mock-id",
                "entries": [
                  {
                    "type": "message",
                    "message": {
                      "id": "22222222-2222-2222-2222-222222222222",
                      "role": "assistant",
                      "text": "Hello from Codex",
                      "senderName": "CODEX"
                    }
                  }
                ]
              }
            ]
            """
            try corruptJSON.write(to: storageURL, atomically: true, encoding: .utf8)

            session.loadThreads(for: root)

            // The loaded thread should be healed to Codex and put in codexChannel
            let codexThreads = session.threads(for: .codex)
            let geminiThreads = session.threads(for: .gemini)

            #expect(codexThreads.count == 1)
            #expect(codexThreads.first?.provider == .codex)
            #expect(codexThreads.first?.title == "Corrupt Codex Thread")
            #expect(codexThreads.first?.codexThreadID == "01a06ece-mock-id")

            #expect(geminiThreads.isEmpty)

            // Re-read file from disk to verify it was re-saved cleanly
            let reReadData = try Data(contentsOf: storageURL)
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            let reSavedThreads = try decoder.decode([AgentThread].self, from: reReadData)
            #expect(reSavedThreads.count == 1)
            #expect(reSavedThreads.first?.provider == .codex)
        }
    }

    // TerminalSession が複数タブの管理およびタブ切り替えを正しく行えるかを検証
    @Test("TerminalSession manages multiple tabs and tab switching")
    @MainActor
    func terminalSessionManagesMultipleTabs() {
        let terminal = TerminalSession()
        #expect(terminal.tabs.count == 1)
        let firstTab = terminal.tabs[0]
        #expect(terminal.activeTabID == firstTab.id)

        let secondTab = terminal.createTab(title: "Build Task")
        #expect(terminal.tabs.count == 2)
        #expect(terminal.activeTabID == secondTab.id)
        #expect(terminal.activeTab?.id == secondTab.id)

        terminal.selectTab(id: firstTab.id)
        #expect(terminal.activeTabID == firstTab.id)

        terminal.closeTab(id: firstTab.id)
        #expect(terminal.tabs.count == 1)
        #expect(terminal.activeTabID == secondTab.id)
    }

    // SyntaxCheckService が JSON の構文エラーを正確に検知できるかを検証
    @Test("SyntaxCheckService detects JSON syntax errors")
    func syntaxCheckDetectsJSONErrors() async {
        let validJSON = "{\"name\": \"RollCode\", \"version\": 1}"
        let validResult = await SyntaxCheckService.check(
            url: URL(fileURLWithPath: "/tmp/test.json"),
            text: validJSON,
            language: .json
        )
        #expect(validResult.isEmpty)

        let invalidJSON = "{\"name\": \"RollCode\", invalid}"
        let invalidResult = await SyntaxCheckService.check(
            url: URL(fileURLWithPath: "/tmp/test.json"),
            text: invalidJSON,
            language: .json
        )
        #expect(!invalidResult.isEmpty)
        #expect(invalidResult[0].severity == .error)
    }

    // CodeCompletionService が言語キーワードおよびバッファ内の識別子を補完できるかを検証
    @Test("CodeCompletionService completes language keywords and buffer identifiers")
    @MainActor
    func codeCompletionCompletesKeywordsAndBufferWords() {
        let text = """
        struct RollCodeWorkspace {
            let customUserIdentifier = "test"
            func setupWorkspaceEnvironment() {}
        }
        """

        // Test 1: Language keyword prefix
        let keywordMatches = CodeCompletionService.shared.completions(for: "gua", in: text, language: .swift)
        #expect(keywordMatches.contains("guard"))

        // Test 2: Buffer identifier prefix
        let bufferMatches = CodeCompletionService.shared.completions(for: "custom", in: text, language: .swift)
        #expect(bufferMatches.contains("customUserIdentifier"))

        // Test 3: 1-character prefix works
        let oneCharMatches = CodeCompletionService.shared.completions(for: "g", in: text, language: .swift)
        #expect(oneCharMatches.contains("guard"))

        // Test 4: Empty prefix returns empty
        let emptyMatches = CodeCompletionService.shared.completions(for: "", in: text, language: .swift)
        #expect(emptyMatches.isEmpty)

        // Test 5: Language keywords are prioritised first
        let fMatches = CodeCompletionService.shared.completions(for: "f", in: text, language: .swift)
        #expect(fMatches.first == "for" || fMatches.first == "func")
    }

    // WorkspaceModel のタブ並べ替えおよび他のタブを閉じる機能を検証
    @Test("WorkspaceModel supports tab reordering and closing other tabs")
    @MainActor
    func workspaceModelTabManagement() throws {
        let workspace = WorkspaceModel()
        let docA = EditorDocument(url: URL(fileURLWithPath: "/tmp/A.swift"), text: "A")
        let docB = EditorDocument(url: URL(fileURLWithPath: "/tmp/B.swift"), text: "B")
        let docC = EditorDocument(url: URL(fileURLWithPath: "/tmp/C.swift"), text: "C")

        workspace.documents = [docA, docB, docC]
        #expect(workspace.documents.map(\.name) == ["A.swift", "B.swift", "C.swift"])

        // Move C to position 0
        workspace.moveDocument(from: 2, to: 0)
        #expect(workspace.documents.map(\.name) == ["C.swift", "A.swift", "B.swift"])

        // Close others except A
        workspace.closeOtherDocuments(except: docA)
        #expect(workspace.documents.map(\.name) == ["A.swift"])
    }

    // GitBridgeService が diff の行番号を正しく解析できるかを検証
    @Test("GitBridgeService parses diff line numbers correctly")
    func gitDiffServiceLineNumberParsing() throws {
        let sampleDiff = """
@@ -10,3 +10,4 @@
 let a = 1
+let b = 2
+let c = 3
 let d = 4
"""
        let (added, _) = GitBridgeService.diffLineNumbers(for: sampleDiff)
        #expect(added.contains(11))
        #expect(added.contains(12))
        #expect(!added.contains(10))
    }

    // LSPClient が JSON-RPC メッセージを正しく抽出できるかを検証
    @Test("LSPClient extracts JSON-RPC messages correctly")
    func lspClientExtractsJSONRPCMessages() throws {
        let jsonString = "{\"jsonrpc\":\"2.0\",\"id\":42,\"result\":{\"items\":[{\"label\":\"title\"}]}}"
        let jsonBytes = jsonString.data(using: .utf8)!
        let headerString = "Content-Length: \(jsonBytes.count)\r\n\r\n"
        var buffer = headerString.data(using: .utf8)! + jsonBytes

        let message = LSPClient.extractMessage(from: &buffer)
        #expect(message != nil)
        #expect((message?["id"] as? NSNumber)?.intValue == 42)
        #expect(buffer.isEmpty)
    }

    // LanguageServerConfig が利用可能な言語サーバーおよび言語識別子を正しく解決できるかを検証
    @Test("LanguageServerConfig resolves available language servers")
    func languageServerConfigResolves() throws {
        let swiftServer = LanguageServerConfig.resolve(for: CodeLanguage.swift)
        #expect(swiftServer != nil)
        #expect(swiftServer?.languageId == "swift")

        let markdownServer = LanguageServerConfig.resolve(for: CodeLanguage.markdown)
        #expect(markdownServer == nil)

        #expect(LanguageServerConfig.languageIdentifier(
            for: CodeLanguage.cFamily,
            documentURL: URL(fileURLWithPath: "/tmp/main.cpp")
        ) == "cpp")
        #expect(LanguageServerConfig.languageIdentifier(
            for: CodeLanguage.cFamily,
            documentURL: URL(fileURLWithPath: "/tmp/main.mm")
        ) == "objective-cpp")
    }

    // LSPClient が補完レスポンスの両方の形状（リスト・配列）と挿入エディットを正しくデコードできるかを検証
    @Test("LSPClient decodes both completion response shapes and insertion edits")
    func lspClientDecodesCompletions() throws {
        let text = "thing.ti"
        let listResponse: [String: Any] = [
            "result": [
                "items": [[
                    "label": "title: String",
                    "filterText": "title",
                    "detail": "String",
                    "textEdit": [
                        "newText": "title",
                        "range": [
                            "start": ["line": 0, "character": 6],
                            "end": ["line": 0, "character": 8]
                        ]
                    ]
                ]]
            ]
        ]
        let listItems = LSPClient.completionSuggestions(from: listResponse, text: text)
        #expect(listItems.count == 1)
        #expect(listItems[0].label == "title: String")
        #expect(listItems[0].insertText == "title")
        #expect(listItems[0].filterText == "title")
        #expect(listItems[0].replacementRange == NSRange(location: 6, length: 2))

        let arrayResponse: [String: Any] = [
            "result": [[
                "label": "map",
                "insertText": "map(${1:transform})$0",
                "insertTextFormat": 2
            ]]
        ]
        let arrayItems = LSPClient.completionSuggestions(from: arrayResponse, text: text)
        #expect(arrayItems.map(\.insertText) == ["map(transform)"])
    }

    // LSPClient がドキュメントのフォーマット編集を逆順で正しく適用できるかを検証
    @Test("LSPClient applies document formatting edits in reverse order")
    func lspClientAppliesFormattingEdits() {
        let text = "let x=1\n"
        let response: [String: Any] = [
            "result": [
                [
                    "range": [
                        "start": ["line": 0, "character": 5],
                        "end": ["line": 0, "character": 5]
                    ],
                    "newText": " "
                ],
                [
                    "range": [
                        "start": ["line": 0, "character": 6],
                        "end": ["line": 0, "character": 6]
                    ],
                    "newText": " "
                ]
            ]
        ]

        #expect(LSPClient.formattedText(from: response, text: text) == "let x = 1\n")
    }

    // LSPClient が UTF-16 エディタ位置をネゴシエートされたエンコーディング (UTF-8, UTF-16, UTF-32) に正しく変換するかを検証
    @Test("LSPClient converts UTF-16 editor positions to negotiated LSP encodings")
    func lspClientConvertsPositionEncodings() {
        let text = "😀abc"
        #expect(LSPClient.characterOffset(
            in: text,
            line: 0,
            utf16Character: 2,
            positionEncoding: "utf-16"
        ) == 2)
        #expect(LSPClient.characterOffset(
            in: text,
            line: 0,
            utf16Character: 2,
            positionEncoding: "utf-8"
        ) == 4)
        #expect(LSPClient.characterOffset(
            in: text,
            line: 0,
            utf16Character: 2,
            positionEncoding: "utf-32"
        ) == 1)
    }

    // CodeCompletionService が非同期の LSP 補完とローカル補完のブレンドをサポートしているかを検証
    @Test("CodeCompletionService supports async completions blending")
    @MainActor
    func codeCompletionAsyncBlending() async {
        let text = """
        struct Book {
            let title: String
            func read() {}
        }
        let b = Book(title: "Swift")
        """
        let matches = await CodeCompletionService.shared.completions(
            for: "tit",
            in: text,
            language: .swift
        )
        #expect(matches.contains(where: { $0.insertText == "title" }))
    }

    // MarkdownBlockParser がコードブロックと通常テキストを正しく抽出・分離できるかを検証
    @Test("MarkdownBlockParser extracts code blocks and plain text correctly")
    func markdownBlockParserExtractsBlocks() {
        let text = """
        Here is an explanation:
        ```swift
        let answer = 42
        ```
        And conclusion.
        """
        let blocks = MarkdownBlockParser.parse(from: text)
        #expect(blocks.count == 3)
        #expect(blocks[0] == .text("Here is an explanation:"))
        #expect(blocks[1] == .code(language: "swift", code: "let answer = 42"))
        #expect(blocks[2] == .text("And conclusion."))
    }

    // AgentSession が ANSI エスケープカラーシーケンスを綺麗に除去できるかを検証
    @Test("AgentSession strips ANSI color escape codes cleanly")
    func agentSessionStripsANSIEscapes() {
        let raw = "\u{001B}[32mSuccess\u{001B}[0m: \u{001B}[1mUpdated 2 files\u{001B}[0m"
        let stripped = AgentSession.stripANSIEscapes(from: raw)
        #expect(stripped == "Success: Updated 2 files")
    }

    // WorkspaceModel が UI フォントスケール（ズーム）の変更と永続化を正しく管理できるかを検証
    @Test("WorkspaceModel manages and persists uiFontScale levels")
    @MainActor
    func workspaceModelManagesUIFontSize() {
        let suiteName = "RollCodeTest_UIFont_\(UUID().uuidString)"
        let testDefaults = UserDefaults(suiteName: suiteName)!
        defer { testDefaults.removePersistentDomain(forName: suiteName) }

        let workspace = WorkspaceModel(defaults: testDefaults)
        #expect(workspace.uiFontScale == .medium)
        #expect(workspace.uiFontSize == 14.5)

        workspace.zoomInUI()
        #expect(workspace.uiFontScale == .large)
        #expect(workspace.uiFontSize == 16.5)

        workspace.zoomInUI()
        #expect(workspace.uiFontScale == .large)

        workspace.zoomOutUI()
        #expect(workspace.uiFontScale == .medium)

        workspace.zoomOutUI()
        #expect(workspace.uiFontScale == .small)
        #expect(workspace.uiFontSize == 12.5)

        workspace.resetUIZoom()
        #expect(workspace.uiFontScale == .medium)

        workspace.setUIFontScale(.large)
        let restored = WorkspaceModel(defaults: testDefaults)
        #expect(restored.uiFontScale == .large)
        #expect(restored.uiFontSize == 16.5)
    }

    // GeminiAuthService が保存された設定および projects.json から有効な Project ID を解決できるかを検証
    @Test("GeminiAuthService resolves effectiveProjectID from stored setting and projects.json")
    @MainActor
    func geminiAuthServiceResolvesProjectID() throws {
        try withTemporaryDirectory { tempDir in
            let geminiDir = tempDir.appending(path: ".gemini")
            try FileManager.default.createDirectory(at: geminiDir, withIntermediateDirectories: true)
            let projectsJSON = """
            {
              "projects": {
                "/Users/test/ProjectA": "project-alpha",
                "/": "project-default"
              }
            }
            """
            try projectsJSON.write(to: geminiDir.appending(path: "projects.json"), atomically: true, encoding: .utf8)

            let suiteName = "RollCodeTest_Gemini_\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defer { defaults.removePersistentDomain(forName: suiteName) }

            let service = GeminiAuthService(geminiDirURL: geminiDir, defaults: defaults, isCLIAvailable: { true })
            
            // 1. Matches workspace path
            let matched = service.effectiveProjectID(for: URL(fileURLWithPath: "/Users/test/ProjectA/src"))
            #expect(matched == "project-alpha")

            // 2. Fallbacks to default
            let fallback = service.effectiveProjectID(for: URL(fileURLWithPath: "/Users/test/Other"))
            #expect(fallback == "project-default")

            // 3. Stored project takes precedence
            service.storedProjectID = "explicit-project"
            #expect(service.effectiveProjectID(for: URL(fileURLWithPath: "/Users/test/ProjectA")) == "explicit-project")
        }
    }

    // ModelCatalogService が Gemini API の JSON をパースしスピード階層を付与できるかを検証
    @Test("ModelCatalogService parses Gemini API JSON and assigns speed tiers")
    func modelCatalogServiceParsesGeminiModels() throws {
        let json = """
        {
          "models": [
            {
              "name": "models/gemini-2.5-flash",
              "displayName": "Gemini 2.5 Flash",
              "supportedGenerationMethods": ["generateContent", "countTokens"]
            },
            {
              "name": "models/gemini-2.5-pro",
              "displayName": "Gemini 2.5 Pro",
              "supportedGenerationMethods": ["generateContent"]
            },
            {
              "name": "models/text-embedding-004",
              "displayName": "Embedding",
              "supportedGenerationMethods": ["embedContent"]
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try #require(ModelCatalogService.parseGeminiModels(data: json))
        #expect(parsed.count == 2)
        #expect(parsed[0].id == "gemini-2.5-pro")
        #expect(parsed[0].speedTier == .deep)
        #expect(parsed[1].id == "gemini-2.5-flash")
        #expect(parsed[1].speedTier == .fast)
    }

    // ModelCatalogService が Vertex AI 公開モデル JSON をパースし、非チャットモデルを除外して最新モデルを最上位にするかを検証
    @Test("ModelCatalogService parses Vertex AI publisher models JSON, filters non-chat, and ranks gemini-3.8-flash highest")
    func modelCatalogServiceParsesVertexGeminiModels() throws {
        let json = """
        {
          "publisherModels": [
            {
              "name": "publishers/google/models/gemini-2.5-flash",
              "versionId": "default"
            },
            {
              "name": "publishers/google/models/gemini-3.8-flash",
              "versionId": "default"
            },
            {
              "name": "publishers/google/models/gemini-2.5-pro",
              "versionId": "default"
            },
            {
              "name": "publishers/google/models/gemini-embedding-001",
              "versionId": "default"
            },
            {
              "name": "publishers/google/models/gemini-2.5-pro-tts",
              "versionId": "default"
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try #require(ModelCatalogService.parseVertexGeminiModels(data: json))
        #expect(parsed.count == 3)
        #expect(parsed[0].id == "gemini-3.8-flash")
        #expect(parsed[0].speedTier == .fast)
        #expect(parsed[0].displayName == "Gemini 3.8 Flash")
        #expect(parsed[1].id == "gemini-2.5-pro")
        #expect(parsed[1].speedTier == .deep)
        #expect(parsed[2].id == "gemini-2.5-flash")
        #expect(parsed[2].speedTier == .fast)
    }

    // ModelCatalogService が思考力 (reasoning support) 対応の Codex キャッシュ JSON をパースできるかを検証
    @Test("ModelCatalogService parses Codex cache JSON with reasoning support")
    func modelCatalogServiceParsesCodexCache() throws {
        let json = """
        {
          "models": [
            {
              "slug": "gpt-5.6-sol",
              "display_name": "GPT-5.6-Sol",
              "supported_reasoning_efforts": ["low", "medium", "high"]
            },
            {
              "slug": "gpt-5.4-mini",
              "display_name": "GPT-5.4-Mini"
            }
          ]
        }
        """.data(using: .utf8)!

        let parsed = try #require(ModelCatalogService.parseCodexCache(data: json))
        #expect(parsed.count == 2)
        #expect(parsed[0].id == "gpt-5.6-sol")
        #expect(parsed[0].supportsReasoningEffort)
        #expect(parsed[0].speedTier == .deep)
        #expect(parsed[1].id == "gpt-5.4-mini")
        #expect(parsed[1].speedTier == .fast)
    }

    // AgentTokenUsage がトークン表記文字列を正しく解析できるかを検証
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

    // AgentSession がモデル選択、推論深度 (reasoning effort) を管理しトークン使用量を記録できるかを検証
    @Test("AgentSession manages model selection, reasoning effort, and tracks token usage")
    @MainActor
    func agentSessionManagesModelAndTracksTokens() async throws {
        try await withTemporaryDirectory { root in
            let executable = root.appendingPathComponent("fake-agent")
            let script = """
            #!/bin/zsh
            printf '%s\\n' '{"type":"thread.started","thread_id":"fake-thread"}'
            printf '%s\\n' '{"type":"turn.completed","usage":{"input_tokens":50,"cached_input_tokens":15,"output_tokens":25}}'
            """
            try script.write(to: executable, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)

            let agent = AgentSession(executableURL: executable, defaults: testAgentDefaults())
            agent.setModel("gpt-5.6-sol")
            agent.setReasoningEffort(.high)

            #expect(agent.currentModel == "gpt-5.6-sol")
            #expect(agent.currentReasoningEffort == .high)

            agent.send("Hello", in: root)
            for _ in 0..<40 where agent.isRunning {
                try await Task.sleep(nanoseconds: 50_000_000)
            }

            #expect(!agent.isRunning)
            #expect(agent.activeThread.inputTokens == 50)
            #expect(agent.activeThread.outputTokens == 25)
            #expect(agent.activeThread.cachedTokens == 15)
            #expect(agent.totalTokens == 75)
            #expect(agent.lastTurnDuration != nil)
        }
    }

    // CodexAppServerClient JSONDictionary のキーアクセスとスレッド安全性を検証
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

    // AgentSession が useAppServer フラグとそのフォールバックをサポートしているかを検証
    @Test("AgentSession supports useAppServer flag and fallback")
    @MainActor
    func agentSessionSupportsUseAppServer() {
        let sessionDefault = AgentSession(executableURL: nil, geminiExecutableURL: nil)
        #expect(sessionDefault.useAppServer == false)

        let sessionExplicitTrue = AgentSession(executableURL: nil, geminiExecutableURL: nil, useAppServer: true)
        #expect(sessionExplicitTrue.useAppServer == true)
    }

    // WorkspaceModel が自動保存有効化およびアプリテーマ設定の変更・永続化を正しく行えるかを検証
    @Test("WorkspaceModel manages autoSaveEnabled and appTheme preferences")
    @MainActor
    func workspaceModelManagesPreferences() {
        let suiteName = "TestPreferences_\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        let model = WorkspaceModel(defaults: defaults, restoresLastWorkspace: false)

        #expect(model.autoSaveEnabled == true)
        #expect(model.appTheme == .system)

        model.setAutoSaveEnabled(false)
        #expect(model.autoSaveEnabled == false)

        model.setAppTheme(.dark)
        #expect(model.appTheme == .dark)
        #expect(model.appTheme.colorScheme == .dark)

        model.setAppTheme(.light)
        #expect(model.appTheme.colorScheme == .light)
    }

    // クエリが空のとき Quick Open で最近開いたファイル (MRU) が優先表示されるかを検証
    @Test("WorkspaceModel prioritizes recent files in quick open when query is empty")
    @MainActor
    func workspaceModelPrioritizesRecentFiles() throws {
        try withTemporaryDirectory { root in
            let fileA = root.appendingPathComponent("alpha.swift")
            let fileB = root.appendingPathComponent("beta.swift")
            try "let a = 1".write(to: fileA, atomically: true, encoding: .utf8)
            try "let b = 2".write(to: fileB, atomically: true, encoding: .utf8)

            let suiteName = "TestMRU_\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            let model = WorkspaceModel(defaults: defaults, restoresLastWorkspace: false)
            model.openWorkspace(root)
            model.rootNode = FileNode.buildTree(at: root)

            model.openFile(fileA)
            model.openFile(fileB) // Most recent is beta.swift

            let quickOpenEmpty = model.quickOpenFiles(matching: "")
            #expect(quickOpenEmpty.first?.name == "beta.swift")
        }
    }

    // EditorDocument のエンコーディング判定および表示名取得機能を検証
    @Test("EditorDocument supports encoding detection and display name")
    @MainActor
    func editorDocumentEncodingSupport() throws {
        let url = URL(fileURLWithPath: "/tmp/test.txt")
        let docUtf8 = EditorDocument(url: url, text: "hello", encoding: .utf8)
        #expect(docUtf8.encodingDisplayName == "UTF-8")

        let docSJIS = EditorDocument(url: url, text: "こんにちは", encoding: .shiftJIS)
        #expect(docSJIS.encodingDisplayName == "Shift-JIS")
    }
}

@MainActor
private func withTemporaryDirectory<T>(_ operation: (URL) async throws -> T) async throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try await operation(root)
}

private func withTemporaryDirectory<T>(_ operation: (URL) throws -> T) throws -> T {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    return try operation(root)
}

private func testAgentDefaults(provider: AgentProvider = .codex) -> UserDefaults {
    let suiteName = "TestAgentDefaults_\(UUID().uuidString)"
    let defaults = UserDefaults(suiteName: suiteName)!
    defaults.set(provider.rawValue, forKey: AgentSession.providerDefaultsKey)
    return defaults
}

private func runGit(_ arguments: [String], in directory: URL) throws {
    _ = try runGitOutput(arguments, in: directory)
}

private func runGitOutput(_ arguments: [String], in directory: URL) throws -> String {
    let process = Process()
    let output = Pipe()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
    process.arguments = ["-C", directory.path] + arguments
    process.standardOutput = output
    process.standardError = output
    try process.run()
    let data = output.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    guard process.terminationStatus == 0 else {
        throw GitDiffError.commandFailed(String(decoding: data, as: UTF8.self))
    }
    return String(decoding: data, as: UTF8.self)
}
