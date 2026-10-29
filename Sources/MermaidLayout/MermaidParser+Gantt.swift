import Foundation

extension MermaidParser {

    /// How a task's start was written.
    private enum GanttStart {
        case date(Double)
        case after([String])
        case previous
    }

    /// How a task's end was written.
    private enum GanttEnd {
        case date(Double)
        case until([String])
        /// A duration in days; `months` is set for whole `M`/`y` durations,
        /// which add calendar months when the chart has absolute dates.
        case duration(days: Double, months: Int?)
        case none
    }

    private struct GanttRawTask {
        var label: String
        var section: String
        var status: GanttChart.Status
        var isMilestone: Bool
        var id: String
        var start: GanttStart
        var end: GanttEnd
        /// The source line, for diagnostics.
        var line: String
    }

    /// Mermaid's task tags; mermaid.js only reads them at the head of the
    /// spec, this parser accepts them anywhere.
    private static let ganttTags: Set<String> = ["done", "active", "crit", "milestone", "vert"]

    /// Parses `gantt` body lines: `title` / `section` directives and task rows
    /// (`Label : done, t1, 2024-01-01, 3d`), whose comma tokens — status tags,
    /// an optional id, a start (a date in `dateFormat` or `after <id>`), and a
    /// duration, end date or `until <id>` — are read leniently in any order.
    /// Starts resolve to absolute day ordinals (forward references included),
    /// duration-based ends are pushed past `excludes`d days as mermaid.js's
    /// `fixTaskDates` does, then everything shifts so the earliest task sits
    /// at day 0 and `originJulianDay` keeps that day's date.
    static func parseGantt(body: [String]) -> GanttChart? {
        // Pass 1 — chart-wide directives, which apply wherever they appear.
        var dateFormat = "YYYY-MM-DD"
        var axisFormat = "%Y-%m-%d"
        var tickInterval: GanttChart.TickInterval?
        var weekStart = 0
        var weekendStartsFriday = false
        var excludeTokens: [String] = []
        var includeTokens: [String] = []
        var inclusiveEndDates = false
        for line in body {
            let keyword = line.split(separator: " ", maxSplits: 1).first.map { $0.lowercased() } ?? ""
            // Mermaid's lexer ends these directive values at `#` or `;`.
            let value = line.dropFirst(keyword.count).prefix(while: { $0 != "#" && $0 != ";" })
                .trimmingCharacters(in: .whitespaces)
            switch keyword {
            case "dateformat": if !value.isEmpty { dateFormat = value }
            case "axisformat": if !value.isEmpty { axisFormat = value }
            case "tickinterval": tickInterval = ganttTickInterval(value)
            case "weekday":
                if let index = GanttCalendar.weekdayNames.firstIndex(where: { $0.lowercased() == value.lowercased() }) {
                    weekStart = index
                }
            case "weekend": weekendStartsFriday = value.lowercased() == "friday"
            case "excludes": excludeTokens += ganttListTokens(value)
            case "includes": includeTokens += ganttListTokens(value)
            case "inclusiveenddates": inclusiveEndDates = true
            default: break
            }
        }
        // Mermaid.js's own default is `YYYY-MM-DD`; only under it is an
        // unreadable start date known to be an error rather than a format
        // this parser doesn't speak.
        let isISOFormat = dateFormat == "YYYY-MM-DD"
        func parseDate(_ token: String) -> Double? {
            GanttCalendar.parse(token, format: dateFormat) ?? GanttCalendar.parseISOLike(token)
        }

        // Pass 2 — sections and task rows.
        var title: String?
        var currentSection = ""
        var sections: [String] = []
        var raw: [GanttRawTask] = []
        var notedUnreadableDate = false
        let directiveKeywords: Set<String> = ["dateformat", "axisformat", "todaymarker",
                                              "tickinterval", "excludes", "includes",
                                              "weekday", "weekend", "click", "inclusiveenddates",
                                              "topaxis", "displaymode", "acctitle", "accdescr"]

        for (index, line) in body.enumerated() {
            if line.hasPrefix("title ") {
                title = String(line.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
                continue
            }
            if line.hasPrefix("section ") {
                currentSection = String(line.dropFirst("section ".count)).trimmingCharacters(in: .whitespaces)
                if !sections.contains(currentSection) { sections.append(currentSection) }
                continue
            }
            // Directive lines (dateFormat, axisFormat %H:%M, todayMarker,
            // excludes, tickInterval, click href https://...) often contain
            // colons; without this guard each became a PHANTOM TASK BAR.
            // Styling and interaction directives are ignored on purpose.
            let keyword = line.split(separator: " ").first.map { $0.lowercased() } ?? ""
            if directiveKeywords.contains(keyword) || keyword.hasPrefix("acctitle") || keyword.hasPrefix("accdescr") {
                continue
            }
            guard let colon = line.firstIndex(of: ":") else {
                ParseReport.note(.statementSetAside,
                                 "not a task row (no ':' between the task name and its data); left out of the chart",
                                 line: line)
                continue
            }
            let label = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let spec = String(line[line.index(after: colon)...])
            guard !label.isEmpty else {
                ParseReport.note(.statementSetAside, "task row has no name; left out of the chart", line: line)
                continue
            }

            let tokens = spec.split(separator: ",", omittingEmptySubsequences: false)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            var status = GanttChart.Status.normal
            var isMilestone = false
            var id: String?
            var afterIDs: [String]?
            var untilIDs: [String]?
            var dates: [Double] = []
            var duration: GanttEnd?
            var positional: [String] = []
            for token in tokens {
                let lower = token.lowercased()
                switch lower {
                case "done": status = .done
                case "active": status = .active
                case "crit": status = .critical
                case "milestone": isMilestone = true
                case "vert":
                    // Mermaid draws a `vert` task as a vertical marker line
                    // across the chart; here it keeps a row as a milestone.
                    isMilestone = true
                    ParseReport.note(.unsupportedFeature,
                                     "'vert' markers are drawn as a milestone row, not a vertical line across the chart",
                                     line: line)
                default:
                    positional.append(token)
                    if lower.hasPrefix("after ") {
                        afterIDs = ganttIDList(token.dropFirst("after ".count))
                    } else if lower.hasPrefix("until ") {
                        untilIDs = ganttIDList(token.dropFirst("until ".count))
                    } else if let ordinal = parseDate(token) {
                        dates.append(ordinal)
                    } else if let days = durationInDays(token) {
                        if ganttDurationExceedsCap(token) {
                            ParseReport.note(.valueClamped,
                                             "duration '\(token)' is longer than \(Int(ganttMaxDays)) days; clamped to \(Int(ganttMaxDays)) days",
                                             line: line)
                        }
                        duration = .duration(days: days, months: ganttCalendarMonths(token))
                    } else {
                        id = token   // a bare identifier
                    }
                }
            }

            // Mermaid.js reads the data positionally: with two values the first
            // is the start, with three the second is (the first is the id).
            // A start that is no date, `after`, or duration fails to render
            // there ("Invalid date:…").
            let startSlot: String? = positional.count == 2 ? positional[0]
                : positional.count == 3 ? positional[1] : nil
            if let slot = startSlot,
               !slot.lowercased().hasPrefix("after "), parseDate(slot) == nil, durationInDays(slot) == nil {
                let identifierLike = ganttIsIdentifierLike(slot)
                if isISOFormat {
                    if positional.count == 2, durationInDays(positional[1]) != nil, identifierLike {
                        // `Task :a1, 3d` — read leniently as id + duration.
                        ParseReport.note(.invalidSyntax,
                                         "mermaid.js reads '\(slot)' as the start date and rejects it (\"Invalid date:\(slot)\"); rendered as task id '\(slot)' starting when the previous task ends",
                                         line: line)
                    } else if identifierLike || GanttCalendar.looksLikeISODate(slot) {
                        ParseReport.reject(.invalidSyntax,
                                           "invalid start date '\(slot)' (dateFormat YYYY-MM-DD); mermaid.js rejects this chart with \"Invalid date:\(slot)\"",
                                           line: line)
                        return nil
                    } else {
                        ParseReport.note(.invalidSyntax,
                                         "could not read '\(slot)' as a start date; the task starts when the previous task ends",
                                         line: line)
                    }
                } else if !notedUnreadableDate {
                    notedUnreadableDate = true
                    ParseReport.note(.unsupportedFeature,
                                     "could not interpret '\(slot)' with dateFormat '\(dateFormat)'; tasks whose dates can't be read start when the previous task ends",
                                     line: line)
                }
            }

            let start: GanttStart
            var endDate: Double?
            if let afterIDs {
                start = .after(afterIDs)
                endDate = dates.first
            } else if let first = dates.first {
                start = .date(first)
                endDate = dates.count >= 2 ? dates[1] : nil
            } else {
                start = .previous
            }
            let end: GanttEnd
            if let endDate {
                end = .date(endDate + (inclusiveEndDates ? 1 : 0))
            } else if let untilIDs {
                end = .until(untilIDs)
            } else if let duration {
                end = duration
            } else {
                end = .none
            }
            raw.append(GanttRawTask(label: label, section: currentSection, status: status,
                                    isMilestone: isMilestone, id: id ?? "task\(index)",
                                    start: start, end: end, line: line))
        }

        guard !raw.isEmpty else { return nil }

        // A chart has absolute dates when any task names one; a task with no
        // predecessor then starts on the first date written.
        let firstDate: Double? = raw.lazy.compactMap { task -> Double? in
            if case .date(let d) = task.start { return d }
            if case .date(let d) = task.end { return d }
            return nil
        }.first
        let isAbsolute = firstDate != nil
        let defaultStart = firstDate ?? 0

        // Excluded days (mermaid's `isInvalidDate`).
        let hasExcludes = !excludeTokens.isEmpty
        var excludedWeekdays = Set<Int>()
        var excludedDays = Set<Int>()
        var includedDays = Set<Int>()
        for token in excludeTokens {
            if token == "weekends" {
                excludedWeekdays.formUnion(weekendStartsFriday ? [5, 6] : [6, 0])
            } else if let weekday = GanttCalendar.weekdayNames.firstIndex(where: { $0.lowercased() == token }) {
                excludedWeekdays.insert(weekday)
            } else if let ordinal = parseDate(token) {
                excludedDays.insert(GanttCalendar.day(of: ordinal))
            }
        }
        for token in includeTokens {
            if let ordinal = parseDate(token) { includedDays.insert(GanttCalendar.day(of: ordinal)) }
        }
        func isExcluded(_ ordinal: Double) -> Bool {
            let day = GanttCalendar.day(of: ordinal)
            if includedDays.contains(day) { return false }
            return excludedWeekdays.contains(GanttCalendar.weekday(day)) || excludedDays.contains(day)
        }
        if hasExcludes, !isAbsolute {
            ParseReport.note(.unsupportedFeature,
                             "'excludes' needs tasks with dates; the chart has none, so no days are skipped")
        }

        // Resolve starts and ends. `after`/`until` may point forward, so
        // repeat until nothing changes (mermaid.js re-compiles likewise),
        // then settle whatever is left (cycles) with fallbacks.
        let indexByID = Dictionary(raw.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { _, last in last })
        var starts = [Double?](repeating: nil, count: raw.count)
        var ends = [Double?](repeating: nil, count: raw.count)       // for dependents
        var drawnEnds = [Double?](repeating: nil, count: raw.count)  // bar end
        var excludesExhausted = false

        func resolve(_ i: Int, force: Bool) -> Bool {
            let task = raw[i]
            let fallbackStart = i > 0 ? (ends[i - 1] ?? defaultStart) : defaultStart
            let start: Double
            switch task.start {
            case .date(let d):
                start = d
            case .previous:
                if i == 0 {
                    start = defaultStart
                } else if let previous = ends[i - 1] {
                    start = previous
                } else if force {
                    start = defaultStart
                } else {
                    return false
                }
            case .after(let ids):
                let known = ids.compactMap { indexByID[$0] }
                if known.isEmpty {
                    if !force {
                        ParseReport.note(.invalidSyntax,
                                         "'after \(ids.joined(separator: " "))' names no task in this chart; the task starts when the previous task ends (mermaid.js uses today's date)",
                                         line: task.line)
                    }
                    if !force, i > 0, ends[i - 1] == nil { return false }
                    start = fallbackStart
                } else {
                    let resolved = known.compactMap { ends[$0] }
                    if resolved.count < known.count, !force { return false }
                    start = resolved.max() ?? fallbackStart
                }
            }

            var end: Double
            var drawnEnd: Double?
            switch task.end {
            case .date(let d):
                end = d   // explicit end dates are not pushed past excluded days
            case .until(let ids):
                let known = ids.compactMap { indexByID[$0] }
                let resolved = known.compactMap { starts[$0] }
                if !known.isEmpty, resolved.count < known.count, !force { return false }
                if let earliest = resolved.min() {
                    end = earliest
                } else {
                    end = start + 1
                    ParseReport.note(.invalidSyntax,
                                     "'until \(ids.joined(separator: " "))' names no task in this chart; the task lasts one day (mermaid.js ends it today)",
                                     line: task.line)
                }
            case .duration(let days, let months):
                if isAbsolute, let months {
                    end = GanttCalendar.addingMonths(months, to: start)
                } else {
                    end = start + days
                }
                if hasExcludes, isAbsolute {
                    // mermaid.js `fixTaskDates`: walk the days after the start
                    // up to the end; every excluded day pushes the end out by
                    // one. The bar stops at the end before the last run of
                    // excluded days; dependents start after them.
                    var day = start + 1
                    var invalid = false
                    var extensions = 0
                    drawnEnd = end
                    while day <= end {
                        if !invalid { drawnEnd = end }
                        invalid = isExcluded(day)
                        if invalid {
                            end += 1
                            extensions += 1
                            if extensions > 10_000 { excludesExhausted = true; return true }
                        }
                        day += 1
                    }
                }
            case .none:
                end = start + 1
            }
            if task.isMilestone { end = start; drawnEnd = start }
            starts[i] = start
            ends[i] = end
            drawnEnds[i] = max(start, drawnEnd ?? end)
            return true
        }

        var pending = Array(raw.indices)
        var passes = 0
        while !pending.isEmpty, passes <= raw.count {
            let before = pending.count
            pending = pending.filter { !resolve($0, force: false) }
            passes += 1
            if pending.count == before { break }
        }
        for i in pending { _ = resolve(i, force: true) }
        if excludesExhausted {
            ParseReport.reject(.invalidSyntax,
                               "'excludes' leaves no working day for a task within 10,000 days; mermaid.js rejects this chart")
            return nil
        }

        let tasks = raw.indices.map { i -> GanttChart.Task in
            let start = starts[i] ?? defaultStart
            return GanttChart.Task(
                id: raw[i].id, label: raw[i].label, section: raw[i].section,
                start: start, length: max(0, (drawnEnds[i] ?? start) - start),
                isMilestone: raw[i].isMilestone, status: raw[i].status)
        }

        // Normalize so the earliest task sits at day 0.
        let origin = tasks.map(\.start).min() ?? 0
        let normalized = tasks.map { task -> GanttChart.Task in
            var copy = task
            copy.start -= origin
            return copy
        }
        return GanttChart(title: title, tasks: normalized, sections: sections,
                          originJulianDay: isAbsolute ? origin : nil,
                          axisFormat: axisFormat, tickInterval: tickInterval, weekStart: weekStart)
    }

    /// Longest task duration, in days (a century): finite-but-absurd values
    /// would otherwise size a multi-billion-point canvas.
    static let ganttMaxDays = 36_500.0

    /// `excludes`/`includes` values: lowercased, split on spaces and commas.
    private static func ganttListTokens(_ value: String) -> [String] {
        value.lowercased().split(whereSeparator: { $0 == " " || $0 == "," || $0 == "\t" }).map(String.init)
    }

    /// The ids of an `after a b` / `until a b` reference.
    private static func ganttIDList(_ text: Substring) -> [String] {
        text.split(separator: " ").map(String.init)
    }

    /// A plain identifier (`a1`, `task-2`, `notadate`) — never a date.
    private static func ganttIsIdentifierLike(_ text: String) -> Bool {
        guard let first = text.unicodeScalars.first,
              CharacterSet.letters.contains(first) || first == "_" else { return false }
        return text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-"
        }
    }

    /// `tickInterval` values mermaid.js accepts (`1day`, `2week`, `1month`,
    /// `6hour`); smaller units fall back to automatic ticks.
    private static func ganttTickInterval(_ value: String) -> GanttChart.TickInterval? {
        let digits = value.prefix(while: { $0.isASCII && $0.isNumber })
        guard !digits.isEmpty, digits.count <= 4, let count = Int(digits), count >= 1,
              let unit = GanttChart.TickInterval.Unit(rawValue: String(value.dropFirst(digits.count)))
        else { return nil }
        return GanttChart.TickInterval(count: count, unit: unit)
    }

    /// Whole calendar months for an `NM` / `Ny` duration, or nil.
    private static func ganttCalendarMonths(_ token: String) -> Int? {
        guard let unit = token.last, unit == "M" || unit == "y",
              let value = finiteDouble(token.dropLast()), value >= 0, value == value.rounded()
        else { return nil }
        let months = unit == "y" ? value * 12 : value
        return Int(min(months, ganttMaxDays / 30))
    }

    /// True when a duration token asks for more than `ganttMaxDays`.
    private static func ganttDurationExceedsCap(_ token: String) -> Bool {
        let factors: [Character: Double] = ["d": 1, "w": 7, "y": 365, "M": 30]
        if let bare = finiteDouble(token) { return bare > ganttMaxDays }
        guard let unit = token.last, let factor = factors[unit],
              let value = finiteDouble(token.dropLast()) else { return false }
        return value * factor > ganttMaxDays
    }

    /// Julian Day Number for a proleptic-Gregorian `YYYY-MM-DD` string, or nil.
    /// Only day *differences* matter, so the absolute epoch is arbitrary; this
    /// is integer and timezone-free (works identically on Linux).
    static func dayOrdinal(fromISODate text: String) -> Double? {
        let parts = text.split(separator: "-")
        guard parts.count == 3,
              let year = Int(parts[0]), let month = Int(parts[1]), let day = Int(parts[2]),
              (1...12).contains(month), (1...31).contains(day), parts[0].count == 4
        else { return nil }
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        let jdn = day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
        return Double(jdn)
    }

    /// A Mermaid duration like `30d`, `2w`, `12h` in days, or nil. A bare
    /// number is treated as days.
    static func durationInDays(_ text: String) -> Double? {
        guard let unit = text.last else { return nil }
        // The bare-number path must sanitize too: Double("inf")/"nan" parse
        // successfully and a non-finite duration traps layout's Int(span)
        // conversions (a reproduced crash). Durations also cap at a century —
        // finite-but-absurd values otherwise size a multi-billion-point canvas.
        let maxDays = ganttMaxDays
        if let bare = MermaidParser.finiteDouble(text) {
            return bare >= 0 ? min(bare, maxDays) : nil  // "30" → 30 days
        }
        let value = MermaidParser.finiteDouble(text.dropLast())
        guard let value, value >= 0 else { return nil }
        switch unit {
        case "d": return min(value, maxDays)
        case "w": return min(value * 7, maxDays)
        case "h": return value / 24
        case "m": return value / (24 * 60)   // minutes
        case "y": return min(value * 365, maxDays)
        case "M": return min(value * 30, maxDays)   // months (mermaid's approximation)
        case "s": return value / (24 * 3600)
        default:
            // `Nms` (two-char unit) — vanishingly small on a day axis but a
            // valid token; without this it became the task's id.
            if text.hasSuffix("ms"), let ms = MermaidParser.finiteDouble(text.dropLast(2)), ms >= 0 {
                return ms / (24 * 3600 * 1000)
            }
            return nil
        }
    }
}
