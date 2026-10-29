#if canImport(AppKit) || canImport(UIKit)
import XCTest
import MermaidLayout
@testable import MermaidRender

/// End-to-end Gantt output through the public renderer entry points: the
/// section names and dated axis labels mermaid.js shows must be present in
/// the SVG, and the raster path must draw them too.
final class GanttRenderTests: XCTestCase {

    private let source = """
    gantt
        title Release plan
        dateFormat YYYY-MM-DD
        axisFormat %m/%d
        excludes weekends
        section Build
        Design      :done, d1, 2026-01-01, 5d
        Implement   :active, i1, after d1, 10d
        section Ship
        Test        :crit, t1, after i1, 3d
        Release     :milestone, m1, after t1, 0d
    """

    func testSVGContainsSectionNamesAndDates() throws {
        let svg = try XCTUnwrap(MermaidRenderer.svg(source: source, theme: DiagramTheme(prefersDark: false)))
        XCTAssertTrue(svg.contains(">Build<"), "section name drawn")
        XCTAssertTrue(svg.contains(">Ship<"), "section name drawn")
        XCTAssertNotNil(svg.range(of: #">0\d/\d\d<"#, options: .regularExpression), "axisFormat %m/%d tick labels")
        XCTAssertNil(svg.range(of: #">0<"#, options: .regularExpression), "no day-index ticks")
    }

    func testRasterDrawsSectionNames() throws {
        var drawn: [String] = []
        DiagramRenderer.textCaptureHook = { text, _ in drawn.append(text) }
        defer { DiagramRenderer.textCaptureHook = nil }
        let image = try XCTUnwrap(MermaidRenderer.pngData(source: source + "\n%% raster section names",
                                                          theme: DiagramTheme(prefersDark: false)))
        XCTAssertFalse(image.isEmpty)
        XCTAssertTrue(drawn.contains("Build"))
        XCTAssertTrue(drawn.contains("Ship"))
        XCTAssertTrue(drawn.contains("01/04") || drawn.contains { $0.hasPrefix("01/") })
    }
}
#endif
