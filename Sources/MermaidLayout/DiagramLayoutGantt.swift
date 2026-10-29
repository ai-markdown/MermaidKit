import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

extension DiagramLayoutEngine {

    /// Lays out a Gantt chart: a left column of section names, a gutter of
    /// task labels, section tint bands, a dated time axis, and one bar per
    /// task (a diamond for a milestone). Time maps to x through a bounded
    /// day-width so a long schedule can't produce a runaway canvas. Pure
    /// geometry — the renderer only draws.
    public static func layout(_ gantt: GanttChart, measure: DiagramTextMeasurer) -> GanttLayout {
        let margin: CGFloat = 14
        let titleHeight: CGFloat = gantt.title == nil ? 0 : Self.titleHeight(24, measure)
        let rowHeight: CGFloat = grown(24, fontSize: labelFontSize, measure)
        let lineHeight: CGFloat = grown(13, fontSize: labelFontSize, measure)
        let barHeight: CGFloat = 14
        let axisHeight: CGFloat = grown(18, fontSize: 9, measure)
        func width(_ text: String) -> CGFloat { measure(text, labelFontSize).width }

        // Section-name column, sized to the widest name (clamped; longer
        // names wrap), present only when some task belongs to a section.
        let sectionNames = gantt.tasks.map(\.section).filter { !$0.isEmpty }
        let sectionTextWidth = min(sectionNames.map(width).max() ?? 0, grown(130, fontSize: labelFontSize, measure))
        let sectionColumn: CGFloat = sectionNames.isEmpty ? 0 : sectionTextWidth + 16

        // Task-label gutter sized to the widest task label (clamped; longer
        // labels wrap onto more lines and the row grows).
        let labelTextWidth = min(max(gantt.tasks.map { width($0.label) }.max() ?? 60, 40),
                                 grown(180, fontSize: labelFontSize, measure))
        let gutter = margin + sectionColumn + labelTextWidth + 10

        // Day → x, with the chart width bounded so the canvas stays a sane
        // size regardless of the schedule's span (guards the runaway-width
        // budget), yet wide enough for a few dated ticks.
        let maxEnd = gantt.tasks.map(\.end).filter(\.isFinite).max() ?? 0
        let span = min(max(maxEnd, gantt.originJulianDay == nil ? 1 : 1.0 / 24), GanttCalendar.ordinalRange.upperBound)
        let natural = CGFloat(span) * min(max(480 / CGFloat(span), 3), 40)
        let chartWidth = min(max(natural, grown(240, fontSize: 9, measure)), 1800)
        let dayWidth = chartWidth / CGFloat(span)
        func x(_ day: Double) -> CGFloat { gutter + CGFloat(day) * dayWidth }

        let chartTop = margin + titleHeight

        // Rows: each task's label lines and height.
        let labelLines = gantt.tasks.map { ganttWrap($0.label, maxWidth: labelTextWidth, measure: measure) }
        let rowHeights = labelLines.map { max(rowHeight, CGFloat($0.count) * lineHeight + 8) }

        // Runs of consecutive same-section rows; a section band grows when its
        // wrapped name needs more room than its rows provide.
        var bars: [GanttLayout.Bar] = []
        var sections: [GanttLayout.SectionBand] = []
        var y = chartTop
        var row = 0
        while row < gantt.tasks.count {
            let name = gantt.tasks[row].section
            var count = 1
            while row + count < gantt.tasks.count, gantt.tasks[row + count].section == name { count += 1 }
            let bandTop = y
            let rowsHeight = rowHeights[row..<(row + count)].reduce(0, +)
            let nameLines = name.isEmpty ? [] : ganttWrap(name, maxWidth: sectionTextWidth, measure: measure)
            let bandHeight = max(rowsHeight, CGFloat(nameLines.count) * lineHeight + 8)

            for r in row..<(row + count) {
                let task = gantt.tasks[r]
                let rowY = y
                let rowMid = rowY + rowHeights[r] / 2
                let barY = rowMid - barHeight / 2
                let startX = x(task.start)
                let frame = task.isMilestone
                    ? CGRect(x: startX - barHeight / 2, y: barY, width: barHeight, height: barHeight)
                    : CGRect(x: startX, y: barY, width: max(CGFloat(task.length) * dayWidth, 3), height: barHeight)
                let labelRight = gutter - 8
                let lines = labelLines[r]
                let firstCenterY = rowMid - CGFloat(lines.count - 1) * lineHeight / 2
                bars.append(GanttLayout.Bar(
                    label: task.label,
                    frame: frame,
                    labelPoint: CGPoint(x: labelRight, y: rowMid),
                    isMilestone: task.isMilestone,
                    status: task.status,
                    labelLines: lines.enumerated().map { i, text in
                        GanttLayout.TextLine(text: text, center: CGPoint(
                            x: labelRight - width(text) / 2, y: firstCenterY + CGFloat(i) * lineHeight))
                    }
                ))
                y += rowHeights[r]
            }
            y = bandTop + bandHeight

            if !name.isEmpty {
                let bandMid = bandTop + bandHeight / 2
                let firstCenterY = bandMid - CGFloat(nameLines.count - 1) * lineHeight / 2
                let textLeft = margin + 8
                sections.append(GanttLayout.SectionBand(
                    name: name,
                    frame: CGRect(x: margin, y: bandTop, width: gutter - margin + chartWidth, height: bandHeight),
                    colorIndex: gantt.sections.firstIndex(of: name) ?? 0,
                    labelLines: nameLines.enumerated().map { i, text in
                        GanttLayout.TextLine(text: text, center: CGPoint(
                            x: textLeft + width(text) / 2, y: firstCenterY + CGFloat(i) * lineHeight))
                    }
                ))
            }
            row += count
        }

        let chartBottom = y

        // Axis ticks: calendar dates in `axisFormat`, spaced so labels never
        // collide.
        var ticks: [GanttLayout.Tick] = []
        var rightmost = gutter + chartWidth + margin
        for tick in ganttTicks(gantt, span: span, dayWidth: Double(dayWidth), measure: measure) {
            let tickX = x(tick.offset)
            ticks.append(GanttLayout.Tick(x: tickX, label: tick.label, top: chartTop, bottom: chartBottom))
            rightmost = max(rightmost, tickX + measure(tick.label, 9).width / 2 + 4)
        }

        return GanttLayout(
            size: CGSize(width: rightmost, height: chartBottom + axisHeight + margin),
            title: gantt.title,
            labelGutter: gutter,
            bars: bars,
            sections: sections,
            ticks: ticks
        )
    }

    /// Greedy word wrap to `maxWidth`; a word wider than the line (or text
    /// without spaces, such as CJK) breaks between characters.
    static func ganttWrap(_ text: String, maxWidth: CGFloat, measure: DiagramTextMeasurer) -> [String] {
        func fits(_ s: String) -> Bool { measure(s, labelFontSize).width <= maxWidth + 0.5 }
        guard !fits(text) else { return [text] }
        var lines: [String] = []
        var current = ""
        func pushCharacters(of word: String) {
            for ch in word {
                if !current.isEmpty, !fits(current + String(ch)) {
                    lines.append(current); current = ""
                }
                current.append(ch)
            }
        }
        for word in text.split(separator: " ").map(String.init) {
            let candidate = current.isEmpty ? word : current + " " + word
            if fits(candidate) {
                current = candidate
            } else if fits(word) {
                if !current.isEmpty { lines.append(current) }
                current = word
            } else {
                if !current.isEmpty { current += " " }
                pushCharacters(of: word)
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines.isEmpty ? [text] : lines
    }

    /// A tick interval on the calendar, d3-time style.
    private enum GanttTickStep {
        case hours(Int), days(Int), weeks(Int), months(Int), years(Int)

        var approximateDays: Double {
            switch self {
            case .hours(let n): return Double(n) / 24
            case .days(let n): return Double(n)
            case .weeks(let n): return Double(n) * 7
            case .months(let n): return Double(n) * 30
            case .years(let n): return Double(n) * 365
            }
        }

        /// The shortest real gap between two ticks, for spacing checks.
        var minimumDays: Double {
            switch self {
            case .months(let n): return Double(n) * 28
            default: return approximateDays
            }
        }

        func scaled(by k: Int) -> GanttTickStep {
            let k = max(k, 1)
            switch self {
            case .hours(let n): return .hours(min(n * k, 24))
            case .days(let n): return .days(n.multipliedReportingOverflow(by: k).overflow ? Int.max / 2 : n * k)
            case .weeks(let n): return .weeks(n.multipliedReportingOverflow(by: k).overflow ? Int.max / 2 : n * k)
            case .months(let n): return .months(n.multipliedReportingOverflow(by: k).overflow ? Int.max / 2 : n * k)
            case .years(let n): return .years(n.multipliedReportingOverflow(by: k).overflow ? Int.max / 2 : n * k)
            }
        }
    }

    /// Axis ticks as day offsets from the chart's day 0 with their labels.
    ///
    /// With absolute dates this follows d3's time-scale ticks (the axis
    /// mermaid.js draws): about ten ticks on hour, day, two-day, week, month,
    /// quarter or year boundaries, or the chart's `tickInterval`, labelled with
    /// `axisFormat`. Unlike d3 it never lets labels collide: the interval
    /// coarsens until each label has room. Without dates the axis shows day
    /// offsets.
    private static func ganttTicks(_ gantt: GanttChart, span: Double, dayWidth: Double,
                                   measure: DiagramTextMeasurer) -> [(offset: Double, label: String)] {
        let gap = 12.0
        guard let origin = gantt.originJulianDay, origin.isFinite else {
            // Relative axis: day offsets on a nice step.
            let labelSpace = Double(measure(String(Int(span.rounded(.up))), 9).width) + gap
            let steps: [Double] = [1, 2, 5, 7, 14, 30, 60, 90, 180, 365, 730, 1825, 3650, 7300, 18250, 36500,
                                   73_000, 182_500, 365_000, 3_650_000, 36_500_000]
            let step = steps.first { $0 * dayWidth >= labelSpace } ?? max(span, 1)
            var ticks: [(Double, String)] = []
            var day = 0.0
            while day <= span + 1e-9, ticks.count < 200 {
                ticks.append((day, String(Int(day))))
                day += step
            }
            return ticks
        }

        let t0 = origin, t1 = origin + span
        let format = gantt.axisFormat
        let samples = [t0, t0 + span / 2, t1].map { GanttCalendar.format($0, format) }
            + [GanttCalendar.format(Double(GanttCalendar.julianDay(year: 2000, month: 9, day: 30)), format)]
        let labelSpace = Double(samples.map { measure($0, 9).width }.max() ?? 40) + gap
        func fits(_ step: GanttTickStep) -> Bool { step.minimumDays * dayWidth >= labelSpace }

        var step: GanttTickStep
        if let interval = gantt.tickInterval {
            switch interval.unit {
            case .hour: step = .hours(min(interval.count, 24))
            case .day: step = .days(interval.count)
            case .week: step = .weeks(interval.count)
            case .month: step = .months(interval.count)
            }
            if !fits(step) {
                step = step.scaled(by: Int((labelSpace / max(step.minimumDays * dayWidth, 1e-9)).rounded(.up)))
            }
        } else {
            var candidates: [GanttTickStep] = []
            if GanttCalendar.formatShowsTime(format) { candidates += [.hours(1), .hours(3), .hours(6), .hours(12)] }
            candidates += [.days(1), .days(2), .weeks(1), .months(1), .months(3), .years(1)]
            for n in [2, 5, 10, 20, 50, 100, 200, 500, 1000, 2000, 5000, 10000, 20000, 50000, 100_000] {
                candidates.append(.years(n))
            }
            // d3: the interval closest (by ratio) to span / 10.
            let target = span / 10
            var index = candidates.firstIndex { $0.approximateDays > target } ?? (candidates.count - 1)
            if index > 0, target / candidates[index - 1].approximateDays < candidates[index].approximateDays / target {
                index -= 1
            }
            while index < candidates.count - 1, !fits(candidates[index]) { index += 1 }
            step = candidates[index]
        }

        let ordinals = ganttTickOrdinals(step, from: t0, to: t1, weekStart: gantt.weekStart)
        let picked = ordinals.isEmpty ? [t0] : ordinals
        return picked.map { ($0 - origin, GanttCalendar.format($0, format)) }
    }

    /// Calendar-aligned tick ordinals in `t0...t1` (bounded count).
    private static func ganttTickOrdinals(_ step: GanttTickStep, from t0: Double, to t1: Double,
                                          weekStart: Int) -> [Double] {
        let limit = 400
        let eps = 1e-9
        var out: [Double] = []
        let firstDay = GanttCalendar.day(of: t0)
        let lastDay = GanttCalendar.day(of: t1)
        func add(_ t: Double) -> Bool {
            if t >= t0 - eps, t <= t1 + eps { out.append(t) }
            return out.count < limit
        }
        switch step {
        case .hours(let n):
            var day = firstDay
            outer: while day <= lastDay {
                for hour in stride(from: 0, to: 24, by: max(n, 1)) {
                    if !add(Double(day) + Double(hour) / 24) { break outer }
                }
                day += 1
            }
        case .days(let n):
            var day = firstDay
            while day <= lastDay {
                if (GanttCalendar.civil(day).day - 1) % max(n, 1) == 0, !add(Double(day)) { break }
                day += 1
            }
        case .weeks(let n):
            // First `weekStart` day on or after the first day, then every n
            // weeks counted from a fixed epoch week (d3's `every`).
            let epoch = 2_440_591 + weekStart   // 1970-01-04 is a Sunday
            var day = firstDay + ((weekStart - GanttCalendar.weekday(firstDay)) % 7 + 7) % 7
            while day <= lastDay {
                if ((day - epoch) / 7) % max(n, 1) == 0, !add(Double(day)) { break }
                day += 7
            }
        case .months(let n):
            var (year, month, _) = GanttCalendar.civil(firstDay)
            while true {
                let day = GanttCalendar.julianDay(year: year, month: month, day: 1)
                if day > lastDay { break }
                if (month - 1) % max(n, 1) == 0, !add(Double(day)) { break }
                month += 1
                if month > 12 { month = 1; year += 1 }
            }
        case .years(let n):
            // Every year that is a multiple of n, from the first one at or
            // after the first day's year (years are positive here).
            let n = max(n, 1)
            let firstYear = GanttCalendar.civil(firstDay).year
            let lastYear = GanttCalendar.civil(lastDay).year
            var year = ((firstYear + n - 1) / n) * n
            while year <= lastYear {
                if !add(Double(GanttCalendar.julianDay(year: year, month: 1, day: 1))) { break }
                year += n
            }
        }
        return out
    }
}
