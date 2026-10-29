#if canImport(AppKit) || canImport(UIKit) || canImport(SilicaCairo)
import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import MermaidLayout

/// Bounds on the bitmap a render may allocate. Large diagrams render at a
/// reduced scale rather than failing; only a diagram that cannot fit even at
/// `minimumScale`, or that has a side of `maxDimension` points or more, is
/// refused — with ``MermaidRenderError/tooLarge(width:height:reason:)``.
public struct MermaidRasterLimits: Hashable, Sendable {
    /// Largest canvas side, in points, that is laid out into an image.
    public var maxDimension: CGFloat
    /// Largest decoded bitmap, in bytes (4 bytes per pixel).
    public var maxBytes: Int
    /// Smallest pixels-per-point scale a render may drop to in order to stay
    /// within `maxBytes`. Text becomes hard to read well below 1.
    public var minimumScale: CGFloat

    public init(maxDimension: CGFloat = 32_768, maxBytes: Int = 256 << 20, minimumScale: CGFloat = 0.5) {
        self.maxDimension = maxDimension
        self.maxBytes = maxBytes
        self.minimumScale = minimumScale
    }

    /// 32,768 pt per side, 256 MiB per bitmap, scale no lower than 0.5. The
    /// source-based image and attachment entry points use these limits.
    public static let `default` = MermaidRasterLimits()

    /// The scale to rasterize a `size`-point canvas at: `preferred` when the
    /// bitmap fits `maxBytes`, otherwise the largest scale that fits; nil when
    /// that is below `minimumScale`.
    func rasterScale(for size: CGSize, preferred: CGFloat) -> CGFloat? {
        let area = Double(size.width) * Double(size.height)
        guard area > 0, area.isFinite, maxBytes > 0 else { return nil }
        let fitting = CGFloat((Double(maxBytes) / (area * 4)).squareRoot())
        let scale = min(preferred, fitting)
        return scale >= minimumScale ? scale : nil
    }

    var fingerprint: String { "\(maxDimension)/\(maxBytes)/\(minimumScale)" }
}

/// Why ``MermaidRenderer/render(source:theme:spacing:limits:)`` produced no
/// image.
public enum MermaidRenderError: Error, Hashable, Sendable {
    /// Which limit a too-large diagram exceeded.
    public enum TooLargeReason: Hashable, Sendable {
        /// A canvas side reached ``MermaidRasterLimits/maxDimension`` points.
        case dimension(limit: Double)
        /// Even at ``MermaidRasterLimits/minimumScale`` the bitmap would
        /// exceed ``MermaidRasterLimits/maxBytes``.
        case memory(limitBytes: Int)
    }

    /// The source is not a diagram this package can parse; the diagnostics
    /// (from ``MermaidParser/diagnose(_:)``) say why.
    case unparseable([ParseDiagnostic])
    /// The diagram parsed but has nothing to draw.
    case emptyDiagram
    /// The laid-out diagram, `width` × `height` points, exceeds the raster
    /// limits. Hosts can show the source, offer an export (PDF/SVG are not
    /// subject to the bitmap budget), or retry with larger limits.
    case tooLarge(width: Double, height: Double, reason: TooLargeReason)
}

#if canImport(AppKit) || canImport(UIKit)
/// A rendered diagram plus what a host needs to present it honestly.
public struct MermaidRenderResult {
    /// The rendered diagram, sized in points to the diagram bounds.
    public let image: PlatformImage
    /// Notes about content that was left out, clamped, or accepted although
    /// mermaid.js would reject it. Empty when the render is expected to be
    /// complete; see ``isPartial``.
    public let diagnostics: [ParseDiagnostic]
    /// Pixels per point of the bitmap. Nil when the image draws lazily at the
    /// destination's scale (AppKit, within budget). Below the screen scale
    /// when the diagram was downscaled to fit ``MermaidRasterLimits/maxBytes``.
    public let rasterScale: CGFloat?
    /// VoiceOver-ready description of the diagram.
    public let altText: String?

    /// True when the diagram rendered but some source content is not shown
    /// as written (hosts can mark it "partially rendered" and offer the source).
    public var isPartial: Bool { !diagnostics.isEmpty }
}

extension MermaidRenderer {
    /// Renders Mermaid source and reports how complete the result is.
    ///
    /// Unlike ``image(source:theme:spacing:)``, which returns nil for every
    /// failure, this says why there is no image (``MermaidRenderError``) and
    /// returns the parse notes with a successful render, so a host can show
    /// "partially rendered" instead of silently presenting a diagram with
    /// missing content. Shares the render cache with the other source-based
    /// entry points.
    public static func render(source: String, theme: DiagramTheme,
                              spacing: DiagramSpacing = .regular,
                              limits: MermaidRasterLimits = .default) throws(MermaidRenderError) -> MermaidRenderResult {
        let entry = try DiagramRenderer.renderEntry(source: source, theme: theme, spacing: spacing, limits: limits).get()
        #if os(macOS)
        // NSImage is mutable; hand out a copy so the cached instance can't be
        // changed through the result.
        let image = (entry.image.copy() as? PlatformImage) ?? entry.image
        image.accessibilityDescription = entry.altText
        #else
        let image = entry.image
        #endif
        return MermaidRenderResult(image: image, diagnostics: entry.diagnostics,
                                   rasterScale: entry.rasterScale, altText: entry.altText)
    }
}
#endif
#endif
