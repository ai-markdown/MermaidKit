import Foundation

/// A Cynefin framework diagram (`cynefin-beta`): the five decision domains
/// with per-domain items and optional transitions between domains.
public struct CynefinDiagram: Hashable, Sendable {
    /// The five Cynefin domains. Raw values are the source keywords.
    public enum Domain: String, Hashable, Sendable, CaseIterable {
        case complex, complicated, clear, chaotic, confusion
        /// The canonical decision heuristic shown under the domain name.
        public var heuristic: String {
            switch self {
            case .complex: return "probe · sense · respond"
            case .complicated: return "sense · analyze · respond"
            case .clear: return "sense · categorize · respond"
            case .chaotic: return "act · sense · respond"
            case .confusion: return "break it down"
            }
        }
    }

    /// A movement between domains, e.g. `chaotic --> clear : "stabilize"`.
    public struct Transition: Hashable, Sendable {
        public let from: Domain
        public let to: Domain
        public let label: String?
        public init(from: Domain, to: Domain, label: String?) {
            self.from = from; self.to = to; self.label = label
        }
    }

    public var title: String?
    /// Items per domain, in source order.
    public var items: [Domain: [String]]
    public var transitions: [Transition]

    public init(title: String?, items: [Domain: [String]], transitions: [Transition]) {
        self.title = title; self.items = items; self.transitions = transitions
    }
}

extension MermaidParser {
    /// Parses `cynefin-beta` bodies: `title …`, domain keywords followed by
    /// that domain's quoted items (on the same line — `clear "A" "B"` — or on
    /// the lines below it), and `domain --> domain : "label"` transitions.
    ///
    /// Mirrors mermaid.js: a quoted item before any domain, an unquoted word
    /// after a domain (`clear {`, `clear A`), an unknown domain or any other
    /// statement makes the whole diagram fail to parse.
    static func parseCynefin(body: [String]) -> CynefinDiagram? {
        var title: String?
        var items: [CynefinDiagram.Domain: [String]] = [:]
        var transitions: [CynefinDiagram.Transition] = []
        var current: CynefinDiagram.Domain?

        for line in body {
            if line.hasPrefix("title ") {
                title = String(line.dropFirst(6)).trimmingCharacters(in: .whitespaces)
                continue
            }
            // Transition: complex --> complicated : "label"
            if line.contains("-->") {
                let parts = line.components(separatedBy: "-->")
                let fromToken = parts[0].trimmingCharacters(in: .whitespaces)
                guard parts.count == 2, let from = CynefinDiagram.Domain(rawValue: fromToken) else {
                    ParseReport.reject(.invalidSyntax,
                                       "cynefin transitions run between the domains complex, complicated, clear, chaotic and confusion",
                                       line: line)
                    return nil
                }
                let rest = parts[1]
                let toToken: String
                var label: String?
                if let colon = rest.firstIndex(of: ":") {
                    toToken = String(rest[..<colon]).trimmingCharacters(in: .whitespaces)
                    let written = rest[rest.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                    if let quoted = cynefinTokens(written), quoted.count == 1, case .quoted(let text) = quoted[0] {
                        label = text
                    } else {
                        // mermaid.js only accepts a quoted label; keep the text.
                        ParseReport.note(.invalidSyntax,
                                         "mermaid.js requires a quoted transition label (: \"label\")",
                                         line: line)
                        label = written.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
                    }
                } else {
                    toToken = rest.trimmingCharacters(in: .whitespaces)
                }
                guard let to = CynefinDiagram.Domain(rawValue: toToken) else {
                    ParseReport.reject(.invalidSyntax,
                                       "unknown cynefin domain '\(toToken)' in a transition",
                                       line: line)
                    return nil
                }
                transitions.append(.init(from: from, to: to, label: label))
                continue
            }
            // Domain keywords and quoted items, in any mix on one line:
            // `clear`, `clear "A" "B"`, `"A"` (under the last domain).
            guard let tokens = cynefinTokens(line) else {
                ParseReport.reject(.invalidSyntax, "unterminated quoted cynefin item", line: line)
                return nil
            }
            for token in tokens {
                switch token {
                case .word(let word):
                    guard let domain = CynefinDiagram.Domain(rawValue: word) else {
                        ParseReport.reject(.invalidSyntax,
                                           "unexpected '\(word)': cynefin items must be quoted and follow a domain (complex, complicated, clear, chaotic, confusion)",
                                           line: line)
                        return nil
                    }
                    current = domain
                    if items[domain] == nil { items[domain] = [] }
                case .quoted(let text):
                    guard let domain = current else {
                        ParseReport.reject(.invalidSyntax,
                                           "cynefin item \"\(text)\" comes before any domain",
                                           line: line)
                        return nil
                    }
                    items[domain, default: []].append(text)
                }
            }
        }
        guard !items.isEmpty || !transitions.isEmpty else { return nil }
        return CynefinDiagram(title: title, items: items, transitions: transitions)
    }

    enum CynefinToken: Equatable {
        case word(String)
        case quoted(String)
    }

    /// Splits a cynefin statement into bare words and `"…"`/`'…'` strings;
    /// nil when a quote is left open.
    static func cynefinTokens(_ line: String) -> [CynefinToken]? {
        var tokens: [CynefinToken] = []
        var i = line.startIndex
        while i < line.endIndex {
            let c = line[i]
            if c == " " || c == "\t" { i = line.index(after: i); continue }
            if c == "\"" || c == "'" {
                let start = line.index(after: i)
                guard let close = line[start...].firstIndex(of: c) else { return nil }
                tokens.append(.quoted(String(line[start..<close])))
                i = line.index(after: close)
                continue
            }
            var end = i
            while end < line.endIndex, line[end] != " ", line[end] != "\t",
                  line[end] != "\"", line[end] != "'" {
                end = line.index(after: end)
            }
            tokens.append(.word(String(line[i..<end])))
            i = end
        }
        return tokens
    }
}
