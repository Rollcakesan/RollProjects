import Foundation
import Testing
@testable import GitBridgeKit

@Suite("GitBridgeKit Tests")
struct GitBridgeKitTests {
    // unified diff の追加行番号を正しく解析できるかを検証
    @Test("diffLineNumbers correctly parses unified diff addition lines")
    func diffLineNumbersParsesAddedLines() {
        let sampleDiff = """
        diff --git a/test.txt b/test.txt
        index 123..456 100644
        --- a/test.txt
        +++ b/test.txt
        @@ -1,3 +1,5 @@
         first line
        +second line
        +third line
         fourth line
        """
        let (added, modified) = GitBridgeService.diffLineNumbers(for: sampleDiff)
        #expect(added == [2, 3])
        #expect(modified.isEmpty)
    }

    // git status の -z (ヌル文字区切り) porcelain フォーマットを正しくパースできるかを検証
    @Test("statusEntries parses porcelain z-format strings")
    func statusEntriesParsesNullDelimitedFields() {
        let nullByte = "\0"
        let raw = " M file1.swift\(nullByte)?? file2.txt\(nullByte)"
        let entries = GitBridgeService.statusEntries(from: raw)
        #expect(entries.count == 2)
        #expect(entries[0].status == " M")
        #expect(entries[0].path == "file1.swift")
        #expect(entries[1].status == "??")
        #expect(entries[1].path == "file2.txt")
    }

    // GitChange モデルが Identifiable および Equatable に準拠しているかを検証
    @Test("GitChange models conform to Identifiable and Equatable")
    func gitChangeProperties() {
        let change = GitChange(path: "Sources/App.swift", status: "M ", diff: "+let a = 1")
        #expect(change.id == "Sources/App.swift")
        #expect(change.path == "Sources/App.swift")
        #expect(change.status == "M ")
    }
}
