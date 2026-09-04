import Testing
import Foundation
@testable import WorkspaceIndexKit

@Suite("WorkspaceIndexKit Tests")
struct WorkspaceIndexKitTests {
    @Test("QuickOpenMatcher scores exact and fuzzy matches")
    func testQuickOpenMatcher() {
        let exactScore = QuickOpenMatcher.score(query: "main", candidate: "main.swift")
        #expect(exactScore != nil)

        let fuzzyScore = QuickOpenMatcher.score(query: "msw", candidate: "main.swift")
        #expect(fuzzyScore != nil)

        let noMatch = QuickOpenMatcher.score(query: "xyz", candidate: "main.swift")
        #expect(noMatch == nil)
    }

    @Test("WorkspaceSearch finds matches and performs replacement")
    func testWorkspaceSearchAndReplace() {
        let fileURL = URL(fileURLWithPath: "/workspace/File.swift")
        let rootURL = URL(fileURLWithPath: "/workspace")
        let text = """
        let foo = 1
        let bar = 2
        let fooBar = foo + bar
        """
        let files = [WorkspaceSearchFile(url: fileURL, text: text)]

        let matches = WorkspaceSearch.matches(for: "foo", in: files, relativeTo: rootURL)
        #expect(matches.count == 2)
        #expect(matches[0].line == 1)
        #expect(matches[1].line == 3)

        let replacements = WorkspaceSearch.replacements(of: "foo", with: "baz", in: files)
        #expect(replacements.count == 1)
        #expect(replacements[0].occurrences == 3)
        #expect(replacements[0].text.contains("let baz = 1"))
    }

    @Test("FileNode builds tree from directory")
    func testFileNodeTree() {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let fileA = tempDir.appendingPathComponent("TestA.swift")
        let fileB = tempDir.appendingPathComponent("TestB.txt")
        try? "content".write(to: fileA, atomically: true, encoding: .utf8)
        try? "content".write(to: fileB, atomically: true, encoding: .utf8)

        let root = FileNode.buildTree(at: tempDir)
        #expect(root.children?.count == 2)
        #expect(root.matchingFiles("TestA").count == 1)
        #expect(root.flattenedFiles.count == 2)
    }
}
