import XCTest
@testable import MermaidLayout
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Regression tests for content that used to parse into nothing and vanish
/// from the render: cynefin inline items, ER key markers and comments, and
/// state notes.
final class DroppedContentTests: XCTestCase {

    /// Deterministic fake measurer that honors line breaks like the real one.
    let measure: DiagramTextMeasurer = { text, size in
        let lines = DiagramLayoutEngine.brLines(text)
        let widest = lines.map(\.count).max() ?? 1
        return CGSize(width: CGFloat(max(widest, 1)) * size * 0.5,
                      height: CGFloat(max(lines.count, 1)) * (size + 4))
    }

    let theme = RenderTheme(
        ink: DiagramColor(hex: 0x1D1D1F), accent: DiagramColor(hex: 0x5B8FF9),
        canvas: DiagramColor(hex: 0xFFFFFF), hairline: DiagramColor(hex: 0x000000, alpha: 0.12),
        secondaryText: DiagramColor(hex: 0x1D1D1F, alpha: 0.55))

    func svg(_ diagram: MermaidDiagram) throws -> String {
        let scene = try XCTUnwrap(RenderScene.from(diagram, theme: theme, measure: measure))
        return SVGRenderer.svg(scene)
    }

    func sceneTexts(_ diagram: MermaidDiagram) throws -> [String] {
        let scene = try XCTUnwrap(RenderScene.from(diagram, theme: theme, measure: measure))
        return scene.elements.compactMap { if case .text(let t) = $0 { return t.string } else { return nil } }
    }

    // MARK: Cynefin

    func testCynefinInlineItemsOnTheDomainLine() throws {
        let source = """
        cynefin-beta
          title Where each failure lived
          clear "Missing package.json script"
          complicated "Freeze boundary off by a line" "Second"
          complex "Superlinearity that was update count"
          chaotic "Force-pushed tags re-firing releases"
          confusion 'Unsure'
          clear --> complicated
        """
        let diagram = try XCTUnwrap(MermaidParser.parse(source))
        guard case .cynefin(let cynefin) = diagram else { return XCTFail("expected cynefin") }
        XCTAssertEqual(cynefin.items[.clear], ["Missing package.json script"])
        XCTAssertEqual(cynefin.items[.complicated], ["Freeze boundary off by a line", "Second"])
        XCTAssertEqual(cynefin.items[.complex], ["Superlinearity that was update count"])
        XCTAssertEqual(cynefin.items[.chaotic], ["Force-pushed tags re-firing releases"])
        XCTAssertEqual(cynefin.items[.confusion], ["Unsure"])
        XCTAssertEqual(cynefin.transitions.count, 1)
        XCTAssertEqual(MermaidParser.diagnose(source), [])

        let texts = try sceneTexts(diagram)
        for item in ["Missing package.json script", "Freeze boundary off by a line", "Second",
                     "Superlinearity that was update count", "Force-pushed tags re-firing releases", "Unsure"] {
            XCTAssertTrue(texts.contains(item), "\(item) missing from the scene")
            XCTAssertTrue(try svg(diagram).contains(">\(item)<"), "\(item) missing from the SVG")
        }
    }

    func testCynefinBlockAndMixedForms() throws {
        let source = "cynefin-beta\n  clear\n    \"A\"\n    \"B\" \"C\"\n  complex \"D\"\n    \"E\"\n  chaotic \"F\" clear \"G\""
        guard case .cynefin(let cynefin) = try XCTUnwrap(MermaidParser.parse(source)) else {
            return XCTFail("expected cynefin")
        }
        XCTAssertEqual(cynefin.items[.clear], ["A", "B", "C", "G"])
        XCTAssertEqual(cynefin.items[.complex], ["D", "E"])
        XCTAssertEqual(cynefin.items[.chaotic], ["F"])
    }

    func testCynefinRejectsWhatMermaidRejects() {
        for source in ["cynefin-beta\n  clear {\n    \"A\"\n  }",
                       "cynefin-beta\n  clear A",
                       "cynefin-beta\n  \"orphan\"\n  clear \"B\"",
                       "cynefin-beta\n  clear \"A\"\n  clear --> nowhere"] {
            XCTAssertNil(MermaidParser.parse(source), source)
            XCTAssertEqual(MermaidParser.diagnose(source).first?.code, .invalidSyntax, source)
        }
    }

    func testCynefinLongAndManyItemsDoNotOverlap() throws {
        let long = String(repeating: "word ", count: 30).trimmingCharacters(in: .whitespaces)
        let source = """
        cynefin-beta
          clear "\(long)" "two" "three" "four" "five" "six"
          complex "\(long)" "B" "C" "D" "E" "F" "G" "H"
          chaotic "x" "\(long)"
          complicated "y"
          confusion "one" "two" "three" "\(long)"
        """
        guard case .cynefin(let cynefin) = try XCTUnwrap(MermaidParser.parse(source)) else {
            return XCTFail("expected cynefin")
        }
        let layout = DiagramLayoutEngine.layout(cynefin, measure: measure)
        let disk = try XCTUnwrap(layout.center)
        XCTAssertEqual(disk.items.count, 4, "every confusion item is laid out")
        let diskCenter = CGPoint(x: disk.frame.midX, y: disk.frame.midY)
        for quadrant in layout.quadrants {
            var rects: [CGRect] = []
            for item in quadrant.items {
                let size = measure(item.text, DiagramLayoutEngine.labelFontSize)
                let rect = CGRect(x: item.center.x - size.width / 2, y: item.center.y - size.height / 2,
                                  width: size.width, height: size.height)
                XCTAssertTrue(quadrant.frame.contains(rect), "\(quadrant.domain) item escapes its quadrant")
                for other in rects { XCTAssertFalse(other.intersects(rect), "items overlap in \(quadrant.domain)") }
                // Nearest point of the rect to the disk center stays outside the disk.
                let nx = min(max(diskCenter.x, rect.minX), rect.maxX)
                let ny = min(max(diskCenter.y, rect.minY), rect.maxY)
                XCTAssertGreaterThanOrEqual(hypot(nx - diskCenter.x, ny - diskCenter.y), layout.centerRadius,
                                            "\(quadrant.domain) item runs under the confusion disk")
                rects.append(rect)
            }
        }
    }

    // MARK: ER

    func testERKeysAndCommentsAreParsedAndDrawn() throws {
        let source = """
        erDiagram
          CUSTOMER ||--o{ ORDER : places
          CUSTOMER {
            string name PK
            string email UK "login"
            int org FK
            int both PK, FK "composite key"
            int tight fk,pk
            int note "just a comment"
            varchar(255) plain
          }
        """
        let diagram = try XCTUnwrap(MermaidParser.parse(source))
        guard case .er(let er) = diagram else { return XCTFail("expected er") }
        let attributes = try XCTUnwrap(er.entities.first { $0.name == "CUSTOMER" }).attributes
        XCTAssertEqual(attributes.map(\.name), ["name", "email", "org", "both", "tight", "note", "plain"])
        XCTAssertEqual(attributes.map(\.keys), [[.primary], [.unique], [.foreign], [.primary, .foreign],
                                                [.foreign, .primary], [], []])
        XCTAssertEqual(attributes.map(\.comment), [nil, "login", nil, "composite key", nil, "just a comment", nil])
        XCTAssertEqual(attributes.last?.type, "varchar(255)")
        XCTAssertEqual(MermaidParser.diagnose(source), [])

        let svg = try svg(diagram)
        for text in ["PK", "UK", "FK", "PK,FK", "FK,PK", "login", "composite key", "just a comment"] {
            XCTAssertTrue(svg.contains(">\(text)<"), "\(text) missing from the SVG")
        }
        // The comment column sits right of every badge and inside the box.
        let layout = DiagramLayoutEngine.layout(er, measure: measure)
        let box = try XCTUnwrap(layout.boxes.first { $0.name == "CUSTOMER" })
        XCTAssertGreaterThan(box.commentColumnWidth, 0)
        XCTAssertLessThan(box.badgeRightX, box.commentX)
        XCTAssertLessThanOrEqual(box.commentX + box.commentColumnWidth, box.frame.maxX)
    }

    func testERWordRelationshipsAliasesAndBareEntities() throws {
        let source = """
        erDiagram
          PRODUCT one or more to zero or more LINE_ITEM : appears
          A only one optionally to many(0) B : x
          p["Person"] {
            string name
          }
          p ||--o{ A : owns
          LONELY
        """
        guard case .er(let er) = try XCTUnwrap(MermaidParser.parse(source)) else { return XCTFail("expected er") }
        XCTAssertEqual(er.entities.map(\.name), ["PRODUCT", "LINE_ITEM", "A", "B", "p", "LONELY"])
        XCTAssertEqual(er.entities.first { $0.name == "p" }?.displayName, "Person")
        XCTAssertEqual(er.relations.count, 3)
        XCTAssertEqual(er.relations[0].fromCard, .oneOrMore)
        XCTAssertEqual(er.relations[0].toCard, .zeroOrMore)
        XCTAssertTrue(er.relations[0].identifying)
        XCTAssertFalse(er.relations[1].identifying)
        XCTAssertTrue(try svg(.er(er)).contains(">Person<"))
    }

    func testERRejectsMalformedAttributeRows() {
        for source in ["erDiagram\n  A {\n    int a XX\n  }",
                       "erDiagram\n  A {\n    int\n  }",
                       "erDiagram\n  A {\n    int a \"c\" PK\n  }",
                       "erDiagram\n  A {\n    int a"] {
            XCTAssertNil(MermaidParser.parse(source), source)
            XCTAssertEqual(MermaidParser.diagnose(source).first?.code, .invalidSyntax, source)
        }
    }

    // MARK: State

    func testStateNotesAreParsedLaidOutAndDrawn() throws {
        let source = """
        stateDiagram-v2
          [*] --> Idle
          Idle --> Running : start
          Running --> Done
          Running --> Failed : error
          note right of Idle : waiting
          note left of Failed
            something went wrong
            word
          end note
          Note right of Done : finished
          note left of Idle : left side
          state Running {
            a --> b
            note right of b : inner note
          }
        """
        let diagram = try XCTUnwrap(MermaidParser.parse(source))
        guard case .state(let state) = diagram else { return XCTFail("expected state") }
        XCTAssertEqual(MermaidParser.diagnose(source), [])
        XCTAssertFalse(state.nodes.contains { $0.id == "word" || $0.id == "end" }, "note body leaked into states")
        XCTAssertEqual(state.notes.map(\.target), ["Idle", "Failed", "Done", "Idle"])
        XCTAssertEqual(state.notes.map(\.side), [.right, .left, .right, .left])
        XCTAssertEqual(state.notes[1].text, "something went wrong\nword")
        guard case .composite(let running)? = state.nodes.first(where: { $0.id == "Running" })?.kind else {
            return XCTFail("expected the Running composite")
        }
        XCTAssertEqual(running.notes, [.init(target: "b", side: .right, text: "inner note")])

        let layout = DiagramLayoutEngine.layout(state, measure: measure)
        XCTAssertEqual(layout.notes.count, 5)
        let canvas = CGRect(origin: .zero, size: layout.size)
        for (i, note) in layout.notes.enumerated() {
            XCTAssertTrue(canvas.contains(note.frame), "note \(i) is off the canvas")
            for node in layout.nodes {
                XCTAssertFalse(note.frame.intersects(node.frame), "note \(i) overlaps state \(node.id)")
            }
            for other in layout.notes[(i + 1)...] {
                XCTAssertFalse(note.frame.intersects(other.frame), "notes overlap")
            }
        }
        // Root-scope notes stay outside the composite box.
        let running_ = try XCTUnwrap(layout.containers.first)
        for note in layout.notes where note.text != "inner note" {
            XCTAssertFalse(note.frame.intersects(running_.frame), "\(note.text) overlaps the composite")
        }
        XCTAssertTrue(running_.frame.contains(try XCTUnwrap(layout.notes.first { $0.text == "inner note" }).frame))

        XCTAssertTrue(MermaidAltText.narrate(diagram).contains("waiting"), "notes are narrated")

        let texts = try sceneTexts(diagram)
        let svg = try svg(diagram)
        for text in ["waiting", "something went wrong", "word", "finished", "left side", "inner note"] {
            XCTAssertTrue(texts.contains(text), "\(text) missing from the scene")
            XCTAssertTrue(svg.contains(">\(text)<"), "\(text) missing from the SVG")
        }
    }

    func testStateNoteOnUndeclaredStateDeclaresIt() throws {
        let source = "stateDiagram-v2\n  A --> B\n  note left of Z : creates Z"
        guard case .state(let state) = try XCTUnwrap(MermaidParser.parse(source)) else { return XCTFail() }
        XCTAssertTrue(state.nodes.contains { $0.id == "Z" })
        XCTAssertEqual(state.notes.count, 1)
        XCTAssertEqual(MermaidParser.diagnose(source).map(\.code), [.invalidSyntax])
    }

    func testStateUnclosedBlocksAreRejected() {
        for source in ["stateDiagram-v2\n  state X {\n    a --> b",
                       "stateDiagram-v2\n  A --> B\n  note left of B\n    text"] {
            XCTAssertNil(MermaidParser.parse(source), source)
            let diagnostics = MermaidParser.diagnose(source)
            XCTAssertEqual(diagnostics.first?.severity, .error, source)
            XCTAssertEqual(diagnostics.first?.code, .invalidSyntax, source)
            XCTAssertEqual(diagnostics.first?.line, 3 - (source.contains("state X") ? 1 : 0), source)
        }
    }

    func testStateStrayBraceDoesNotEndTheDiagram() throws {
        let source = "stateDiagram-v2\n  A --> B\n  }\n  B --> C"
        guard case .state(let state) = try XCTUnwrap(MermaidParser.parse(source)) else { return XCTFail() }
        XCTAssertEqual(state.nodes.map(\.id), ["A", "B", "C"])
        XCTAssertEqual(MermaidParser.diagnose(source).map(\.code), [.invalidSyntax])
    }

    func testStateDescriptionsStyledEndpointsAndHistory() throws {
        let source = """
        stateDiagram-v2
          A : first line
          A : second line
          A:::hot --> B
          classDef hot fill:#f00
          state B {
            [H] --> x
          }
        """
        guard case .state(let state) = try XCTUnwrap(MermaidParser.parse(source)) else { return XCTFail() }
        XCTAssertEqual(state.nodes.first { $0.id == "A" }?.label, "first line\nsecond line")
        XCTAssertEqual(state.edges.map(\.from), ["A"])
        guard case .composite(let b)? = state.nodes.first(where: { $0.id == "B" })?.kind else { return XCTFail() }
        XCTAssertEqual(b.edges.count, 1)
        XCTAssertEqual(MermaidParser.diagnose(source), [])
    }
}

