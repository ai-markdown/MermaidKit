#if canImport(AppKit) || canImport(UIKit)
import XCTest
import MermaidLayout
@testable import MermaidRender
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Large diagrams used to come back as a silent nil whenever a canvas side
/// reached 4000 pt (100-node flowcharts, 300-message sequences). They now
/// render — downscaled when the bitmap would exceed the memory budget — and
/// anything that still can't render says why through `MermaidRenderError`.
final class LargeDiagramRenderTests: XCTestCase {
    private let theme = DiagramTheme(prefersDark: false)

    /// A binary-tree flowchart, as in the evaluation corpus.
    private func flowTree(_ count: Int) -> String {
        "flowchart TD\n" + (1..<count).map { "  n\(($0 - 1) / 2)[Node \(($0 - 1) / 2)] --> n\($0)[Node \($0)]" }
            .joined(separator: "\n")
    }

    private func sequence(_ count: Int) -> String {
        "sequenceDiagram\n" + (0..<count).map { "  P\($0 % 8)->>P\(($0 * 3 + 1) % 8): message \($0)" }
            .joined(separator: "\n")
    }

    func testDiagramsPastTheOld4000PointCapRender() throws {
        for source in [flowTree(100), sequence(300)] {
            let image = try XCTUnwrap(MermaidRenderer.image(source: source, theme: theme))
            XCTAssertGreaterThanOrEqual(max(image.size.width, image.size.height), 4000)
            let result = try MermaidRenderer.render(source: source, theme: theme)
            XCTAssertEqual(result.image.size, image.size)
            XCTAssertFalse(result.isPartial)
        }
    }

    func testDimensionLimitIsReportedWithMeasuredSize() throws {
        let source = sequence(300)
        let full = try MermaidRenderer.render(source: source, theme: theme).image.size
        let limits = MermaidRasterLimits(maxDimension: 2000)
        XCTAssertThrowsError(try MermaidRenderer.render(source: source, theme: theme, limits: limits)) { error in
            guard case MermaidRenderError.tooLarge(let width, let height, .dimension(let limit))? = error as? MermaidRenderError else {
                return XCTFail("expected tooLarge(.dimension), got \(error)")
            }
            XCTAssertEqual(width, Double(full.width), accuracy: 0.5)
            XCTAssertEqual(height, Double(full.height), accuracy: 0.5)
            XCTAssertEqual(limit, 2000)
        }
    }

    func testMemoryBudgetDownscalesThenRefuses() throws {
        let source = flowTree(40)
        let size = try MermaidRenderer.render(source: source, theme: theme).image.size
        let area = Double(size.width * size.height)

        // A budget that only fits ~1x: the render drops below the preferred
        // scale but stays above the minimum, and the bitmap honors it.
        let squeezed = MermaidRasterLimits(maxBytes: Int(area * 4 * 1.1), minimumScale: 0.5)
        let result = try MermaidRenderer.render(source: source, theme: theme, limits: squeezed)
        let scale = try XCTUnwrap(result.rasterScale)
        XCTAssertLessThan(scale, 1.1)
        XCTAssertGreaterThan(scale, 0.9)
        // UIKit rounds a fractional-scale bitmap to whole pixels, so the
        // point size may drift by under one pixel.
        XCTAssertEqual(result.image.size.width, size.width, accuracy: 1 / scale)
        XCTAssertEqual(result.image.size.height, size.height, accuracy: 1 / scale)
        let pixels = try XCTUnwrap(cgImage(result.image))
        XCTAssertLessThanOrEqual(pixels.width * pixels.height * 4, squeezed.maxBytes + 4 * (pixels.width + pixels.height + 1))

        // A budget below the minimum scale is refused with the memory reason.
        let starved = MermaidRasterLimits(maxBytes: Int(area * 4 * 0.1), minimumScale: 0.5)
        XCTAssertThrowsError(try MermaidRenderer.render(source: source, theme: theme, limits: starved)) { error in
            guard case MermaidRenderError.tooLarge(_, _, .memory(let bytes))? = error as? MermaidRenderError else {
                return XCTFail("expected tooLarge(.memory), got \(error)")
            }
            XCTAssertEqual(bytes, starved.maxBytes)
        }
    }

    /// The downscaled bitmap path draws the same picture as the default path
    /// (same orientation, same content), just at its own scale.
    func testDownscaledBitmapMatchesDefaultRender() throws {
        let source = "flowchart LR\n  A[Start] --> B{Check}\n  B -->|yes| C[Done]\n  B -->|no| A"
        let reference = try MermaidRenderer.render(source: source, theme: theme)
        let size = reference.image.size
        let oneX = MermaidRasterLimits(maxBytes: Int(size.width * size.height * 4), minimumScale: 0.5)
        let squeezed = try MermaidRenderer.render(source: source, theme: theme, limits: oneX)
        let a = try XCTUnwrap(bitmap(reference.image, scale: 1))
        let b = try XCTUnwrap(bitmap(squeezed.image, scale: 1))
        XCTAssertEqual(a.count, b.count)
        var diff = 0.0
        for i in 0..<min(a.count, b.count) { diff += abs(Double(a[i]) - Double(b[i])) }
        XCTAssertLessThan(diff / Double(a.count), 6, "downscaled render differs from the default render")
    }

    func testUnparseableAndPartialRendersAreDistinguished() throws {
        XCTAssertThrowsError(try MermaidRenderer.render(source: "flowchar TD\n A --> B", theme: theme)) { error in
            guard case MermaidRenderError.unparseable(let diagnostics)? = error as? MermaidRenderError else {
                return XCTFail("expected unparseable, got \(error)")
            }
            XCTAssertEqual(diagnostics.first?.code, .unknownDiagramType)
        }
        let partial = try MermaidRenderer.render(
            source: "flowchart LR\n  A[Start] --> B{Ok?}\n  this is not mermaid ]]]", theme: theme)
        XCTAssertTrue(partial.isPartial)
        XCTAssertEqual(partial.diagnostics.map(\.line), [3])
        // A cache hit returns the same diagnostics.
        let again = try MermaidRenderer.render(
            source: "flowchart LR\n  A[Start] --> B{Ok?}\n  this is not mermaid ]]]", theme: theme)
        XCTAssertEqual(again.diagnostics, partial.diagnostics)
    }

    // MARK: - Helpers

    private func cgImage(_ image: PlatformImage) -> CGImage? {
        #if os(macOS)
        var rect = CGRect(origin: .zero, size: image.size)
        return image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        #else
        return image.cgImage
        #endif
    }

    /// Draws `image` into an RGBA buffer at `scale` over white.
    private func bitmap(_ image: PlatformImage, scale: CGFloat) -> [UInt8]? {
        let width = Int((image.size.width * scale).rounded(.up))
        let height = Int((image.size.height * scale).rounded(.up))
        var data = [UInt8](repeating: 0, count: width * height * 4)
        let ok = data.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(
                data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            #if os(macOS)
            let graphics = NSGraphicsContext(cgContext: context, flipped: false)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = graphics
            context.scaleBy(x: scale, y: scale)
            image.draw(in: CGRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            #else
            guard let cg = image.cgImage else { return false }
            context.draw(cg, in: CGRect(x: 0, y: 0, width: width, height: height))
            #endif
            return true
        }
        return ok ? data : nil
    }
}
#endif
