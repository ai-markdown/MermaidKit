import XCTest
@testable import MermaidLayout

/// Inputs mermaid.js 11.17.2 rejects used to render here without any
/// diagnostic. Clear syntax errors now fail the parse like mermaid.js; inputs
/// this package can still draw render with an `.invalidSyntax` note.
final class MermaidCompatibilityTests: XCTestCase {

    private func assertRejected(_ source: String, line: Int?, file: StaticString = #filePath, lineNumber: UInt = #line) {
        XCTAssertNil(MermaidParser.parse(source), source, file: file, line: lineNumber)
        let diagnostics = MermaidParser.diagnose(source)
        XCTAssertEqual(diagnostics.map(\.code), [.invalidSyntax], source, file: file, line: lineNumber)
        XCTAssertEqual(diagnostics.first?.severity, .error, source, file: file, line: lineNumber)
        XCTAssertEqual(diagnostics.first?.line, line, source, file: file, line: lineNumber)
    }

    private func assertRenderedWithNote(_ source: String, line: Int?, file: StaticString = #filePath, lineNumber: UInt = #line) {
        XCTAssertNotNil(MermaidParser.parse(source), source, file: file, line: lineNumber)
        let diagnostics = MermaidParser.diagnose(source)
        XCTAssertFalse(diagnostics.isEmpty, source, file: file, line: lineNumber)
        XCTAssertTrue(diagnostics.allSatisfy { $0.severity == .note && $0.code == .invalidSyntax }, "\(diagnostics)",
                      file: file, line: lineNumber)
        XCTAssertEqual(diagnostics.first?.line, line, source, file: file, line: lineNumber)
    }

    // MARK: Rejected like mermaid.js

    func testSequenceMessageWithoutReceiverIsRejected() {
        assertRejected("sequenceDiagram\n  Alice->>: missing target", line: 2)
    }

    func testSequenceUnclosedBlocksAreRejected() {
        assertRejected("sequenceDiagram\n  loop forever\n    A->>B: x", line: nil)
        assertRejected("sequenceDiagram\n  box Group\n  participant A\n  A->>A: x", line: nil)
    }

    func testSequenceStrayEndIsRejected() {
        assertRejected("sequenceDiagram\n  A->>B: x\n  end", line: 3)
    }

    func testPieSyntaxMermaidRejects() {
        assertRejected("pie title 分布\n  中文 : 55\n  英文 : 45", line: 2)
        assertRejected("pie\n  \"A\" : 1e308\n  \"B\" : 1e308", line: 2)
        assertRejected("pie\n  \"A\" : -3", line: 2)
        assertRejected("pie\n  \"A\" : 3\n  \"B\" : .5", line: 3)
    }

    // MARK: Rendered with a note

    func testNonASCIINamesMermaidRejectsAreNoted() {
        assertRenderedWithNote("sankey-beta\n\n中文,日本語,10\n中文,한국어,5", line: 3)
        assertRenderedWithNote(
            "gitGraph\n  commit id: \"初始提交\"\n  branch 开发分支\n  checkout 开发分支\n  commit id: \"增加语料\"", line: 3)
        assertRenderedWithNote(
            "xychart-beta\n  title \"月度请求量\"\n  x-axis [一月, 二月, 三月]\n  y-axis \"请求数\" 0 --> 100\n  bar [30, 60, 90]", line: 3)
        assertRenderedWithNote(
            "xychart-beta\n  title 月度请求量\n  x-axis [\"一月\", \"二月\"]\n  y-axis \"请求数\" 0 --> 100\n  bar [30, 60]", line: 2)
        assertRenderedWithNote(
            "requirementDiagram\n  requirement 性能要求 {\n    id: 1\n    text: 首屏小于一秒\n    risk: high\n    verifymethod: test\n  }",
            line: 2)
        assertRenderedWithNote(
            "wardley-beta\n  title 语料作为一项能力\n  anchor 读者 [0.95, 0.60]\n  component 渲染结果 [0.85, 0.65]\n  读者 -> 渲染结果",
            line: 3)
    }

    func testZenUMLIsNotedAsAPluginDiagram() {
        assertRenderedWithNote("zenuml\n  title Demo\n  Alice->Bob: hello\n  Bob->Alice: hi", line: nil)
    }

    // MARK: Valid controls stay clean

    func testValidEquivalentsHaveNoDiagnostics() {
        let sources = [
            "sequenceDiagram\n  loop forever\n    A->>B: x\n  end",
            "sequenceDiagram\n  box Group\n  participant A\n  end\n  A->>A: x",
            "sequenceDiagram\n  alt ok\n    A->>B: yes\n  else no\n    A->>B: no\n  end",
            "pie showData\n  title Pets\n  \"Dogs\" : 3\n  \"Cats\" : 2.5\n  \"中文\" : 99999999999",
            "sankey-beta\n\nA,B,10\n\"A, b\",C,5",
            "gitGraph\n  commit\n  branch dev-1/x\n  checkout dev-1/x\n  commit",
            "xychart-beta\n  title \"月度\"\n  x-axis [\"一月\", \"二月\"]\n  bar [1, 2]",
            "wardley-beta\n  title 语料\n  anchor Reader [0.95, 0.60]\n  component Render [0.85, 0.65]\n  Reader -> Render",
        ]
        for source in sources {
            XCTAssertNotNil(MermaidParser.parse(source), source)
            XCTAssertEqual(MermaidParser.diagnose(source), [], source)
        }
    }
}
