import XCTest
@testable import MermaidLayout

/// Numbers in Mermaid sources are untrusted text. Each case here used to (or
/// could) trap on Int overflow; they must parse to a bounded diagram or be
/// rejected with a diagnostic, never crash the host.
final class IntegerSafetyTests: XCTestCase {

    private func numbers(_ source: String) throws -> [Int?] {
        guard case .sequence(let diagram)? = MermaidParser.parse(source) else {
            XCTFail("expected a sequence diagram: \(source)")
            return []
        }
        return diagram.messages.map(\.number)
    }

    private func sequence(_ autonumber: String) -> String {
        "sequenceDiagram\n  \(autonumber)\n  A->>B: one\n  B->>A: two\n  A->>B: three"
    }

    /// The evaluation's reproduced crash: the second message's increment
    /// overflowed `Int` and trapped at `autonumber += autonumberStep`.
    func testAutonumberAtIntMaxSaturatesWithNote() throws {
        let source = sequence("autonumber 9223372036854775807")
        XCTAssertEqual(try numbers(source), [Int.max, Int.max, Int.max])
        let notes = MermaidParser.diagnose(source)
        XCTAssertEqual(notes.map(\.code), [.valueClamped])
        XCTAssertEqual(notes.first?.severity, .note)
        XCTAssertEqual(notes.first?.line, 3)
    }

    func testAutonumberStepOverflowSaturates() throws {
        let source = sequence("autonumber 9223372036854775000 9223372036854775000")
        XCTAssertEqual(try numbers(source), [9223372036854775000, Int.max, Int.max])
    }

    func testAutonumberBeyondIntRangeIsClamped() throws {
        let source = sequence("autonumber 99999999999999999999999")
        XCTAssertEqual(try numbers(source), [Int.max, Int.max, Int.max])
        XCTAssertTrue(MermaidParser.diagnose(source).allSatisfy { $0.code == .valueClamped })
        XCTAssertFalse(MermaidParser.diagnose(source).isEmpty)
    }

    /// mermaid.js treats a 0 start or step as unset and falls back to 1.
    func testAutonumberZeroFallsBackToOne() throws {
        XCTAssertEqual(try numbers(sequence("autonumber 0")), [1, 2, 3])
        XCTAssertEqual(try numbers(sequence("autonumber 5 0")), [5, 6, 7])
        XCTAssertEqual(try numbers(sequence("autonumber 10 5")), [10, 15, 20])
        XCTAssertEqual(try numbers(sequence("autonumber")), [1, 2, 3])
        XCTAssertEqual(MermaidParser.diagnose(sequence("autonumber 10 5")), [])
    }

    func testAutonumberOffStopsNumbering() throws {
        let source = "sequenceDiagram\n  autonumber\n  A->>B: one\n  autonumber off\n  B->>A: two"
        XCTAssertEqual(try numbers(source), [1, nil])
    }

    func testAutonumberFractionIsTruncatedWithNote() throws {
        let source = sequence("autonumber 1.5")
        XCTAssertEqual(try numbers(source), [1, 2, 3])
        XCTAssertEqual(MermaidParser.diagnose(source).map(\.code), [.unsupportedFeature])
    }

    /// mermaid.js rejects signs, words, and extra operands; so do we.
    func testAutonumberRejectsWhatMermaidRejects() {
        for operands in ["autonumber -3 2", "autonumber 1 -1", "autonumber x", "autonumber 10 abc", "autonumber 1 2 3"] {
            let source = sequence(operands)
            XCTAssertNil(MermaidParser.parse(source), operands)
            let diagnostics = MermaidParser.diagnose(source)
            XCTAssertEqual(diagnostics.map(\.code), [.invalidSyntax], operands)
            XCTAssertEqual(diagnostics.first?.line, 2, operands)
        }
    }

    /// Other numeric operands that reach Int arithmetic stay bounded.
    func testHugeNumericOperandsElsewhereDoNotTrap() {
        let sources = [
            "packet-beta\n  0-9223372036854775807: \"all\"\n  9223372036854775807: \"last\"",
            "packet-beta\n  +9223372036854775807: \"wide\"",
            "radar-beta\n  axis a, b, c\n  curve x{1, 2, 3}\n  ticks 9223372036854775807",
            "block-beta\n  columns 9223372036854775807\n  a b c",
            "journey\n  section S\n    Task: 9223372036854775807: Me",
            "xychart-beta\n  x-axis [a, b]\n  y-axis 0 --> 1e300\n  bar [1e300, 9223372036854775807]",
            "treemap-beta\n\"Root\"\n    \"A\": 1e300\n    \"B\": 9223372036854775807",
            "pie\n  \"A\" : 1e308\n  \"B\" : 9223372036854775807",
        ]
        let measure: DiagramTextMeasurer = { text, size in
            CGSize(width: CGFloat(max(text.count, 1)) * size * 0.6, height: size + 4)
        }
        let theme = RenderTheme(
            ink: DiagramColor(hex: 0x1D1D1F), accent: DiagramColor(hex: 0x5B8FF9),
            canvas: DiagramColor(hex: 0xFFFFFF), hairline: DiagramColor(hex: 0x000000, alpha: 0.12),
            secondaryText: DiagramColor(hex: 0x1D1D1F, alpha: 0.55),
            tertiaryText: DiagramColor(hex: 0x1D1D1F, alpha: 0.38),
            palette: [DiagramColor(hex: 0x5B8FF9), DiagramColor(hex: 0x61DDAA)])
        for source in sources {
            guard let diagram = MermaidParser.parse(source) else { continue }
            let scene = RenderScene.from(diagram, theme: theme, measure: measure)
            XCTAssertNotNil(scene, source)
            if let scene {
                XCTAssertTrue(scene.size.width.isFinite && scene.size.height.isFinite, source)
            }
            _ = MermaidParser.diagnose(source)
        }
    }
}
