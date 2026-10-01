// FlexibleBatchM2Tests — batch M2 (task 2026-09-29-flexible-screens, round 5): the two places on the
// SETTINGS page that still broke his round-5 rule "this and the graded dent colours should be in both
// views" / "dent colours back to the FEA rainbow. And this is in BOTH views" (batch M verification's
// V12 and V10, routed until batch S merged).
//   V12: the Settings page's dent legends (the open one and its folded bar) were 24 flat blocks; the
//        main page's card is a smooth gradient. Now both read the main page's ONE ramp
//        (FlexibleMainLegendRow.ramp). RED: the 24 blocks, measured by the same instrument.
//   V10: the Settings page's stamp dent (the next commit).
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import SwiftUI
import AppKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleBatchM2Tests: XCTestCase {

    // MARK: - the instrument: a rendered legend's ramp, pixel by pixel

    /// `view` rendered by SwiftUI (ImageRenderer, `scale`) into sRGB RGBA8 bytes.
    static func pixels<V: View>(_ view: V, scale: CGFloat = 2) throws -> (px: [UInt8], w: Int, h: Int) {
        let r = ImageRenderer(content: view.background(DS.Surface.panel.color))
        r.scale = scale
        let img = try XCTUnwrap(r.cgImage, "the view renders")
        let w = img.width, h = img.height
        var px = [UInt8](repeating: 0, count: w * h * 4)
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        try px.withUnsafeMutableBytes { buf in
            let ctx = try XCTUnwrap(CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        }
        return (px, w, h)
    }

    /// Evidence only: the rendered pixels as a PNG.
    static func writePNG(_ img: (px: [UInt8], w: Int, h: Int), to url: URL) throws {
        var px = img.px
        let cs = try XCTUnwrap(CGColorSpace(name: CGColorSpace.sRGB))
        let cg = try px.withUnsafeMutableBytes { buf -> CGImage in
            let ctx = try XCTUnwrap(CGContext(data: buf.baseAddress, width: img.w, height: img.h, bitsPerComponent: 8, bytesPerRow: img.w * 4,
                                              space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
        let rep = NSBitmapImageRep(cgImage: cg)
        try XCTUnwrap(rep.representation(using: .png, properties: [:])).write(to: url)
        print("FLEX-EVIDENCE wrote \(url.path)")
    }

    struct Ramp {
        /// The ramp's pixels, from its low end (0 mm) to its high end (the deepest).
        let colours: [SIMD3<Double>]
        /// Σ |Δ RGB| between neighbouring pixels, its largest single step, and the longest run of
        /// IDENTICAL neighbours (a flat block).
        var path: Double { zip(colours, colours.dropFirst()).map { simd_reduce_add(simd_abs($1 - $0)) }.reduce(0, +) }
        var maxStep: Double { zip(colours, colours.dropFirst()).map { simd_reduce_add(simd_abs($1 - $0)) }.max() ?? 0 }
        var meanStep: Double { colours.count > 1 ? path / Double(colours.count - 1) : 0 }
        var longestFlat: Int {
            var best = 0, run = 0
            for (a, b) in zip(colours, colours.dropFirst()) {
                if simd_reduce_add(simd_abs(b - a)) < 0.5 { run += 1; best = max(best, run) } else { run = 0 }
            }
            return best + 1
        }
        /// The share of neighbouring pixels that are IDENTICAL (a flat block repeats its colour).
        var flatShare: Double {
            let pairs = zip(colours, colours.dropFirst()).map { simd_reduce_add(simd_abs($1 - $0)) < 0.5 }
            return pairs.isEmpty ? 1 : Double(pairs.filter { $0 }.count) / Double(pairs.count)
        }
        /// A smooth ramp: hardly a pixel repeats its neighbour (24 flat blocks: most do), no flat run
        /// longer than 3 px, no step more than 6 × the mean (the rainbow runs faster through some stops).
        var smooth: Bool { flatShare <= 0.2 && longestFlat <= 3 && maxStep <= 6 * meanStep }
        /// Where a colour sits on the dent's ramp (0…1): the nearest of 1001 samples.
        static func fraction(_ c: SIMD3<Double>) -> Double {
            var best = (d: Double.infinity, f: 0.0)
            for i in 0...1000 {
                let f = Double(i) / 1000, r = FlexibleColours.depthColour(fraction: f)
                let d = simd_reduce_add(simd_abs(SIMD3(r.r, r.g, r.b) * 255 - c))
                if d < best.d { best = (d, f) }
            }
            return best.f
        }
    }

    /// The ramp in a rendered legend: the longest run of SATURATED pixels along one row (`vertical`:
    /// one column, read bottom → top so the deepest end is last), 2 px trimmed at each end.
    static func ramp(_ img: (px: [UInt8], w: Int, h: Int), vertical: Bool) -> Ramp? {
        func rgb(_ x: Int, _ y: Int) -> SIMD3<Double> {
            let i = 4 * (y * img.w + x)
            return SIMD3(Double(img.px[i]), Double(img.px[i + 1]), Double(img.px[i + 2]))
        }
        func saturated(_ c: SIMD3<Double>) -> Bool { c.max() - c.min() >= 50 }
        var best: [SIMD3<Double>] = []
        let lines = vertical ? img.w : img.h, along = vertical ? img.h : img.w
        for l in 0..<lines {
            var run: [SIMD3<Double>] = []
            for a in 0..<along {
                let c = vertical ? rgb(l, img.h - 1 - a) : rgb(a, l)
                if saturated(c) { run.append(c) } else {
                    if run.count > best.count { best = run }
                    run = []
                }
            }
            if run.count > best.count { best = run }
        }
        guard best.count > 20 else { return nil }
        return Ramp(colours: Array(best.dropFirst(3).dropLast(3)))
    }

    /// Batch S's legend bars as they were (the RED control): 24 flat blocks.
    struct OldBlocks: View {
        let vertical: Bool
        var body: some View {
            if vertical {
                VStack(spacing: 0) {
                    ForEach((0..<24).reversed(), id: \.self) { i in
                        FlexibleColours.depthColour(fraction: Double(i) / 23).color.frame(width: 18)
                    }
                }
                .frame(height: FlexibleLegendBar.barHeight)
            } else {
                HStack(spacing: 0) {
                    ForEach(0..<24, id: \.self) { i in
                        FlexibleColours.depthColour(fraction: Double(i) / 23).color.frame(width: 9, height: 10)
                    }
                }
            }
        }
    }

    // MARK: - V12

    func testTheSettingsPagesDentLegendsAreTheMainPagesSmoothRamp() async throws {
        var s = FlexibleStageSettings(materialID: "varioshore_tpu")
        let probe = try FlexibleHisProject.padProject(s)
        let top = FlexibleHisProject.topFace(try XCTUnwrap(probe.viewerMesh))
        s.setFace(FlexibleFaceSettings(faceRegionID: top, weightKg: 10, deepestMM: 3))
        let m = try await FlexibleHisProject.openedModel(try FlexibleHisProject.padProject(s), test: self)
        m.selectedRegion = top
        // the main page's ramp, alone, at each Settings legend's own size (what the two must show)
        let mainOpen = try XCTUnwrap(Self.ramp(try Self.pixels(FlexibleMainLegendRow.ramp(.dent).frame(width: 216, height: 10).padding(8)), vertical: false))
        let mainBar = try XCTUnwrap(Self.ramp(try Self.pixels(FlexibleMainLegendRow.ramp(.dent, vertical: true)
            .frame(width: 18, height: FlexibleLegendBar.barHeight).padding(8)), vertical: true))
        for (name, view, vertical, main) in [
            ("the open legend (FlexibleLegend)", AnyView(FlexibleLegend(model: m)), false, mainOpen),
            ("the folded bar (FlexibleLegendBar)", AnyView(FlexibleLegendBar(fraction: nil)), true, mainBar),
        ] {
            let img = try Self.pixels(view)
            let r = try XCTUnwrap(Self.ramp(img, vertical: vertical), "\(name): its ramp is found")
            let oldImg = try Self.pixels(OldBlocks(vertical: vertical).padding(8))
            let old = try XCTUnwrap(Self.ramp(oldImg, vertical: vertical))
            if let dir = ProcessInfo.processInfo.environment["FLEX_M2_EVIDENCE_DIR"] {
                try Self.writePNG(img, to: URL(fileURLWithPath: dir).appendingPathComponent("M2_legend_\(vertical ? "folded" : "open")_now.png"))
                try Self.writePNG(oldImg, to: URL(fileURLWithPath: dir).appendingPathComponent("M2_legend_\(vertical ? "folded" : "open")_batchS_blocks.png"))
            }
            // colour for colour, by place along the ramp (the folded bar's 1 pt border trims it a little)
            let n = r.colours.count, mn = main.colours.count
            let vsMain = (0..<n).map { i -> Double in
                let j = Int((Double(i) * Double(mn - 1) / Double(max(1, n - 1))).rounded())
                return simd_reduce_add(simd_abs(r.colours[i] - main.colours[j])) / 3
            }.reduce(0, +) / Double(max(1, n))
            let ends = (Ramp.fraction(r.colours.first!), Ramp.fraction(r.colours.last!))
            print(String(format: "FLEX-M2 LEGEND %@: %d px · identical neighbours %.0f%% · longest flat run %d px · largest step %.1f (%.1f × the mean %.2f) · vs the main page's ramp %.1f / 255 · ends at %.2f … %.2f of the ramp | 24 blocks (batch S): identical %.0f%%, flat %d px, step %.1f (%.1f × mean)",
                         name, r.colours.count, 100 * r.flatShare, r.longestFlat, r.maxStep, r.maxStep / max(1e-9, r.meanStep), r.meanStep, vsMain,
                         ends.0, ends.1, 100 * old.flatShare, old.longestFlat, old.maxStep, old.maxStep / max(1e-9, old.meanStep)))
            print(String(format: "FLEX-M2 LEGEND %@ — the main page's ramp alone: %d px · identical neighbours %.0f%% · longest flat run %d px · largest step %.1f (%.1f × the mean %.2f)",
                         name, main.colours.count, 100 * main.flatShare, main.longestFlat, main.maxStep, main.maxStep / max(1e-9, main.meanStep), main.meanStep))
            XCTAssertTrue(r.smooth, "\(name): a smooth gradient, like the main page's card")
            XCTAssertEqual(Double(r.colours.count), Double(main.colours.count), accuracy: 8, "\(name): as long as before (216 × 10 / 18 × 64 pt)")
            XCTAssertLessThan(vsMain, 6, "\(name): the main page's own ramp, colour for colour")
            XCTAssertLessThan(ends.0, 0.08, "\(name): 0 mm is the rainbow's blue end")
            XCTAssertGreaterThan(ends.1, 0.92, "\(name): the deepest is its red end")
            XCTAssertTrue(main.smooth, "premise: the main page's ramp is smooth")
            // ★ RED CONTROL: batch S's 24 flat blocks, by the same instrument
            XCTAssertFalse(old.smooth, "control: 24 flat blocks are not a smooth ramp")
        }
    }

}
#endif
