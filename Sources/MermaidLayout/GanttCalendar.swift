import Foundation

/// Calendar arithmetic for Gantt charts on a Julian Day Number timeline.
///
/// An *ordinal* is a Julian Day Number (the civil date, midnight-based) plus
/// the time of day as a fraction. Everything here is integer or plain
/// floating-point arithmetic — no `Calendar`, `TimeZone` or `DateFormatter` —
/// so results are identical on Apple platforms and Linux, and timezone-free.
enum GanttCalendar {

    /// Years outside this range are rejected as dates (mermaid.js treats any
    /// date beyond 10,000 AD/BC as invalid; the integer algorithms below need
    /// a positive day number, so the floor is year 1).
    static let yearRange = 1...9999

    /// Ordinals are clamped to this range before any `Int` conversion, so a
    /// runaway (but finite) schedule can never trap.
    static let ordinalRange: ClosedRange<Double> = 0...100_000_000

    static let monthNames = ["January", "February", "March", "April", "May", "June", "July",
                             "August", "September", "October", "November", "December"]
    /// Sunday-first, matching `weekday(_:)`.
    static let weekdayNames = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    // MARK: - Civil date <-> Julian day

    /// Julian Day Number of a proleptic-Gregorian civil date. `day` may run
    /// past the month's end (1...31); it rolls into the next month, as
    /// JavaScript's `Date` does (`2026-02-30` is March 2). Callers bound the
    /// inputs (year 1...9999, month 1...12, day 1...31).
    static func julianDay(year: Int, month: Int, day: Int) -> Int {
        let a = (14 - month) / 12
        let y = year + 4800 - a
        let m = month + 12 * a - 3
        return day + (153 * m + 2) / 5 + 365 * y + y / 4 - y / 100 + y / 400 - 32045
    }

    /// The civil date of a (non-negative) Julian Day Number.
    static func civil(_ jdn: Int) -> (year: Int, month: Int, day: Int) {
        let j = max(jdn, 0)
        let f = j + 1401 + (((4 * j + 274_277) / 146_097) * 3) / 4 - 38
        let e = 4 * f + 3
        let g = (e % 1461) / 4
        let h = 5 * g + 2
        let day = (h % 153) / 5 + 1
        let month = ((h / 153 + 2) % 12) + 1
        let year = e / 1461 - 4716 + (12 + 2 - month) / 12
        return (year, month, day)
    }

    /// Day of the week, 0 = Sunday … 6 = Saturday.
    static func weekday(_ jdn: Int) -> Int { ((jdn + 1) % 7 + 7) % 7 }

    static func isLeapYear(_ year: Int) -> Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func daysInMonth(year: Int, month: Int) -> Int {
        switch month {
        case 2: return isLeapYear(year) ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// The whole Julian day of an ordinal, clamped so it always converts.
    static func day(of ordinal: Double) -> Int {
        guard ordinal.isFinite else { return 0 }
        return Int(min(max(ordinal, ordinalRange.lowerBound), ordinalRange.upperBound).rounded(.down))
    }

    /// Adds whole calendar months the way dayjs does: the day of the month is
    /// kept, clamped to the target month's length (Jan 31 + 1 month = Feb 28).
    static func addingMonths(_ months: Int, to ordinal: Double) -> Double {
        let jdn = day(of: ordinal)
        let fraction = ordinal - Double(jdn)
        let (y, m, d) = civil(jdn)
        let total = (y * 12 + (m - 1)).addingReportingOverflow(months)
        guard !total.overflow else { return ordinal }
        let year = total.partialValue / 12, month = total.partialValue % 12 + 1
        guard year >= 1 else { return ordinal }
        let clampedDay = min(d, daysInMonth(year: year, month: month))
        return Double(julianDay(year: year, month: month, day: clampedDay)) + fraction
    }

    // MARK: - Parsing

    /// Parses `text` with a dayjs-style `dateFormat` (strict: every field must
    /// match and the date must exist). Supported tokens: `YYYY YY M MM MMM MMMM
    /// D DD Do H HH h hh m mm s ss S SS SSS A a X x Z ZZ` and `[literal]`
    /// text. Nil when the text doesn't match.
    static func parse(_ text: String, format: String) -> Double? {
        let parts = tokenize(format)
        var scanner = Substring(text)
        var year = 1970, month = 1, day = 1, hour = 0, minute = 0, second = 0.0
        var pm: Bool?
        var offsetMinutes = 0
        var timestamp: Double?

        func digits(_ min: Int, _ max: Int) -> Int? {
            let run = scanner.prefix(while: { $0.isASCII && $0.isNumber }).prefix(max)
            guard run.count >= min, let value = Int(run) else { return nil }
            scanner = scanner.dropFirst(run.count)
            return value
        }

        for part in parts {
            switch part {
            case .literal(let lit):
                guard scanner.hasPrefix(lit) else { return nil }
                scanner = scanner.dropFirst(lit.count)
            case .token(let token):
                switch token {
                case "YYYY": guard let v = digits(4, 4) else { return nil }; year = v
                case "YY": guard let v = digits(2, 2) else { return nil }; year = v + (v > 68 ? 1900 : 2000)
                case "MM": guard let v = digits(2, 2) else { return nil }; month = v
                case "M": guard let v = digits(1, 2) else { return nil }; month = v
                case "MMM", "MMMM":
                    let lower = scanner.lowercased()
                    guard let index = monthNames.indices.first(where: { i in
                        let name = monthNames[i].lowercased()
                        return token == "MMMM" ? lower.hasPrefix(name) : lower.hasPrefix(String(name.prefix(3)))
                    }) else { return nil }
                    scanner = scanner.dropFirst(token == "MMMM" ? monthNames[index].count : 3)
                    month = index + 1
                case "DD": guard let v = digits(2, 2) else { return nil }; day = v
                case "D": guard let v = digits(1, 2) else { return nil }; day = v
                case "Do":
                    guard let v = digits(1, 2) else { return nil }
                    day = v
                    for suffix in ["st", "nd", "rd", "th"] where scanner.hasPrefix(suffix) {
                        scanner = scanner.dropFirst(2); break
                    }
                case "HH", "hh": guard let v = digits(2, 2) else { return nil }; hour = v
                case "H", "h": guard let v = digits(1, 2) else { return nil }; hour = v
                case "mm": guard let v = digits(2, 2) else { return nil }; minute = v
                case "m": guard let v = digits(1, 2) else { return nil }; minute = v
                case "ss": guard let v = digits(2, 2) else { return nil }; second += Double(v)
                case "s": guard let v = digits(1, 2) else { return nil }; second += Double(v)
                case "SSS", "SS", "S":
                    guard let v = digits(token.count, token.count) else { return nil }
                    second += Double(v) / pow(10, Double(token.count))
                case "A", "a":
                    let lower = scanner.lowercased()
                    if lower.hasPrefix("am") { pm = false } else if lower.hasPrefix("pm") { pm = true } else { return nil }
                    scanner = scanner.dropFirst(2)
                case "X", "x":
                    var run = scanner.prefix(while: { ($0.isASCII && $0.isNumber) || $0 == "." || $0 == "-" })
                    if token == "x" { run = run.prefix(while: { $0 != "." }) }
                    guard !run.isEmpty, let v = MermaidParser.finiteDouble(run) else { return nil }
                    scanner = scanner.dropFirst(run.count)
                    timestamp = token == "X" ? v : v / 1000
                case "Z", "ZZ":
                    if scanner.hasPrefix("Z") { scanner = scanner.dropFirst(); break }
                    guard let sign = scanner.first, sign == "+" || sign == "-" else { return nil }
                    scanner = scanner.dropFirst()
                    guard let hh = digits(2, 2) else { return nil }
                    if scanner.hasPrefix(":") { scanner = scanner.dropFirst() }
                    guard let mm = digits(2, 2) else { return nil }
                    offsetMinutes = (hh * 60 + mm) * (sign == "-" ? -1 : 1)
                default:
                    return nil
                }
            }
        }
        guard scanner.isEmpty else { return nil }

        if let timestamp {
            // Unix seconds → Julian day (1970-01-01 is JDN 2440588), bounded to
            // the supported year range.
            let ordinal = 2_440_588 + timestamp / 86_400
            guard ordinal >= Double(julianDay(year: yearRange.lowerBound, month: 1, day: 1)),
                  ordinal < Double(julianDay(year: yearRange.upperBound + 1, month: 1, day: 1))
            else { return nil }
            return ordinal
        }
        if let pm {
            guard (1...12).contains(hour) else { return nil }
            hour = hour % 12 + (pm ? 12 : 0)
        }
        guard yearRange.contains(year), (1...12).contains(month),
              (1...daysInMonth(year: year, month: month)).contains(day),
              (0...23).contains(hour), (0...59).contains(minute), second < 60
        else { return nil }
        let time = (Double(hour * 60 + minute - offsetMinutes) * 60 + second) / 86_400
        return Double(julianDay(year: year, month: month, day: day)) + time
    }

    /// The JavaScript-`Date`-style fallback mermaid.js applies when the strict
    /// `dateFormat` parse fails: `YYYY-M-D` or `YYYY/M/D`, optionally followed
    /// by ` HH:mm[:ss[.SSS]]` or `THH:mm…` and a `Z`. A day past the month's
    /// end rolls over (`2026-02-30` → March 2) as in V8; day 32+ and month 13+
    /// are invalid.
    static func parseISOLike(_ text: String) -> Double? {
        let utf8 = Array(text.utf8)
        var i = 0
        func number(maxDigits: Int) -> Int? {
            var value = 0, count = 0
            while i < utf8.count, count < maxDigits, (48...57).contains(utf8[i]) {
                value = value * 10 + Int(utf8[i] - 48); i += 1; count += 1
            }
            return count == 0 ? nil : value
        }
        let start = i
        guard let year = number(maxDigits: 4), i - start == 4, i < utf8.count else { return nil }
        let separator = utf8[i]
        guard separator == UInt8(ascii: "-") || separator == UInt8(ascii: "/") else { return nil }
        i += 1
        guard let month = number(maxDigits: 2), i < utf8.count, utf8[i] == separator else { return nil }
        i += 1
        guard let day = number(maxDigits: 2) else { return nil }
        guard yearRange.contains(year), (1...12).contains(month), (1...31).contains(day) else { return nil }
        var time = 0.0
        if i < utf8.count {
            guard utf8[i] == UInt8(ascii: " ") || utf8[i] == UInt8(ascii: "T") else { return nil }
            i += 1
            guard let hour = number(maxDigits: 2), i < utf8.count, utf8[i] == UInt8(ascii: ":") else { return nil }
            i += 1
            guard let minute = number(maxDigits: 2), hour < 24, minute < 60 else { return nil }
            var seconds = 0.0
            if i < utf8.count, utf8[i] == UInt8(ascii: ":") {
                i += 1
                guard let s = number(maxDigits: 2), s < 60 else { return nil }
                seconds = Double(s)
                if i < utf8.count, utf8[i] == UInt8(ascii: ".") {
                    i += 1
                    let fracStart = i
                    guard let ms = number(maxDigits: 3) else { return nil }
                    seconds += Double(ms) / pow(10, Double(i - fracStart))
                }
            }
            if i < utf8.count, utf8[i] == UInt8(ascii: "Z") { i += 1 }
            time = (Double(hour * 60 + minute) * 60 + seconds) / 86_400
        }
        guard i == utf8.count else { return nil }
        return Double(julianDay(year: year, month: month, day: day)) + time
    }

    /// True for a token shaped like an ISO date (`dddd-d…`), valid or not.
    static func looksLikeISODate(_ text: String) -> Bool {
        let utf8 = Array(text.utf8)
        guard utf8.count >= 6, utf8.prefix(4).allSatisfy({ (48...57).contains($0) }) else { return false }
        return utf8[4] == UInt8(ascii: "-") || utf8[4] == UInt8(ascii: "/")
    }

    private enum FormatPart { case literal(String), token(String) }

    /// Splits a dayjs format into tokens (longest match first) and literals.
    private static func tokenize(_ format: String) -> [FormatPart] {
        let tokens = ["YYYY", "MMMM", "SSS", "MMM", "YY", "MM", "Do", "DD", "HH", "hh", "mm", "ss", "SS", "ZZ",
                      "M", "D", "H", "h", "m", "s", "S", "A", "a", "X", "x", "Z"]
        var parts: [FormatPart] = []
        var rest = Substring(format)
        func appendLiteral(_ text: String) {
            if case .literal(let previous)? = parts.last {
                parts[parts.count - 1] = .literal(previous + text)
            } else {
                parts.append(.literal(text))
            }
        }
        while !rest.isEmpty {
            if rest.first == "[", let close = rest.firstIndex(of: "]") {
                appendLiteral(String(rest[rest.index(after: rest.startIndex)..<close]))
                rest = rest[rest.index(after: close)...]
                continue
            }
            if let token = tokens.first(where: { rest.hasPrefix($0) }) {
                parts.append(.token(token))
                rest = rest.dropFirst(token.count)
                continue
            }
            appendLiteral(String(rest.first!))
            rest = rest.dropFirst()
        }
        return parts
    }

    // MARK: - Formatting

    /// True when a strftime pattern shows a time of day (so sub-day ticks
    /// would get distinct labels).
    static func formatShowsTime(_ pattern: String) -> Bool {
        var chars = Array(pattern)[...]
        while let percent = chars.firstIndex(of: "%") {
            chars = chars[(percent + 1)...]
            if let flag = chars.first, "-_0".contains(flag) { chars = chars.dropFirst() }
            guard let directive = chars.first else { break }
            if "HIMSLpXcfsQ".contains(directive) { return true }
            chars = chars.dropFirst()
        }
        return false
    }

    /// Formats an ordinal with a d3/strftime `axisFormat`. Supports `%Y %y %m
    /// %d %e %b %B %a %A %H %I %M %S %L %p %j %u %w %x %X %c %%` and the `-`
    /// (no padding), `_` (space padding) and `0` modifiers; any other
    /// directive is kept literally.
    static func format(_ ordinal: Double, _ pattern: String) -> String {
        // Round to the nearest millisecond so 08:00 doesn't read 07:59.
        let clamped = min(max(ordinal.isFinite ? ordinal : 0, ordinalRange.lowerBound), ordinalRange.upperBound)
        var jdn = Int(clamped.rounded(.down))
        var ms = Int(((clamped - Double(jdn)) * 86_400_000).rounded())
        if ms >= 86_400_000 { jdn += 1; ms -= 86_400_000 }
        let (year, month, day) = civil(jdn)
        let hour = ms / 3_600_000, minute = ms / 60_000 % 60, second = ms / 1000 % 60, milli = ms % 1000
        let weekdayIndex = weekday(jdn)
        let dayOfYear = jdn - julianDay(year: year, month: 1, day: 1) + 1

        func pad(_ value: Int, _ width: Int, _ flag: Character?, _ defaultFill: Character = "0") -> String {
            let text = String(value)
            if flag == "-" { return text }
            let fill: Character = flag == "_" ? " " : (flag == "0" ? "0" : defaultFill)
            return text.count >= width ? text : String(repeating: fill, count: width - text.count) + text
        }

        var out = ""
        var chars = Array(pattern)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            guard c == "%" else { out.append(c); continue }
            var flag: Character?
            if let f = chars.first, "-_0".contains(f) { flag = f; chars = chars.dropFirst() }
            guard let d = chars.first else { out.append("%"); break }
            chars = chars.dropFirst()
            switch d {
            case "Y": out += pad(year, 4, flag)
            case "y": out += pad(year % 100, 2, flag)
            case "m": out += pad(month, 2, flag)
            case "d": out += pad(day, 2, flag)
            case "e": out += pad(day, 2, flag, " ")
            case "b": out += String(monthNames[month - 1].prefix(3))
            case "B": out += monthNames[month - 1]
            case "a": out += String(weekdayNames[weekdayIndex].prefix(3))
            case "A": out += weekdayNames[weekdayIndex]
            case "H": out += pad(hour, 2, flag)
            case "I": out += pad(hour % 12 == 0 ? 12 : hour % 12, 2, flag)
            case "M": out += pad(minute, 2, flag)
            case "S": out += pad(second, 2, flag)
            case "L": out += pad(milli, 3, flag)
            case "p": out += hour < 12 ? "AM" : "PM"
            case "j": out += pad(dayOfYear, 3, flag)
            case "u": out += String(weekdayIndex == 0 ? 7 : weekdayIndex)
            case "w": out += String(weekdayIndex)
            case "x": out += format(ordinal, "%-m/%-d/%Y")
            case "X": out += format(ordinal, "%-I:%M:%S %p")
            case "c": out += format(ordinal, "%-m/%-d/%Y, %-I:%M:%S %p")
            case "%": out += "%"
            default: out += "%" + (flag.map { String($0) } ?? "") + String(d)
            }
        }
        // d3 trims nothing, but `%e` pads with a space; keep the label tidy.
        return out.trimmingCharacters(in: .whitespaces)
    }
}
