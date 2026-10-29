import Foundation

/// A human-readable reason `MermaidParser.parse` returned nil (or a note
/// about degraded input) — the answer to "why didn't my diagram render?".
public struct ParseDiagnostic: Hashable, Sendable {
    public enum Severity: String, Hashable, Sendable {
        /// The source cannot produce a diagram.
        case error
        /// The source parses, but something the author wrote was set aside: a
        /// flowchart statement the parser couldn't read (left out of the
        /// diagram), a stray `end`, an unknown direction, content the renderer
        /// cannot draw, or syntax mermaid.js itself would reject. Styling
        /// ignored on purpose (`classDef`, `style`, `click`…) isn't reported.
        /// A host that receives any `.note` should treat the render as
        /// partial (for example, offer the source next to the image).
        case note
    }

    /// A stable, machine-readable category, so hosts can react to a class of
    /// problem without matching on the English `message`.
    public enum Code: String, Hashable, Sendable {
        /// The source is empty or only comments.
        case emptySource
        /// The source exceeds `MermaidParser.maxTextSize`.
        case sourceTooLarge
        /// A structural limit was exceeded (edge cap, nesting depth).
        case limitExceeded
        /// The header names no supported diagram type.
        case unknownDiagramType
        /// The header was recognized but the body produced nothing to draw.
        case noUsableContent
        /// Syntax that mermaid.js rejects. As an `.error` the parse was
        /// rejected to match mermaid.js; as a `.note` it was rendered
        /// leniently and the result may differ from mermaid.js.
        case invalidSyntax
        /// A statement was skipped and is missing from the rendered diagram.
        case statementSetAside
        /// The statement parsed, but part of its content is not drawn.
        case contentDropped
        /// A numeric value was out of range and was clamped or saturated.
        case valueClamped
        /// A directive or option that is recognized but not implemented.
        case unsupportedFeature
    }

    public let severity: Severity
    /// 1-based line in the original source, or nil when the diagnostic is
    /// about the source as a whole (size caps, empty input).
    public let line: Int?
    public let message: String
    /// The diagnostic's category; nil only for diagnostics built by callers
    /// that predate codes.
    public let code: Code?

    public init(severity: Severity, line: Int?, message: String, code: Code? = nil) {
        self.severity = severity
        self.line = line
        self.message = message
        self.code = code
    }
}

/// Collects diagnostics that dialect parsers report while parsing. Parsers
/// call `ParseReport.note`/`ParseReport.reject`; the reports are only
/// gathered while `MermaidParser.diagnose` (or another collecting caller)
/// has installed a sink, so the plain `parse` path stays allocation-free.
enum ParseReport {
    struct Entry: Sendable {
        let severity: ParseDiagnostic.Severity
        let code: ParseDiagnostic.Code
        let message: String
        /// The trimmed source line the report is about, resolved to a line
        /// number by the collector; nil for whole-diagram reports.
        let lineText: String?
    }

    final class Sink: @unchecked Sendable {
        private let lock = NSLock()
        private var storage: [Entry] = []
        func append(_ entry: Entry) { lock.withLock { storage.append(entry) } }
        var entries: [Entry] { lock.withLock { storage } }
    }

    @TaskLocal static var sink: Sink?

    /// Reports content that renders degraded (dropped, clamped, or accepted
    /// although mermaid.js rejects it).
    static func note(_ code: ParseDiagnostic.Code, _ message: @autoclosure () -> String,
                     line: String? = nil) {
        guard let sink else { return }
        sink.append(Entry(severity: .note, code: code, message: message(),
                          lineText: line.map { $0.trimmingCharacters(in: .whitespaces) }))
    }

    /// Records why a parser is about to return nil, so `diagnose` can give
    /// the precise reason instead of a generic one.
    static func reject(_ code: ParseDiagnostic.Code, _ message: @autoclosure () -> String,
                       line: String? = nil) {
        guard let sink else { return }
        sink.append(Entry(severity: .error, code: code, message: message(),
                          lineText: line.map { $0.trimmingCharacters(in: .whitespaces) }))
    }

    /// Runs `body` with a fresh sink installed and returns its reports.
    static func collecting<T>(_ body: () -> T) -> (T, [Entry]) {
        let sink = Sink()
        let value = $sink.withValue(sink, operation: body)
        return (value, sink.entries)
    }
}

extension MermaidParser {

    /// The diagram-type headers `parse` recognizes, in canonical spelling —
    /// the vocabulary "did you mean" suggestions draw from.
    public static let knownHeaders: [String] = [
        "flowchart", "graph", "sequenceDiagram", "pie", "stateDiagram-v2",
        "classDiagram", "erDiagram", "gantt", "timeline", "mindmap",
        "journey", "quadrantChart", "packet-beta", "xychart-beta", "kanban",
        "radar-beta", "treemap-beta", "treeView-beta", "venn-beta", "cynefin-beta", "wardley-beta", "ishikawa-beta", "eventmodeling", "swimlane-beta", "gitGraph", "sankey-beta",
        "requirementDiagram", "zenuml", "C4Context", "architecture-beta",
        "block-beta",
    ]

    /// Explains a source that `parse` rejects, or, for a source it accepts,
    /// notes what it left out, clamped, or accepted although mermaid.js would
    /// reject it (`.note`s). An empty result means the diagram is expected to
    /// render completely. Deliberately cheap — safe to call on every parse to build an
    /// error UI, a log line, or a host's "show the source instead" check:
    ///
    /// ```swift
    /// guard let diagram = MermaidParser.parse(source) else {
    ///     let reasons = MermaidParser.diagnose(source)
    ///     // "line 1: unknown diagram type 'flowchar' — did you mean 'flowchart'?"
    /// }
    /// ```
    public static func diagnose(_ source: String) -> [ParseDiagnostic] {
        // Whole-source guards, in the same order parse() applies them.
        guard !source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return [.init(severity: .error, line: nil, message: "source is empty", code: .emptySource)]
        }
        guard source.count <= maxTextSize else {
            return [.init(severity: .error, line: nil,
                          message: "source is \(source.count) characters; the cap is \(maxTextSize) (MermaidParser.maxTextSize)",
                          code: .sourceTooLarge)]
        }
        let source = normalizedLineEndings(source)

        // Locate the header: first line that isn't blank or a %% comment.
        let rawLines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard let headerIndex = rawLines.firstIndex(where: { !$0.isEmpty && !$0.hasPrefix("%%") }) else {
            return [.init(severity: .error, line: nil, message: "source contains only comments/blank lines",
                          code: .emptySource)]
        }
        let header = rawLines[headerIndex]
        let headerLine = headerIndex + 1
        let headerWord = String(header.split(separator: " ").first ?? "")

        let (parsed, reports) = ParseReport.collecting { parse(source) }
        if parsed != nil {
            return setAsideNotes(source) + resolve(reports.filter { $0.severity == .note }, in: source)
        }
        let rejections = resolve(reports.filter { $0.severity == .error }, in: source)
        if !rejections.isEmpty { return rejections }

        // The header was recognized but the parse still failed: either the
        // flowchart edge cap, or a body the type parser couldn't use.
        if knownHeaders.contains(where: { header.hasPrefix(commonPrefixKey($0)) }) {
            if header.hasPrefix("graph") || header.hasPrefix("flowchart") {
                // Distinguish the edge cap from an empty/broken body.
                let statements = rawLines.filter { !$0.isEmpty && !$0.hasPrefix("%%") }.flatMap(flowchartStatements)
                if let first = statements.first,
                   let chart = parseFlowchart(header: first, body: Array(statements.dropFirst())),
                   chart.edges.count > maxEdges {
                    return [.init(severity: .error, line: nil,
                                  message: "flowchart has \(chart.edges.count) edges; the cap is \(maxEdges) (MermaidParser.maxEdges)",
                                  code: .limitExceeded)]
                }
            }
            return [.init(severity: .error, line: headerLine,
                          message: "recognized '\(headerWord)' but the body produced no usable content — check the type's core syntax",
                          code: .noUsableContent)]
        }

        // Unknown header — suggest the nearest known one.
        if let suggestion = nearestHeader(to: headerWord) {
            return [.init(severity: .error, line: headerLine,
                          message: "unknown diagram type '\(headerWord)' — did you mean '\(suggestion)'?",
                          code: .unknownDiagramType)]
        }
        return [.init(severity: .error, line: headerLine,
                      message: "unknown diagram type '\(headerWord)'", code: .unknownDiagramType)]
    }

    /// Maps parser reports to diagnostics, resolving each report's line text
    /// to its 1-based line in `source`. Reports usually arrive in source
    /// order, so the search resumes after the previous match (falling back to
    /// the first occurrence) to tell repeated identical lines apart.
    private static func resolve(_ reports: [ParseReport.Entry], in source: String) -> [ParseDiagnostic] {
        guard !reports.isEmpty else { return [] }
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        var cursor = 0
        var seen = Set<ParseDiagnostic>()
        var result: [ParseDiagnostic] = []
        for report in reports {
            var line: Int?
            if let text = report.lineText {
                if let hit = lines[cursor...].firstIndex(of: text) ?? lines.firstIndex(of: text) {
                    line = hit + 1
                    cursor = hit
                }
            }
            let diagnostic = ParseDiagnostic(severity: report.severity, line: line,
                                             message: report.message, code: report.code)
            if seen.insert(diagnostic).inserted { result.append(diagnostic) }
        }
        return result
    }

    /// Converts `\r\n` and lone `\r` line breaks to `\n`, as mermaid.js does
    /// before parsing (`/\r\n?/g` → `\n`). Swift treats `\r\n` as a single
    /// `Character`, so without this a CRLF source never splits on `"\n"`.
    static func normalizedLineEndings(_ source: String) -> String {
        guard source.utf8.contains(13) else { return source }
        return source
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
    }

    /// A `.note` for each statement a flowchart that parses set aside, at its
    /// line in `source`; `[]` for every other type.
    private static func setAsideNotes(_ source: String) -> [ParseDiagnostic] {
        let body = strippingMetadata(from: source).lines
            .map { (text: $0.text.trimmingCharacters(in: .whitespaces), line: $0.line) }
            .filter { !$0.text.isEmpty && !$0.text.hasPrefix("%%") }
        guard let header = body.first?.text, header.hasPrefix("graph") || header.hasPrefix("flowchart") else { return [] }

        let statements = body.flatMap { line in
            flowchartStatements(line.text).map { (text: $0, line: Optional(line.line)) }
        }
        guard let first = statements.first else { return [] }

        var notes: [ParseDiagnostic] = []
        let chart = parseFlowchart(header: first.text, body: statements.dropFirst().map(\.text)) { index, reason in
            notes.append(.init(severity: .note, line: statements[index + 1].line, message: reason,
                               code: .statementSetAside))
        }
        if let chart, chart.nodes.isEmpty, chart.subgraphs.isEmpty {
            notes.append(.init(severity: .note, line: first.line,
                               message: "the flowchart has no nodes, so there's nothing to draw; it renders empty",
                               code: .contentDropped))
        }
        return notes
    }

    /// The prefix `parse` actually matches for a canonical header ("pie"
    /// matches "pie showData", "C4Context" is matched via "C4"…).
    private static func commonPrefixKey(_ canonical: String) -> String {
        if canonical.hasPrefix("C4") { return "C4" }
        if canonical == "stateDiagram-v2" { return "stateDiagram" }
        // block-beta is matched by parse() in FULL (a bare "block" is not a
        // recognized header), unlike the other -beta types which match on
        // their stem.
        if canonical == "block-beta" { return "block-beta" }
        if let dash = canonical.firstIndex(of: "-") { return String(canonical[..<dash]) }
        return canonical
    }

    /// Case-insensitive nearest known header within a small edit distance —
    /// generous enough for typos, strict enough not to "correct" arbitrary text.
    private static func nearestHeader(to word: String) -> String? {
        guard !word.isEmpty else { return nil }
        var best: (header: String, distance: Int)?
        for header in knownHeaders {
            let d = editDistance(word.lowercased(), header.lowercased())
            if best == nil || d < best!.distance { best = (header, d) }
        }
        guard let best, best.distance <= max(2, word.count / 4) else { return nil }
        return best.header
    }

    private static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a.utf8), b = Array(b.utf8)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var previous = Array(0...b.count)
        var current = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            current[0] = i
            for j in 1...b.count {
                let substitution = previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1)
                current[j] = min(previous[j] + 1, current[j - 1] + 1, substitution)
            }
            swap(&previous, &current)
        }
        return previous[b.count]
    }
}
