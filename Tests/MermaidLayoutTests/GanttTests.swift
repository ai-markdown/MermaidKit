import XCTest
#if canImport(CoreGraphics)
import CoreGraphics
#else
import Foundation
#endif
@testable import MermaidLayout

/// Parser + layout coverage for Gantt charts (Mermaid `gantt`). The parser
/// resolves each task's start/length to a numeric day timeline; the layout
/// maps that timeline to bounded geometry with an injected measurer.
final class GanttTests: XCTestCase {

    // A schedule exercising dates, `after` deps, implicit start, statuses,
    // sections, and a milestone — the same shape as the render fixture.
    private let source = """
    gantt
        title Renderer Hardening Schedule
        dateFormat  YYYY-MM-DD
        axisFormat  %m/%d
        excludes    weekends

        section Parser
        CommonMark baseline       :done,    cm, 2026-07-01, 2d
        GFM tables/tasks          :active,  gfm, after cm, 3d
        Unicode and RTL sweep     :         uni, after gfm, 2d

        section Extensions
        Mermaid pass              :crit,    mer, 2026-07-06, 4d
        MathJax pass              :crit,    mj,  after mer, 3d

        section Release
        Visual regression suite   :milestone, vr, 2026-07-17, 0d
        Canary                    :         canary, after vr, 2d
    """

    private func parseGantt(_ text: String) -> GanttChart? {
        guard case .gantt(let chart)? = MermaidParser.parse(text) else { return nil }
        return chart
    }

    // MARK: - Parser

    func testParsesTitleSectionsAndTaskCount() throws {
        let chart = try XCTUnwrap(parseGantt(source))
        XCTAssertEqual(chart.title, "Renderer Hardening Schedule")
        XCTAssertEqual(chart.sections, ["Parser", "Extensions", "Release"])
        XCTAssertEqual(chart.tasks.count, 7)
    }

    func testResolvesDatesDependenciesAndNormalizesToDayZero() throws {
        let chart = try XCTUnwrap(parseGantt(source))
        func task(_ label: String) -> GanttChart.Task? { chart.tasks.first { $0.label == label } }

        // Earliest task (2026-07-01) anchors day 0.
        let cm = try XCTUnwrap(task("CommonMark baseline"))
        XCTAssertEqual(cm.start, 0); XCTAssertEqual(cm.length, 2); XCTAssertEqual(cm.status, .done)

        // `after cm` starts at cm's end (Fri 07-03). The fixture declares
        // `excludes weekends`, so the 3-day task runs Fri, Mon, Tue and its
        // bar spans the weekend (mermaid.js `fixTaskDates`): 5 calendar days.
        let gfm = try XCTUnwrap(task("GFM tables/tasks"))
        XCTAssertEqual(gfm.start, 2); XCTAssertEqual(gfm.length, 5); XCTAssertEqual(gfm.status, .active)

        // Chained `after gfm` starts on Wed 07-08.
        XCTAssertEqual(task("Unicode and RTL sweep")?.start, 7)

        // Explicit date 2026-07-06 → 5 days after the 07-01 origin.
        let mer = try XCTUnwrap(task("Mermaid pass"))
        XCTAssertEqual(mer.start, 5); XCTAssertEqual(mer.length, 4); XCTAssertEqual(mer.status, .critical)

        // Milestone: zero length, flagged, 2026-07-17 → day 16.
        let vr = try XCTUnwrap(task("Visual regression suite"))
        XCTAssertTrue(vr.isMilestone); XCTAssertEqual(vr.length, 0); XCTAssertEqual(vr.start, 16)
        XCTAssertEqual(task("Canary")?.start, 16, "after a milestone starts at the milestone's instant")
    }

    func testImplicitSequentialStartWithoutDates() throws {
        let chart = try XCTUnwrap(parseGantt("""
        gantt
            section S
            A :a, 3d
            B :b, 2d
            C :c, 1d
        """))
        XCTAssertEqual(chart.tasks.map(\.start), [0, 3, 5], "each dateless task starts when the previous ends")
        XCTAssertEqual(chart.tasks.map(\.length), [3, 2, 1])
    }

    func testStartAndEndDateForm() throws {
        let chart = try XCTUnwrap(parseGantt("""
        gantt
            section S
            Span :t, 2026-07-01, 2026-07-05
        """))
        XCTAssertEqual(chart.tasks.first?.length, 4, "a second date is an end date, not a duration")
    }

    func testDegradesToNilWithoutTasks() {
        XCTAssertNil(parseGantt("gantt\n    title Empty\n    dateFormat YYYY-MM-DD"))
    }

    func testDurationAndDateHelpers() {
        XCTAssertEqual(MermaidParser.durationInDays("30d"), 30)
        XCTAssertEqual(MermaidParser.durationInDays("2w"), 14)
        XCTAssertEqual(MermaidParser.durationInDays("12h"), 0.5)
        XCTAssertEqual(MermaidParser.durationInDays("30"), 30, "a bare number is days")
        XCTAssertNil(MermaidParser.durationInDays("soon"))

        // Only day differences matter; check them across a month boundary.
        let d1 = try! XCTUnwrap(MermaidParser.dayOrdinal(fromISODate: "2026-07-01"))
        let d2 = try! XCTUnwrap(MermaidParser.dayOrdinal(fromISODate: "2026-08-01"))
        XCTAssertEqual(d2 - d1, 31)
        XCTAssertNil(MermaidParser.dayOrdinal(fromISODate: "2026-13-40"))
        XCTAssertNil(MermaidParser.dayOrdinal(fromISODate: "not-a-date"))
    }

    // MARK: - Layout

    /// width = 10 per character; deterministic and font-free.
    private let measure: DiagramTextMeasurer = { text, _ in CGSize(width: Double(text.count) * 10, height: 14) }

    func testLayoutIsNonDegenerateWithOneBarPerTask() throws {
        let chart = try XCTUnwrap(parseGantt(source))
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)

        XCTAssertGreaterThan(layout.size.width, 0)
        XCTAssertGreaterThan(layout.size.height, 0)
        XCTAssertLessThan(layout.size.width, 20_000, "bounded day-width keeps the canvas sane")
        XCTAssertEqual(layout.bars.count, chart.tasks.count)
        XCTAssertEqual(layout.sections.count, 3, "one tint band per section")
        XCTAssertFalse(layout.ticks.isEmpty)
    }

    func testLayoutOrdersRowsAndPlacesTimeLeftToRight() throws {
        let chart = try XCTUnwrap(parseGantt(source))
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)

        // Bars stack top to bottom in task order.
        for i in 1..<layout.bars.count {
            XCTAssertGreaterThan(layout.bars[i].frame.minY, layout.bars[i - 1].frame.minY)
        }
        // A later start sits further right: Mermaid pass (day 5) right of CommonMark (day 0).
        let cm = layout.bars[0].frame.minX
        let mer = try XCTUnwrap(layout.bars.first(where: { $0.label == "Mermaid pass" })).frame.minX
        XCTAssertGreaterThan(mer, cm)
        // The milestone is a small square, not a wide bar.
        let vr = try XCTUnwrap(layout.bars.first(where: { $0.isMilestone }))
        XCTAssertEqual(vr.frame.width, vr.frame.height, accuracy: 0.01, "milestone renders as a diamond box")
    }

    // MARK: - Regression: section names, dated axis, excludes, invalid input

    private let theme = RenderTheme(
        ink: DiagramColor(hex: 0x1D1D1F), accent: DiagramColor(hex: 0x5B8FF9),
        canvas: DiagramColor(hex: 0xFFFFFF), hairline: DiagramColor(hex: 0x000000, alpha: 0.12),
        secondaryText: DiagramColor(hex: 0x1D1D1F, alpha: 0.55),
        tertiaryText: DiagramColor(hex: 0x1D1D1F, alpha: 0.38),
        palette: [DiagramColor(hex: 0x5B8FF9), DiagramColor(hex: 0x61DDAA)])

    private func svg(_ source: String) throws -> String {
        let chart = try XCTUnwrap(parseGantt(source))
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)
        return SVGRenderer.svg(RenderScene.from(layout, theme: theme, measure: measure))
    }

    /// Proportional to the font size, close to the system font's widths, so
    /// tick spacing (which depends on label width) is realistic.
    private let fontMeasure: DiagramTextMeasurer = { text, size in
        CGSize(width: Double(text.count) * size * 0.55, height: size + 4)
    }

    private func tickLabels(_ source: String) throws -> [String] {
        let chart = try XCTUnwrap(parseGantt(source))
        return DiagramLayoutEngine.layout(chart, measure: fontMeasure).ticks.map(\.label)
    }

    func testSectionNamesAreDrawnInSceneAndSVG() throws {
        let source = """
        gantt
            dateFormat YYYY-MM-DD
            section Alpha phase
            A :a1, 2024-01-01, 3d
            section Beta
            B :after a1, 5d
        """
        let chart = try XCTUnwrap(parseGantt(source))
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)
        XCTAssertEqual(layout.sections.map { $0.labelLines.map(\.text).joined(separator: " ") }, ["Alpha phase", "Beta"])
        for band in layout.sections {
            for line in band.labelLines {
                XCTAssertTrue(band.frame.contains(line.center), "section name sits inside its band")
                XCTAssertLessThan(line.center.x, layout.labelGutter, "section name sits left of the bars")
            }
        }
        // Section names never overlap the task labels in the gutter.
        let nameRects = layout.sections.flatMap(\.labelLines).map { line -> CGRect in
            let w = measure(line.text, 10.5).width
            return CGRect(x: line.center.x - w / 2, y: line.center.y - 7, width: w, height: 14)
        }
        let taskRects = layout.bars.flatMap(\.labelLines).map { line -> CGRect in
            let w = measure(line.text, 10.5).width
            return CGRect(x: line.center.x - w / 2, y: line.center.y - 7, width: w, height: 14)
        }
        for a in nameRects { for b in taskRects { XCTAssertFalse(a.intersects(b)) } }

        let svg = try svg(source)
        XCTAssertTrue(svg.contains(">Alpha phase<"), "section name in the SVG")
        XCTAssertTrue(svg.contains(">Beta<"))
        let scene = DiagramScene.from(layout, measure: measure)
        XCTAssertTrue(scene.labels.contains { $0.text == "Alpha phase" })
    }

    func testLongSectionAndTaskNamesWrapInsteadOfOverlapping() throws {
        let chart = try XCTUnwrap(parseGantt("""
        gantt
            dateFormat YYYY-MM-DD
            section A rather long section name that must wrap somewhere
            A very long task label that will certainly not fit into the label gutter at all :a1, 2024-01-01, 3d
        """))
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)
        let band = try XCTUnwrap(layout.sections.first)
        XCTAssertGreaterThan(band.labelLines.count, 1)
        XCTAssertGreaterThan(layout.bars[0].labelLines.count, 1)
        XCTAssertEqual(band.labelLines.map(\.text).joined(separator: " "),
                       "A rather long section name that must wrap somewhere", "no text is dropped")
        let lastLine = try XCTUnwrap(band.labelLines.last)
        XCTAssertLessThanOrEqual(lastLine.center.y + 7, band.frame.maxY, "the band grows to hold the name")
        let sectionRight = band.labelLines.map { $0.center.x + measure($0.text, 10.5).width / 2 }.max() ?? 0
        let taskLeft = layout.bars[0].labelLines.map { $0.center.x - measure($0.text, 10.5).width / 2 }.min() ?? 0
        XCTAssertLessThan(sectionRight, taskLeft, "section column and task gutter don't overlap")
    }

    func testAxisShowsDatesInDefaultFormat() throws {
        let chart = try XCTUnwrap(parseGantt("""
        gantt
            dateFormat YYYY-MM-DD
            section S
            A :a1, 2024-01-01, 3d
            B :after a1, 5d
        """))
        XCTAssertEqual(chart.originJulianDay, MermaidParser.dayOrdinal(fromISODate: "2024-01-01"))
        let labels = DiagramLayoutEngine.layout(chart, measure: fontMeasure).ticks.map(\.label)
        // mermaid.js 11.17.2 draws 2024-01-01 … 2024-01-09 for this chart;
        // the dated ticks here are a collision-free subset of those.
        XCTAssertEqual(labels.first, "2024-01-01")
        XCTAssertTrue(labels.allSatisfy { $0.range(of: #"^2024-01-\d\d$"#, options: .regularExpression) != nil }, "\(labels)")
        XCTAssertGreaterThanOrEqual(labels.count, 3)
    }

    func testAxisHonorsAxisFormat() throws {
        let labels = try tickLabels("""
        gantt
            dateFormat YYYY-MM-DD
            axisFormat %m/%d
            section S
            A :a1, 2024-01-01, 3d
        """)
        XCTAssertEqual(labels, ["01/01", "01/02", "01/03", "01/04"])
    }

    func testAxisMatchesMermaidWeeklyTicks() throws {
        // mermaid.js 11.17.2 ticks this corpus chart weekly on Sundays:
        // 2026-08-02, 08-09, …, 09-13.
        let labels = try tickLabels("""
        gantt
          title Release 3.0.0
          dateFormat YYYY-MM-DD
          excludes weekends
          section Engine
            Split packages      :done,    split, 2026-08-01, 12d
            Two-model rewrite   :done,    two,   after split, 20d
          section Corpus
            Generate math       :active,  math,  2026-08-31, 3d
            Mermaid coverage    :         merm,  after math, 2d
            Wire consumers      :         wire,  after merm, 3d
          section Release
            Cut 3.0.0           :milestone, rel, after wire, 0d
        """)
        XCTAssertEqual(labels, ["2026-08-02", "2026-08-09", "2026-08-16", "2026-08-23",
                                "2026-08-30", "2026-09-06", "2026-09-13"])
    }

    func testDateFormattingAndCalendarHelpers() throws {
        let jan1 = Double(GanttCalendar.julianDay(year: 2024, month: 1, day: 1))
        XCTAssertEqual(GanttCalendar.format(jan1, "%e %b %a|%B %A %j %y %%"), "1 Jan Mon|January Monday 001 24 %")
        XCTAssertEqual(GanttCalendar.format(jan1 + 8.5 / 24, "%Y-%m-%d %H:%M %I%p"), "2024-01-01 08:30 08AM")
        XCTAssertTrue(GanttCalendar.civil(GanttCalendar.julianDay(year: 2024, month: 2, day: 29)) == (2024, 2, 29))
        XCTAssertTrue(GanttCalendar.civil(GanttCalendar.julianDay(year: 2026, month: 2, day: 30)) == (2026, 3, 2),
                      "day overflow rolls over as in JavaScript Date")
        XCTAssertEqual(GanttCalendar.weekday(Int(jan1)), 1, "2024-01-01 is a Monday")
        XCTAssertEqual(GanttCalendar.parse("05.01.2024", format: "DD.MM.YYYY"),
                       Double(GanttCalendar.julianDay(year: 2024, month: 1, day: 5)))
        XCTAssertNil(GanttCalendar.parse("30.02.2024", format: "DD.MM.YYYY"), "strict: no Feb 30")
        XCTAssertEqual(GanttCalendar.addingMonths(1, to: Double(GanttCalendar.julianDay(year: 2024, month: 1, day: 31))),
                       Double(GanttCalendar.julianDay(year: 2024, month: 2, day: 29)))
    }

    func testNonISODateFormatIsInterpreted() throws {
        let chart = try XCTUnwrap(parseGantt("""
        gantt
            dateFormat DD.MM.YYYY
            A :a1, 05.01.2024, 3d
        """))
        XCTAssertEqual(chart.originJulianDay, MermaidParser.dayOrdinal(fromISODate: "2024-01-05"))
        XCTAssertEqual(chart.tasks.first?.length, 3)
    }

    func testRelativeChartFallsBackToDayOffsets() throws {
        let chart = try XCTUnwrap(parseGantt("gantt\n    A :3d\n    B :2d"))
        XCTAssertNil(chart.originJulianDay)
        let labels = DiagramLayoutEngine.layout(chart, measure: measure).ticks.map(\.label)
        XCTAssertEqual(labels.first, "0")
    }

    func testExcludesWeekendsExtendsDurationPastWeekend() throws {
        // 2024-01-05 is a Friday: 5 working days are Fri, Mon–Thu, so the task
        // ends (exclusive) on Friday 01-12 — 7 calendar days.
        let chart = try XCTUnwrap(parseGantt("""
        gantt
            dateFormat YYYY-MM-DD
            excludes weekends
            A :a1, 2024-01-05, 5d
            B :b1, after a1, 1d
            C :c1, 2024-01-05, 2024-01-08
        """))
        XCTAssertEqual(chart.tasks[0].length, 7)
        XCTAssertEqual(chart.tasks[1].start, 7, "dependents start after the pushed end")
        XCTAssertEqual(chart.tasks[2].length, 3, "an explicit end date is not extended")
    }

    func testExcludesExplicitDatesAndWeekdays() throws {
        let chart = try XCTUnwrap(parseGantt("""
        gantt
            dateFormat YYYY-MM-DD
            excludes 2024-01-02, wednesday
            A :a1, 2024-01-01, 2d
        """))
        // Mon 01-01 + 2d → 01-03; Tue 01-02 and Wed 01-03 are excluded → 01-05.
        XCTAssertEqual(chart.tasks[0].length, 4)
    }

    func testExcludesWithoutAnyWorkingDayIsRejected() {
        let source = """
        gantt
            dateFormat YYYY-MM-DD
            excludes weekends monday tuesday wednesday thursday friday
            A :a1, 2024-01-01, 2d
        """
        XCTAssertNil(MermaidParser.parse(source))
        XCTAssertTrue(MermaidParser.diagnose(source).contains { $0.severity == .error && $0.code == .invalidSyntax })
    }

    func testInvalidStartDateIsRejectedWithDiagnostic() throws {
        let source = "gantt\n  dateFormat YYYY-MM-DD\n  Task :a1, notadate, 3d"
        XCTAssertNil(MermaidParser.parse(source))
        let diagnostics = MermaidParser.diagnose(source)
        let error = try XCTUnwrap(diagnostics.first { $0.severity == .error })
        XCTAssertEqual(error.code, .invalidSyntax)
        XCTAssertEqual(error.line, 3)
        XCTAssertTrue(error.message.contains("notadate"))

        for bad in ["gantt\n  dateFormat YYYY-MM-DD\n  Task :a1, 9999-99-99, 3d",
                    "gantt\n  dateFormat YYYY-MM-DD\n  Task :a1, 2026-02-32, 3d",
                    "gantt\n  Task :done, a1, foo, 3d",
                    "gantt\n  dateFormat YYYY-MM-DD\n  Task :a1, 2024-01-01"] {
            XCTAssertNil(MermaidParser.parse(bad), bad)
        }
    }

    func testValidTaskFormsAreNotRejected() {
        let forms = [
            "Task :a1, 2024-01-01, 3d",
            "Task :a1, after a0, 2d",
            "Task :2d",
            "Task :done, a1, 2024-01-01, 3d",
            "Task :a1, 2024-01-01, until a0",
            "Task :milestone, m1, 2024-01-03, 0d",
            "Task :2024-01-01, 3d",
            "Task :a1, 2026-02-30, 3d",   // mermaid.js rolls it over to March 2
            "Task :a1, 2024-1-5, 3d",
            "Task :a1, 2024-01-05 10:00, 3h",
        ]
        for form in forms {
            let source = "gantt\n  dateFormat YYYY-MM-DD\n  Zero :a0, 2024-01-01, 1d\n  \(form)"
            XCTAssertNotNil(MermaidParser.parse(source), form)
            XCTAssertFalse(MermaidParser.diagnose(source).contains { $0.severity == .error }, form)
        }
    }

    func testNonISODateFormatNotesInsteadOfRejecting() throws {
        let source = "gantt\n  dateFormat DD.MM.YYYY\n  A :a1, foo, 3d\n  B :b1, bar, 2d"
        XCTAssertNotNil(MermaidParser.parse(source))
        let notes = MermaidParser.diagnose(source).filter { $0.code == .unsupportedFeature }
        XCTAssertEqual(notes.count, 1, "noted once")
        XCTAssertEqual(notes.first?.severity, .note)
    }

    func testHugeDurationIsBoundedAndNoted() throws {
        let source = "gantt\n  dateFormat YYYY-MM-DD\n  A :a, 2026-01-01, 99999999d"
        let chart = try XCTUnwrap(parseGantt(source))
        XCTAssertEqual(chart.tasks[0].length, MermaidParser.ganttMaxDays)
        let layout = DiagramLayoutEngine.layout(chart, measure: measure)
        XCTAssertLessThan(layout.size.width, 4000, "bounded canvas")
        XCTAssertFalse(layout.ticks.isEmpty)
        XCTAssertTrue(MermaidParser.diagnose(source).contains { $0.code == .valueClamped })

        // A long chain of clamped durations stays finite and bounded too.
        var chain = "gantt\n  dateFormat YYYY-MM-DD\n  T0 :t0, 9990-01-01, 99999999d\n"
        for i in 1..<60 { chain += "  T\(i) :t\(i), after t\(i - 1), 1e308d\n" }
        let long = try XCTUnwrap(parseGantt(chain))
        XCTAssertTrue(long.tasks.allSatisfy { $0.start.isFinite && $0.length.isFinite })
        let longLayout = DiagramLayoutEngine.layout(long, measure: measure)
        XCTAssertLessThan(longLayout.size.width, 4000)
        XCTAssertLessThan(longLayout.ticks.count, 100)
    }

    func testForwardReferencesAndUntilResolve() throws {
        let chart = try XCTUnwrap(parseGantt("""
        gantt
            dateFormat YYYY-MM-DD
            A :a1, 2024-01-01, until b1
            C :c1, after b1, 1d
            B :b1, 2024-01-10, 2d
        """))
        XCTAssertEqual(chart.tasks[0].length, 9, "until b1 ends at B's start")
        XCTAssertEqual(chart.tasks[1].start, 11, "after a later task resolves")
    }

    func testDroppedContentIsNoted() {
        let source = """
        gantt
            dateFormat YYYY-MM-DD
            todayMarker off
            click a1 href "https://example.com"
            this line is not a task
            A :a1, 2024-01-01, 2d
            B :b1, after zz, 1d
        """
        let diagnostics = MermaidParser.diagnose(source)
        XCTAssertTrue(diagnostics.contains { $0.code == .statementSetAside && $0.line == 5 })
        XCTAssertTrue(diagnostics.contains { $0.line == 7 && $0.severity == .note })
        XCTAssertFalse(diagnostics.contains { $0.line == 3 || $0.line == 4 }, "styling/interaction stays quiet")
    }
}
