import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Laid-out Cynefin framework: four fixed quadrants, the central confusion
/// disk, per-domain item text positions, and transition arrows.
public struct CynefinLayout: Sendable {
    public struct Item: Sendable {
        public let text: String
        public let center: CGPoint
    }
    public struct Quadrant: Sendable {
        public let domain: String
        public let name: String
        public let heuristic: String
        public let frame: CGRect
        public let colorIndex: Int
        public let items: [Item]
    }
    public struct Transition: Sendable {
        public let from: CGPoint
        public let to: CGPoint
        public let label: String?
        public let labelCenter: CGPoint
    }
    public let size: CGSize
    public let title: String?
    public let quadrants: [Quadrant]
    /// The central "confusion" disk (nil when the source never mentions it).
    public let center: Quadrant?
    public let centerRadius: CGFloat
    public let transitions: [Transition]
}

extension DiagramLayoutEngine {

    /// How much a Cynefin framework grows with its text: 1 at the default size.
    /// Its quadrants, rows and heading offsets are all tuned to the text, so
    /// they scale together; both renderers place the headings by it.
    package static func cynefinScale(_ measure: DiagramTextMeasurer) -> CGFloat {
        textGrowth(labelFontSize, measure)
    }
    /// Lays out a Cynefin diagram: a 2×2 (complex top-left, complicated
    /// top-right, chaotic bottom-left, clear bottom-right) with the confusion
    /// disk in the middle. Item text wraps to the quadrant width and stacks
    /// under each domain heading; the quadrants grow so no item runs under
    /// the disk, and the disk grows to hold all of its own items. Transitions
    /// run between quadrant centers, pulled toward the outer edges so arrows
    /// don't cross the middle disk.
    public static func layout(_ diagram: CynefinDiagram, measure: DiagramTextMeasurer) -> CynefinLayout {
        // Every quadrant, row and offset grows with the text (`cynefinScale`).
        let g = cynefinScale(measure)
        let margin: CGFloat = 14
        let titleHeight: CGFloat = diagram.title == nil ? 0 : Self.titleHeight(26, measure)
        let gap: CGFloat = 4
        let clearance: CGFloat = 2

        // The confusion disk: name, heuristic, then its items, each line
        // centered on the disk's vertical axis. The radius grows until every
        // text block fits inside the circle.
        let confusionItems = diagram.items[.confusion] ?? []
        let hasConfusion = diagram.items.keys.contains(.confusion)
        let diskFont: Double = 8.5
        let diskLines = confusionItems.map { cynefinWrap($0, width: 110 * g, fontSize: diskFont, measure) }
        var diskOffsets: [CGFloat] = []       // item block centers below the disk center
        var diskBlocks: [(dy: CGFloat, size: CGSize)] = [
            (-10 * g, measure("Confusion", 11)),
            (5 * g, measure(CynefinDiagram.Domain.confusion.heuristic, diskFont)),
        ]
        var diskCursor: CGFloat = 18 * g - 7.5 * g   // top of the first 15g slot
        for lines in diskLines {
            let lineHeight = measure("Ag", diskFont).height
            let slot = 15 * g + CGFloat(lines.count - 1) * lineHeight
            let dy = diskCursor + slot / 2
            diskOffsets.append(dy)
            diskBlocks.append((dy, measure(lines.joined(separator: "\n"), diskFont)))
            diskCursor += slot
        }
        var centerRadius: CGFloat = 52 * g
        if !confusionItems.isEmpty {
            for block in diskBlocks {
                let reach = hypot(abs(block.dy) + block.size.height / 2, block.size.width / 2) + 3
                centerRadius = max(centerRadius, reach)
            }
        }
        let keepOut = hasConfusion ? centerRadius + clearance : 0

        // Quadrant headings (name + heuristic), relative to the quadrant's
        // top-left corner, as half-width/vertical-extent pairs.
        func headingBlocks(_ domain: CynefinDiagram.Domain) -> [(halfWidth: CGFloat, top: CGFloat, bottom: CGFloat)] {
            let name = measure(domain.rawValue.capitalized, nodeFontSize)
            let heuristic = measure(domain.heuristic, 9)
            return [(name.width / 2, 18 * g - name.height / 2, 18 * g + name.height / 2),
                    (heuristic.width / 2, 34 * g - heuristic.height / 2, 34 * g + heuristic.height / 2)]
        }

        // The quadrant width: 250 at the default size, wider when a large
        // disk would otherwise reach a bottom quadrant's centered heading.
        var quadW: CGFloat = 250 * g
        if hasConfusion {
            for domain in [CynefinDiagram.Domain.chaotic, .clear] {
                for block in headingBlocks(domain) {
                    let dy = block.top + gap / 2     // disk center sits gap/2 above the quadrant
                    guard dy < keepOut else { continue }
                    let dx = (keepOut * keepOut - dy * dy).squareRoot()
                    quadW = max(quadW, 2 * (dx - gap / 2 + block.halfWidth))
                }
            }
        }

        // Item blocks: each item wraps to the quadrant width and occupies a
        // 17g slot plus a line per extra wrapped line.
        let itemLineHeight = measure("Ag", labelFontSize).height
        let wrapWidth = quadW - 28 * g
        struct Placed { var text: String; var centerY: CGFloat; var size: CGSize }

        // How far a block (centered horizontally in the quadrant, `halfWidth`
        // wide) must stay from the disk vertically: zero when it clears the
        // disk sideways.
        func diskVerticalReach(halfWidth: CGFloat) -> CGFloat {
            let dx = quadW / 2 - halfWidth + gap / 2   // block's inner side to the disk center
            guard dx < keepOut else { return -.greatestFiniteMagnitude }
            return (keepOut * keepOut - dx * dx).squareRoot()
        }

        let placement: [(CynefinDiagram.Domain, Int, Int)] = [
            (.complex, 0, 0), (.complicated, 1, 0), (.chaotic, 0, 1), (.clear, 1, 1),
        ]
        var placedItems: [CynefinDiagram.Domain: [Placed]] = [:]
        var quadH: CGFloat = 150 * g
        for (domain, _, row) in placement {
            var cursor: CGFloat = 43.5 * g
            var placed: [Placed] = []
            for text in diagram.items[domain] ?? [] {
                let lines = cynefinWrap(text, width: wrapWidth, fontSize: labelFontSize, measure)
                let joined = lines.joined(separator: "\n")
                let size = measure(joined, labelFontSize)
                let slot = 17 * g + CGFloat(lines.count - 1) * itemLineHeight
                var top = cursor
                if row == 1, hasConfusion {
                    // Bottom row: the disk sits on the quadrant's top inner
                    // corner — push a block down until it clears it.
                    let blockTop = top + slot / 2 - size.height / 2
                    let minTop = diskVerticalReach(halfWidth: size.width / 2) - gap / 2
                    if blockTop < minTop { top += minTop - blockTop }
                }
                let centerY = top + slot / 2
                placed.append(Placed(text: joined, centerY: centerY, size: size))
                cursor = top + slot
                if row == 0, hasConfusion {
                    // Top row: the disk sits on the bottom inner corner, so
                    // the quadrant must be tall enough to keep it clear.
                    let reach = diskVerticalReach(halfWidth: size.width / 2)
                    quadH = max(quadH, centerY + size.height / 2 - gap / 2 + reach)
                }
            }
            quadH = max(quadH, cursor + 20.5 * g)
            if row == 0, hasConfusion {
                for block in headingBlocks(domain) {
                    quadH = max(quadH, block.bottom - gap / 2 + diskVerticalReach(halfWidth: block.halfWidth))
                }
            }
            placedItems[domain] = placed
        }

        let originY = margin + titleHeight
        var quadrants: [CynefinLayout.Quadrant] = []
        for (index, (domain, col, row)) in placement.enumerated() {
            let frame = CGRect(
                x: margin + CGFloat(col) * (quadW + gap),
                y: originY + CGFloat(row) * (quadH + gap),
                width: quadW, height: quadH)
            let items = (placedItems[domain] ?? []).map { item in
                CynefinLayout.Item(text: item.text, center: CGPoint(x: frame.midX, y: frame.minY + item.centerY))
            }
            quadrants.append(.init(
                domain: domain.rawValue, name: domain.rawValue.capitalized,
                heuristic: domain.heuristic, frame: frame,
                colorIndex: index, items: items))
        }

        let full = CGRect(x: margin, y: originY,
                          width: quadW * 2 + gap, height: quadH * 2 + gap)
        var center: CynefinLayout.Quadrant?
        if hasConfusion {
            let frame = CGRect(x: full.midX - centerRadius, y: full.midY - centerRadius,
                               width: centerRadius * 2, height: centerRadius * 2)
            let items = zip(diskLines, diskOffsets).map { lines, dy in
                CynefinLayout.Item(text: lines.joined(separator: "\n"),
                                   center: CGPoint(x: frame.midX, y: frame.midY + dy))
            }
            center = .init(domain: "confusion", name: "Confusion",
                           heuristic: CynefinDiagram.Domain.confusion.heuristic,
                           frame: frame, colorIndex: 4, items: items)
        }

        // Transitions: from/to points sit on the segment between the two
        // quadrant centers, inset so arrows live in the border zone.
        func quadrantCenter(_ domain: CynefinDiagram.Domain) -> CGPoint {
            if domain == .confusion { return CGPoint(x: full.midX, y: full.midY) }
            guard let q = quadrants.first(where: { $0.domain == domain.rawValue }) else {
                return CGPoint(x: full.midX, y: full.midY)
            }
            return CGPoint(x: q.frame.midX, y: q.frame.midY)
        }
        let diagramCenter = CGPoint(x: full.midX, y: full.midY)
        let transitions: [CynefinLayout.Transition] = diagram.transitions.map { t in
            let a = quadrantCenter(t.from), b = quadrantCenter(t.to)
            var from = CGPoint(x: a.x + (b.x - a.x) * 0.30, y: a.y + (b.y - a.y) * 0.30)
            var to = CGPoint(x: a.x + (b.x - a.x) * 0.70, y: a.y + (b.y - a.y) * 0.70)
            // Quadrant-to-quadrant arrows shift toward the OUTER edge so they
            // run in the corridor past the item stacks instead of through
            // them; confusion-involved arrows stay on the centerline (short,
            // and the disk's surroundings are clear).
            if t.from != .confusion, t.to != .confusion {
                let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
                var away = CGVector(dx: mid.x - diagramCenter.x, dy: mid.y - diagramCenter.y)
                let magnitude = max(hypot(away.dx, away.dy), 0.001)
                away.dx /= magnitude
                away.dy /= magnitude
                let shift: CGFloat = min(quadW, quadH) * 0.30
                from.x += away.dx * shift
                from.y += away.dy * shift
                to.x += away.dx * shift
                to.y += away.dy * shift
            }
            return .init(from: from, to: to, label: t.label,
                         labelCenter: CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2 - 10 * g))
        }

        return CynefinLayout(
            size: CGSize(width: full.maxX + margin, height: full.maxY + margin),
            title: diagram.title,
            quadrants: quadrants, center: center, centerRadius: centerRadius,
            transitions: transitions)
    }

    /// Greedy word wrap of a cynefin item to `width`, honoring explicit
    /// `<br>`/`\n` breaks; a word (or an unspaced CJK run) wider than the line
    /// breaks between characters.
    static func cynefinWrap(_ text: String, width: CGFloat, fontSize: Double,
                            _ measure: DiagramTextMeasurer) -> [String] {
        var out: [String] = []
        let paragraphs = brLines(text)
        for paragraph in paragraphs.isEmpty ? [text] : paragraphs {
            var current = ""
            func fits(_ candidate: String) -> Bool { measure(candidate, fontSize).width <= width }
            for word in paragraph.split(separator: " ").map(String.init) {
                let candidate = current.isEmpty ? word : current + " " + word
                if fits(candidate) { current = candidate; continue }
                if !current.isEmpty, fits(word) {
                    out.append(current)
                    current = word
                    continue
                }
                // Too wide even alone: break it between characters.
                var piece = current.isEmpty ? "" : current + " "
                for character in word {
                    let next = piece + String(character)
                    if !piece.trimmingCharacters(in: .whitespaces).isEmpty, !fits(next) {
                        out.append(piece.trimmingCharacters(in: .whitespaces))
                        piece = String(character)
                    } else {
                        piece = next
                    }
                }
                current = piece
            }
            if !current.isEmpty { out.append(current) }
        }
        return out.isEmpty ? [text] : out
    }
}
