// FlexibleBatchM2Tests — batch M2 (task 2026-09-29-flexible-screens, round 5): the two places on the
// SETTINGS page that still broke his round-5 rule "this and the graded dent colours should be in both
// views" / "dent colours back to the FEA rainbow. And this is in BOTH views" (batch M verification's
// V12 and V10, routed until batch S merged).
//   V12: the Settings page's dent legends (the open one and its folded bar) were 24 flat blocks; the
//        main page's card is a smooth gradient. Now both read the main page's ONE ramp
//        (FlexibleMainLegendRow.ramp). RED: the 24 blocks, measured by the same instrument.
//   V10: the Settings page's stamp dent (see testTheTwoPagesAgreeOnAFourFingertipStamp).
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

    // MARK: - V10: the Settings page's stamp dent spreads as the main page's 3D sim does

    /// The pad (100 × 100 × 20, C1's) with the four-fingertip stamp on its top (`kg`, `deepest`), its
    /// bottom resting — through Save & Exit, the main page's sim landed (the main page's map IS the sim).
    func fingertipPad(kg: Double, deepest: Double) async throws -> (FlexibleMainStage, FlexibleStageModel, Int) {
        let pm = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let stage = FlexibleMainStage()
        stage.reduceMotion = { true }
        let m = stage.model(for: pm, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(90, "the pad") { m.sceneState == .ready }
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleHisProject.topFace(mesh)
        _ = m.press(top, kg: kg)
        m.rest(FlexibleSquishFixture.bottomFace(mesh))
        try await FlexibleHisProject.waitFor(60, "the top's stack") { m.stack(top) != nil }
        m.setShape(top, "stamp")
        let fingers = try XCTUnwrap(m.library?.stamps.first { $0.id == "four_fingers" })
        m.setStamp(top, source: .library(fingers.id), shape: fingers)
        m.edit { s in if var f = s.face(top) { f.deepestMM = deepest; s.setFace(f) } }
        try await FlexibleHisProject.waitFor(60, "the stamp's grid") { m.stampDent(top) != nil }
        try await FlexibleSquishFixture.settle(m, "the fingertip pad")
        stage.didExitSettings()
        stage.apply(pm, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(400, "the fingertip pad's sim") {
            stage.refresh()
            return m.lattice != nil && !m.squish.isEmpty && !m.squish.values.contains(.pending)
        }
        await m.squishSolver.waitForIdle()
        stage.refresh()
        return (stage, m, top)
    }

    /// Along one line of columns: the RMS and the largest difference of two colour fractions.
    static func agreement(_ a: [Double], _ b: [Double], _ line: [Int]) -> (rms: Double, max: Double) {
        let d = line.compactMap { c -> Double? in a[c].isFinite && b[c].isFinite ? a[c] - b[c] : nil }
        guard !d.isEmpty else { return (.nan, .nan) }
        return ((d.map { $0 * $0 }.reduce(0, +) / Double(d.count)).squareRoot(), d.map(abs).max()!)
    }

    /// The drawn dent's SAW-TOOTH on face `key`: per column quad, how far its two triangles' crease
    /// lifts off the other diagonal — |(c0 + c2) − (c1 + c3)| / 2 of its corners' dents (mm along the
    /// load, × the page's exaggeration: what is DRAWN), over the column pitch. 0 for a plane; a steep
    /// curved wall drawn by two flat triangles per column zig-zags at the pitch.
    static func tooth(_ dents: [Float], overlay o: FlexibleOverlayMesh, key: FlexFaceKey, stack st: FlexStackInfo, exaggeration: Double) -> Double {
        guard let start = o.flatStart[key] else { return .nan }
        let l = SIMD3<Float>(st.load)
        func along(_ v: Int) -> Double { Double(simd_dot(SIMD3(dents[3 * v], dents[3 * v + 1], dents[3 * v + 2]), l)) }
        var worst = 0.0
        for c in st.columns.indices {
            let q = start + 6 * c
            guard 3 * (q + 5) + 2 < dents.count else { break }
            // the quad's flat order [0, 2, 1, 0, 3, 2] (FlexibleOverlayMesh.quadOrder): corners 0 → v0, 1 → v2, 2 → v1, 3 → v4
            let c0 = along(q), c1 = along(q + 2), c2 = along(q + 1), c3 = along(q + 4)
            worst = max(worst, abs((c0 + c2) - (c1 + c3)) / 2 * exaggeration / st.pitchMM)
        }
        return worst
    }

    /// The FOCI along a line: the line's rise and dip round its own 9-column moving mean, inside the
    /// stamp's extent (`foot` > 0.02) — its correlation with the reference's and its size over it.
    static func foci(_ x: [Double], _ ref: [Double], line: [Int], foot: [Double]) -> (corr: Double, size: Double) {
        let inside = line.filter { foot[$0] > 0.02 }
        guard let lo = line.firstIndex(of: inside.first ?? -1), let hi = line.lastIndex(of: inside.last ?? -1), hi - lo > 10 else { return (.nan, .nan) }
        func detrend(_ v: [Double]) -> [Double] {
            let seg = (lo...hi).map { v[line[$0]] }
            return seg.indices.map { i in
                let w = (-4...4).map { seg[min(seg.count - 1, max(0, i + $0))] }
                return seg[i] - w.reduce(0, +) / 9
            }
        }
        let a = detrend(x), b = detrend(ref)
        guard a.allSatisfy(\.isFinite), b.allSatisfy(\.isFinite) else { return (.nan, .nan) }
        func mean(_ v: [Double]) -> Double { v.reduce(0, +) / Double(v.count) }
        let ma = mean(a), mb = mean(b)
        let sab = zip(a, b).map { ($0 - ma) * ($1 - mb) }.reduce(0, +)
        let saa = a.map { ($0 - ma) * ($0 - ma) }.reduce(0, +), sbb = b.map { ($0 - mb) * ($0 - mb) }.reduce(0, +)
        guard saa > 0, sbb > 0 else { return (.nan, .nan) }
        return (sab / (saa * sbb).squareRoot(), (saa / sbb).squareRoot())
    }

    /// His round-5 V10 (batch M verification): "the Settings page's stamp dent is a steep trench with
    /// saw-tooth edges and disagrees with the main page". Same face, same stamp: the Settings page's
    /// column dent and the main page's map (the 3D sim's own squish), each as the colour it is drawn in
    /// (over its own legend's top), along the row through the four fingertips and the line across them.
    /// RED CONTROL: batch M's spread (the footprint, a full sink under all of it, e^(−r / 0.2·depth)).
    func testTheTwoPagesAgreeOnAFourFingertipStamp() async throws {
        defer { FlexibleStampSpread.controlBatchMSpread = false }
        for (kg, deepest, rmsCap, maxCap) in [(3.0, 6.0, 0.07, 0.13), (10.0, 3.0, 0.09, 0.20)] {
            let (stage, m, top) = try await fingertipPad(kg: kg, deepest: deepest)
            let tag = String(format: "%.0f kg, %.0f mm", kg, deepest)
            XCTAssertTrue(stage.fe.active, "\(tag): premise: the main page's map is the 3D sim")
            let key = try XCTUnwrap(m.key(top)), st = try XCTUnwrap(m.stacks[key])
            let mainO = try XCTUnwrap(stage.overlay), mainStart = try XCTUnwrap(mainO.flatStart[key])
            let heat = try XCTUnwrap(stage.heatValues)
            XCTAssertGreaterThan(stage.dentMaxMM, 0)
            // ★ THE DENT'S SHAPE on each page: its value per column over the face's own deepest — the colour
            // it is drawn in whenever the page's legend tops at that face (the main page's card does here;
            // the Settings legend tops at core's buildable range when that is deeper — an older rule,
            // printed beside, not what V10 is about)
            func shape(_ x: [Double]) -> [Double] {
                let top = x.filter(\.isFinite).max() ?? 0
                return x.map { $0.isFinite && top > 0 ? $0 / top : .nan }
            }
            // the main page's map per column: the mean of its quad's six vertex values (the sim's mm)
            let mainMM: [Double] = st.columns.indices.map { c in
                let v = (0..<6).map { Double(heat[mainStart + 6 * c + $0]) }
                return v.allSatisfy(\.isFinite) ? v.reduce(0, +) / 6 : .nan
            }
            let main = shape(mainMM)
            // the Settings page's per column (its own rule: FlexibleShownValues, no lattice drawn), mm
            func settings() -> (frac: [Double], mm: [Double], shown: FlexibleShownValues) {
                let shown = FlexibleShownValues(model: m)
                let v = shown.values[key] ?? []
                let mm: [Double] = st.columns.indices.map { c in
                    if c < v.count, case .depth(let d) = v[c] { return d }
                    return .nan
                }
                return (shape(mm), mm, shown)
            }
            // the lines: the row through the stamp (most of its footprint) and the column across it
            let foot = try XCTUnwrap(m.stampFootprint(top))
            var rowSum: [Int: Double] = [:], colSum: [Int: Double] = [:]
            for (c, col) in st.columns.enumerated() { rowSum[col.iv, default: 0] += foot[c]; colSum[col.iu, default: 0] += foot[c] }
            let iv = try XCTUnwrap(rowSum.max { $0.value < $1.value }?.key), iu = try XCTUnwrap(colSum.max { $0.value < $1.value }?.key)
            let row = st.columns.indices.filter { st.columns[$0].iv == iv }.sorted { st.columns[$0].iu < st.columns[$1].iu }
            let across = st.columns.indices.filter { st.columns[$0].iu == iu }.sorted { st.columns[$0].iv < st.columns[$1].iv }
            // the Settings page's drawn dent and its saw-tooth (its own channels, as the page hands them over)
            let so = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
            func drawnTooth() throws -> Double {
                let ch = FlexiblePageChannels.channels(model: m, overlay: so, xray: true, drawnLattice: nil)
                return Self.tooth(try XCTUnwrap(ch.dents), overlay: so, key: key, stack: st, exaggeration: ch.exaggeration)
            }
            let now = settings()
            let toothNow = try drawnTooth()
            let rNow = Self.agreement(now.frac, main, row), aNow = Self.agreement(now.frac, main, across)
            FlexibleStampSpread.controlBatchMSpread = true
            let old = settings()
            let toothOld = try drawnTooth()
            FlexibleStampSpread.controlBatchMSpread = false
            let rOld = Self.agreement(old.frac, main, row), aOld = Self.agreement(old.frac, main, across)
            let fNow = Self.foci(now.frac, main, line: row, foot: foot), fOld = Self.foci(old.frac, main, line: row, foot: foot)
            func line(_ x: [Double], _ ids: [Int]) -> String { stride(from: 0, to: ids.count, by: 3).map { String(format: "%.2f", x[ids[$0]]) }.joined(separator: " ") }
            print("FLEX-M2 AGREE \(tag): row iv \(iv) (\(row.count) columns) · across iu \(iu) (\(across.count))")
            print("FLEX-M2 AGREE \(tag) row    main:     \(line(main, row))")
            print("FLEX-M2 AGREE \(tag) row    settings: \(line(now.frac, row))")
            print("FLEX-M2 AGREE \(tag) row    batch M:  \(line(old.frac, row))")
            print("FLEX-M2 AGREE \(tag) across main:     \(line(main, across))")
            print("FLEX-M2 AGREE \(tag) across settings: \(line(now.frac, across))")
            print("FLEX-M2 AGREE \(tag) across batch M:  \(line(old.frac, across))")
            print(String(format: "FLEX-M2 AGREE %@: settings vs main — row rms %.3f max %.3f · across rms %.3f max %.3f | batch M's spread — row rms %.3f max %.3f · across rms %.3f max %.3f",
                         tag, rNow.rms, rNow.max, aNow.rms, aNow.max, rOld.rms, rOld.max, aOld.rms, aOld.max))
            print(String(format: "FLEX-M2 FOCI %@: along the fingertips the Settings dent rises and dips with the main page's — correlation %.2f, %.2f × its size | batch M's spread %.2f, %.2f ×",
                         tag, fNow.corr, fNow.size, fOld.corr, fOld.size))
            print(String(format: "FLEX-M2 TOOTH %@: the drawn dent's largest crease over the pitch %.3f (×%.0f) · batch M's spread %.3f (×%.0f) · the face's deepest %.2f mm (the Settings legend tops at %.2f) · the main page's face top %.2f mm (its card %.2f)",
                         tag, toothNow, now.shown.exaggeration, toothOld, old.shown.exaggeration, now.mm.filter(\.isFinite).max() ?? 0,
                         now.shown.maxDepth, mainMM.filter(\.isFinite).max() ?? 0, stage.dentMaxMM))
            XCTAssertGreaterThan(row.count, 40); XCTAssertGreaterThan(across.count, 40)
            XCTAssertLessThanOrEqual(rNow.rms, rmsCap, "\(tag): along the fingertips the two pages show the same colours")
            XCTAssertLessThanOrEqual(rNow.max, maxCap, "\(tag): …nowhere more than \(maxCap) of the ramp apart")
            XCTAssertLessThanOrEqual(aNow.rms, rmsCap, "\(tag): across the stamp too")
            XCTAssertLessThanOrEqual(aNow.max, maxCap, "\(tag): …across the stamp, nowhere more than \(maxCap) apart")
            XCTAssertEqual(now.mm.filter(\.isFinite).max() ?? 0, deepest, accuracy: 1e-9, "\(tag): the deepest is still his deepest squish")
            XCTAssertLessThan(toothNow, 0.08, "\(tag): no saw-tooth — a crease under 8 % of the pitch")
            // his "it should have foci but expand out … combining the foci into a single input": one press,
            // each fingertip still a focus — rising and dipping where the sim's does, about as much
            XCTAssertGreaterThan(fNow.corr, 0.9, "\(tag): the fingertips' foci are where the main page's are")
            XCTAssertTrue(fNow.size > 0.5 && fNow.size < 1.5, "\(tag): …and about as strong (\(fNow.size) × the main page's)")
            // ★ RED CONTROL: batch M's spread disagrees with the main page and zig-zags
            XCTAssertTrue(rOld.rms > rmsCap || rOld.max > maxCap || aOld.rms > rmsCap || aOld.max > maxCap,
                          "control: batch M's spread is not what the main page shows")
            XCTAssertGreaterThan(toothOld, 0.08, "control: batch M's steep wall zig-zags at the pitch")
            XCTAssertFalse(fOld.size > 0.5 && fOld.size < 1.5, "control: batch M's fingertips are pits, not the sim's foci (\(fOld.size) ×)")
        }
    }
}
#endif
