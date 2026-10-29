import XCTest
@testable import MermaidLayout

/// mermaid.js normalizes `\r\n` and lone `\r` to `\n` before parsing. Swift
/// treats `\r\n` as one `Character`, so before normalization a CRLF source
/// never split into lines and every diagram failed to parse.
final class LineEndingTests: XCTestCase {

    private let sources = [
        "flowchart TD\n  A --> B\n  B --> C\n",
        "sequenceDiagram\n  Alice->>Bob: hi\n  Bob-->>Alice: hello\n",
        "stateDiagram-v2\n  [*] --> Idle\n  Idle --> Busy\n",
        "pie title Pets\n  \"Dogs\" : 3\n  \"Cats\" : 2\n",
        "mindmap\n  root\n    child one\n    child two\n",
        "---\ntitle: Captioned\n---\nflowchart LR\n  A --> B\n",
    ]

    func testCRLFParsesLikeLF() throws {
        for lf in sources {
            let crlf = lf.replacingOccurrences(of: "\n", with: "\r\n")
            let expected = try XCTUnwrap(MermaidParser.parseWithMetadata(lf), lf)
            let actual = try XCTUnwrap(MermaidParser.parseWithMetadata(crlf), crlf.debugDescription)
            XCTAssertEqual(actual.diagram, expected.diagram, lf)
            XCTAssertEqual(actual.metadata, expected.metadata, lf)
            XCTAssertEqual(MermaidParser.diagnose(crlf), MermaidParser.diagnose(lf), lf)
        }
    }

    func testLoneCarriageReturnParsesLikeLF() throws {
        for lf in sources {
            let cr = lf.replacingOccurrences(of: "\n", with: "\r")
            XCTAssertEqual(MermaidParser.parse(cr), MermaidParser.parse(lf), cr.debugDescription)
        }
    }

    func testMixedLineEndingsKeepLineNumbers() {
        let source = "flowchart LR\r\n  A --> B\r  this is not mermaid ]]]\n  B --> C"
        XCTAssertNotNil(MermaidParser.parse(source))
        XCTAssertEqual(MermaidParser.diagnose(source).map(\.line), [3])
    }

    func testMetadataReadsThroughCRLF() {
        let metadata = MermaidParser.metadata(in: "---\r\ntitle: Hello\r\n---\r\nflowchart LR\r\n  A --> B")
        XCTAssertEqual(metadata.title, "Hello")
    }
}
