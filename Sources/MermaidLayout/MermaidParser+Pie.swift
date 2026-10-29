import Foundation

extension MermaidParser {

    /// Parses a `pie` chart: an optional `title` (on the header line or the
    /// next), then `"Label" : 42.5` slice rows (non-negative values).
    /// Nil when no valid slice parses.
    static func parsePie(header: String, body: [String]) -> PieChart? {
        var title: String?
        var lines = body

        // Title can ride the header line or the next line.
        if let range = header.range(of: "title ") {
            title = String(header[range.upperBound...]).trimmingCharacters(in: .whitespaces)
        } else if let first = lines.first, first.hasPrefix("title ") {
            title = String(first.dropFirst("title ".count)).trimmingCharacters(in: .whitespaces)
            lines.removeFirst()
        }

        var slices: [PieChart.Slice] = []
        for line in lines {
            // "Label" : 42.5
            guard let colon = line.lastIndex(of: ":") else {
                if line != "showData" {
                    ParseReport.note(.invalidSyntax, "pie statement '\(line)' is not a slice and was ignored; mermaid.js rejects it", line: line)
                }
                continue
            }
            let rawLabel = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            let label = rawLabel.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let valueText = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            // mermaid.js 11.17.2 requires a double-quoted label and a plain
            // non-negative decimal (`\d+(\.\d+)?`: no sign, exponent, or
            // leading dot); anything else fails the whole diagram.
            guard rawLabel.count >= 2, rawLabel.hasPrefix("\""), rawLabel.hasSuffix("\""), !label.isEmpty else {
                ParseReport.reject(.invalidSyntax, "pie slice label must be double-quoted: '\(line)'", line: line)
                return nil
            }
            guard isPlainDecimal(valueText), let value = MermaidParser.finiteDouble(valueText) else {
                ParseReport.reject(.invalidSyntax,
                                   "pie slice value must be a non-negative decimal number: '\(line)'", line: line)
                return nil
            }
            if value >= 1e12 {
                ParseReport.note(.valueClamped, "pie slice value '\(valueText)' was clamped to 1e12", line: line)
            }
            slices.append(PieChart.Slice(label: label, value: value))
        }
        guard !slices.isEmpty else { return nil }
        return PieChart(title: title, slices: slices)
    }

    /// `\d+(\.\d+)?` — the number token mermaid.js's pie grammar accepts.
    static func isPlainDecimal(_ text: String) -> Bool {
        let parts = text.split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        let digits: (Substring) -> Bool = { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }
        return digits(parts[0]) && (parts.count == 1 || digits(parts[1]))
    }
}
