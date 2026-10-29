import Foundation

extension MermaidParser {

    /// Notes for constructs mermaid.js 11.17.2 rejects although this parser
    /// renders them. The diagram is still drawn (refusing input this package
    /// can draw would only hide content), but a host comparing against
    /// mermaid.js, or showing "partially rendered", learns about it.
    ///
    /// The checks follow mermaid.js's lexers: several grammars only accept
    /// ASCII in unquoted names (sankey accepts no non-ASCII text at all), and
    /// zenuml is an external plugin that mermaid.js core does not register.
    static func reportCompatibilityNotes(_ diagram: MermaidDiagram, body: String) {
        let lines = body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("%%") }
            .dropFirst()   // the header

        func note(_ line: String, _ what: String) {
            ParseReport.note(.invalidSyntax,
                             "\(what) — mermaid.js 11.17.2 rejects this line, so the Web renderer will not draw this diagram",
                             line: line)
        }

        switch diagram {
        case .zenuml:
            ParseReport.note(.invalidSyntax,
                             "zenuml needs mermaid.js's external @mermaid-js/mermaid-zenuml plugin; mermaid.js core 11.17.2 does not render it")
        case .sankey:
            for line in lines where line.contains(where: { !$0.isASCII }) {
                note(line, "sankey text must be ASCII, quoted or not")
            }
        case .gitGraph:
            for line in lines {
                let words = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard words.count == 2, ["branch", "checkout", "switch", "merge"].contains(words[0]) else { continue }
                let name = words[1].split(separator: " ").first.map(String.init) ?? ""
                if !name.hasPrefix("\""), name.contains(where: { !$0.isASCII }) {
                    note(line, "unquoted non-ASCII branch name '\(name)' (quote it)")
                }
            }
        case .xychart:
            for line in lines where line.hasPrefix("title") || line.hasPrefix("x-axis") || line.hasPrefix("y-axis") {
                if unquoted(line).contains(where: { !$0.isASCII }) {
                    note(line, "unquoted non-ASCII title or axis text (quote it)")
                }
            }
        case .requirement:
            for line in lines where unquoted(line).contains(where: { !$0.isASCII }) {
                note(line, "unquoted non-ASCII requirement name or value (quote it)")
            }
        case .wardley:
            for line in lines where !line.hasPrefix("title") && unquoted(line).contains(where: { !$0.isASCII }) {
                note(line, "unquoted non-ASCII component name (quote it)")
            }
        default:
            break
        }
    }

    /// `line` with its double-quoted segments removed.
    private static func unquoted(_ line: String) -> String {
        var result = ""
        var inQuotes = false
        for character in line {
            if character == "\"" { inQuotes.toggle(); continue }
            if !inQuotes { result.append(character) }
        }
        return result
    }
}
