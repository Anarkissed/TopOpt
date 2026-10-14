// FlexibleR7X1HostedTests — round 7 batch X1's PRINTED VIEW, by the shipping renderer (MeshRenderer's offscreen render of
// exactly what the main Flexible page hands MetalMeshView), on HIS pad with his live lattice (Group C's two 25 mm
// face-prisms — the two strips of his img5), at img5's TOP camera, Heat off. Written BEFORE the code (the red run:
// round7/batch_x1/r7x1_red_run.txt); each test runs its RED control inside. His words (2026-10-14): "The lattice should be
// visible without x-ray on as long as finish is set to something that isn't 'covered' … If lattice is on without x-ray
// view, we see the lattice plus the solid. If the user adds x-ray, we see through the solid."
//   XH1  Finish None, the default view (the lattice on, X-ray off): OUTSIDE the strips' screen footprint ≥ 95 % of the
//        model's pixels match the plain opaque model within ΔE 3 (the solid part, correctly sorted — at the page's 900 pt
//        and at his 13" pixel size, and at his img1 camera); INSIDE ≥ 60 % differ (the walls and the voids, not the skin). X-ray on: the frame is
//        R7-V's X-ray frame, byte for byte. RED controls: R7-V's rule (the walls only in X-ray: ~0 % differ inside), and the
//        plan's solid-flag route alone (no closed body in the G-buffer: the far face painted over the Top, < 95 % outside).
//   XH2  Covered: ≤ 5 % differ inside (the plain model). Skin: the perforated sheet — fewer differ than under None, more
//        than under Covered. Rim: bands at the edges — between the two as well.
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

/// img5's TOP camera (R7-V's evidence probe's).
let r7x1Img5 = FlexibleRound6Tests.Cam(name: "img5 (top)", azimuth: .pi / 9, elevation: 1.42, zoom: 1)
/// img1's camera (his main-page screenshot's; the M1 probe's).
let r7x1Img1 = FlexibleRound6Tests.Cam(name: "img1", azimuth: .pi / 4, elevation: 0.62, zoom: 1)

@MainActor
final class FlexibleR7X1HostedTests: XCTestCase {
    typealias Cam = FlexibleRound6Tests.Cam
    static let img5 = r7x1Img5

    struct Frame { let px: [UInt8]; let n: Int }

    /// One frame of what the page hands MetalMeshView now (BGRA, n × n). `tints` overrides the page's.
    func frame(_ s: FlexibleMainStage, _ p: ProjectModel, cam: Cam = r7x1Img5, n: Int = 900, tints: [Float]? = nil,
               alpha: Float? = nil, layer: FlexibleLatticeLayerInputs?? = nil, device: MTLDevice) throws -> Frame {
        s.refresh()
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let mesh = try XCTUnwrap(s.mesh(p, on: .lattice))
        let mr = try FlexibleRound6EvidenceProbe().renderer(
            mesh: mesh, tints: tints ?? s.tints(p, on: .lattice, roles: [:], stress: nil), dents: s.dents(p, on: .lattice),
            scale: s.dentScale(p, on: .lattice), bodyAlpha: alpha ?? (s.bodyAlpha(p, on: .lattice) ?? 1), settle: settle, cam: cam,
            device: device, items: [], layer: layer ?? s.layer(p, stage: .lattice, pageUp: false))
        let bg = DS.Color.background
        return Frame(px: try XCTUnwrap(mr.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))), n: n)
    }

    /// The strips' screen footprint: the plain opaque model with the surface over the lattice region painted pure red.
    func footprint(_ s: FlexibleMainStage, _ p: ProjectModel, _ m: FlexibleStageModel, cam: Cam = r7x1Img5, n: Int = 900,
                   device: MTLDevice) throws -> (strips: [Bool], model: [Bool]) {
        let mesh = try XCTUnwrap(s.mesh(p, on: .lattice))
        let g = try XCTUnwrap(m.lattice)
        let open = FlexibleMainTints.overLattice(mesh: mesh, lattice: g.inputs)
        var t = [Float](repeating: 0, count: mesh.flat.vertexCount * 8)
        for v in open.indices where open[v] { t[v * 8] = 1; t[v * 8 + 3] = 1 }
        let f = try frame(s, p, cam: cam, n: n, tints: t, alpha: 1, layer: .some(nil), device: device)
        let bg = DS.Color.background
        let (br, bgc, bb) = (Int((bg.b * 255).rounded()), Int((bg.g * 255).rounded()), Int((bg.r * 255).rounded()))   // BGRA
        var strips = [Bool](repeating: false, count: n * n), model = [Bool](repeating: false, count: n * n)
        for i in 0..<(n * n) {
            let b = Int(f.px[4 * i]), gg = Int(f.px[4 * i + 1]), r = Int(f.px[4 * i + 2])
            model[i] = abs(b - br) + abs(gg - bgc) + abs(r - bb) > 9
            strips[i] = model[i] && r > 90 && r > gg * 2 && r > b * 2
        }
        return (strips, model)
    }

    /// Opt-in (FLEX_R7X1_DUMP=<dir>): a frame written as a PNG, to look at what a measurement counted.
    static func dump(_ f: Frame, _ name: String, mark: [Bool]? = nil) {
        guard let d = ProcessInfo.processInfo.environment["FLEX_R7X1_DUMP"] else { return }
        var rgba = f.px
        for i in stride(from: 0, to: rgba.count, by: 4) {
            rgba.swapAt(i, i + 2); rgba[i + 3] = 255
            if let m = mark, m[i / 4] { rgba[i] = 255; rgba[i + 1] = 0; rgba[i + 2] = 255 }
        }
        guard let ctx = CGContext(data: &rgba, width: f.n, height: f.n, bitsPerComponent: 8, bytesPerRow: f.n * 4,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue),
              let img = ctx.makeImage() else { return }
        try? FileManager.default.createDirectory(atPath: d, withIntermediateDirectories: true)
        let url = URL(fileURLWithPath: d).appendingPathComponent(name)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }
    /// The pixels within `r` (a square) of a selected one.
    static func near(_ sel: [Bool], n: Int, r: Int) -> [Bool] {
        var rows = [Bool](repeating: false, count: sel.count), out = rows
        for y in 0..<n { var last = -1_000_000
            for x in 0..<n { if sel[y * n + x] { last = x }; if x - last <= r { rows[y * n + x] = true } }
            last = 1_000_000
            for x in stride(from: n - 1, through: 0, by: -1) { if sel[y * n + x] { last = x }; if last - x <= r { rows[y * n + x] = true } } }
        for x in 0..<n { var last = -1_000_000
            for y in 0..<n { if rows[y * n + x] { last = y }; if y - last <= r { out[y * n + x] = true } }
            last = 1_000_000
            for y in stride(from: n - 1, through: 0, by: -1) { if rows[y * n + x] { last = y }; if last - y <= r { out[y * n + x] = true } } }
        return out
    }
    /// `sel` kept only where every pixel within `r` (a square) is selected too.
    static func eroded(_ sel: [Bool], n: Int, r: Int) -> [Bool] {
        var out = [Bool](repeating: false, count: sel.count)
        for y in r..<(n - r) { for x in r..<(n - r) where sel[y * n + x] {
            var all = true
            outer: for dy in -r...r { for dx in -r...r where !sel[(y + dy) * n + x + dx] { all = false; break outer } }
            out[y * n + x] = all
        } }
        return out
    }
    static func grossMask(_ a: Frame, _ ref: Frame, where sel: [Bool]) -> [Bool] {
        sel.indices.map { sel[$0] && deltaE(a.px, ref.px, $0) > 15 }
    }

    /// CIE76 ΔE between two BGRA pixels (sRGB → Lab, D65).
    static func deltaE(_ a: [UInt8], _ b: [UInt8], _ i: Int) -> Float {
        func lab(_ px: [UInt8]) -> SIMD3<Float> {
            func lin(_ c: UInt8) -> Float { let v = Float(c) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
            let r = lin(px[4 * i + 2]), g = lin(px[4 * i + 1]), bl = lin(px[4 * i])
            let x = (0.4124 * r + 0.3576 * g + 0.1805 * bl) / 0.95047, y = 0.2126 * r + 0.7152 * g + 0.0722 * bl
            let z = (0.0193 * r + 0.1192 * g + 0.9505 * bl) / 1.08883
            func f(_ t: Float) -> Float { t > 0.008856 ? pow(t, 1.0 / 3) : 7.787 * t + 16.0 / 116 }
            return SIMD3(116 * f(y) - 16, 500 * (f(x) - f(y)), 200 * (f(y) - f(z)))
        }
        return simd_length(lab(a) - lab(b))
    }

    /// Of the pixels `where`, the share whose ΔE to the reference is above `above` (3: the plan's bar).
    static func differing(_ a: Frame, _ ref: Frame, where sel: [Bool], above: Float = 3) -> (share: Double, count: Int) {
        var n = 0, d = 0
        for i in sel.indices where sel[i] { n += 1; if deltaE(a.px, ref.px, i) > above { d += 1 } }
        return (n > 0 ? Double(d) / Double(n) : 0, n)
    }
    /// A body drawn in the wrong order shows another SURFACE (another face's shading) — a gross difference, not a shading
    /// nuance: the share of pixels `where` above ΔE 15.
    static func grossly(_ a: Frame, _ ref: Frame, where sel: [Bool]) -> Double { differing(a, ref, where: sel, above: 15).share }

    func hisStrips() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let (r, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: true)
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        try await waitFresh(m)
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        s.heat = false
        s.refresh()
        return (r, s, m)
    }

    func waitFresh(_ m: FlexibleStageModel) async throws {
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) }
    }

    // MARK: - XH1: None — the solid part plus the lattice, correctly sorted; X-ray unchanged

    func testFinishNoneShowsTheSolidPartAndTheLatticeWithXrayOff() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (r, s, m) = try await hisStrips()
        let p = r.project
        XCTAssertEqual(m.settings.finishMode, .none, "premise: Finish None")
        XCTAssertFalse(s.xrayOn, "premise: the default view (X-ray off)")
        var lines: [String] = []
        // img5's top camera at the page's 900 pt and at his 13" portrait's pixels (the G-buffer's 1152 cap below it), and his
        // img1 camera (the side faces in view — where a mis-sorted body shows: the far face over the Top)
        for (cam, n) in [(Self.img5, 900), (Self.img5, 2064), (r7x1Img1, 900)] {
            let fp = try footprint(s, p, m, cam: cam, n: n, device: device)
            // (the solid part's own pixels: away from the silhouette and the strips' edge by a few pixels — an edge pixel is
            // half background or half lattice in one frame and not the other)
            let outside = Self.eroded(zip(fp.model, fp.strips).map { $0 && !$1 }, n: n, r: max(2, n / 450))
            XCTAssertGreaterThan(fp.strips.filter { $0 }.count, n * n / 50, "premise: the strips are on screen")
            let printed = try frame(s, p, cam: cam, n: n, device: device)
            s.latticeOn = false
            let plain = try frame(s, p, cam: cam, n: n, device: device)
            s.latticeOn = true
            let out = Self.differing(printed, plain, where: outside), ins = Self.differing(printed, plain, where: fp.strips)
            // the plan's AO check: the solid part NEXT to the strips (within ~24 px of them at 900) — the printed body's
            // occlusion and creases against #354's opaque body's, as a mean ΔE (reported)
            let nearStrips = Self.near(fp.strips, n: n, r: max(4, n * 24 / 900))
            let band = zip(outside, nearStrips).map { $0 && $1 }
            let bandN = band.filter { $0 }.count
            let bandMean = bandN > 0 ? band.indices.filter { band[$0] }.map { Double(Self.deltaE(printed.px, plain.px, $0)) }.reduce(0, +) / Double(bandN) : 0
            let gross = Self.grossly(printed, plain, where: outside)
            Self.dump(printed, "XH1_\(cam.name.prefix(4))_\(n)_printed.png", mark: Self.grossMask(printed, plain, where: outside))
            Self.dump(plain, "XH1_\(cam.name.prefix(4))_\(n)_plain.png", mark: fp.strips)
            lines.append("\(cam.name) n \(n): outside the strips \(String(format: "%.2f", 100 * (1 - out.share))) % match (of \(out.count) px), \(String(format: "%.2f", 100 * gross)) % grossly off (ΔE > 15) · inside \(String(format: "%.1f", 100 * ins.share)) % differ (of \(ins.count) px) · AO check: the solid part next to the strips, mean ΔE \(String(format: "%.2f", bandMean)) over \(bandN) px")
            XCTAssertGreaterThanOrEqual(1 - out.share, 0.95, "★ \(cam.name) n \(n): outside the strips the solid part (ΔE ≤ 3)")
            XCTAssertLessThan(gross, 0.01, "★ \(cam.name) n \(n): …correctly sorted (no other surface shows through: ΔE > 15 under 1 %)")
            XCTAssertGreaterThanOrEqual(ins.share, 0.60, "★ \(cam.name) n \(n): inside the strips the lattice (the walls and the voids)")
            if cam.name == r7x1Img1.name {
                // ★ RED CONTROL 2: the plan's solid-flag route alone (no closed body in the G-buffer — no depth to sort it),
                // as the spike drew it: Heat ON (the Top's heat quads)
                s.heat = true
                let printedHeat = try frame(s, p, cam: cam, n: n, device: device)
                var flagOnly = s.layer(p, stage: .lattice, pageUp: false)
                flagOnly?.printed = true
                let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
                let mr = try FlexibleRound6EvidenceProbe().renderer(
                    mesh: try XCTUnwrap(s.mesh(p, on: .lattice)), tints: s.tints(p, on: .lattice, roles: [:], stress: nil),
                    dents: s.dents(p, on: .lattice), scale: s.dentScale(p, on: .lattice), bodyAlpha: 0, settle: settle, cam: cam,
                    device: device, items: [], layer: flagOnly)
                mr.flexibleLattice?.controlNoBodyInGBuffer = true
                let bg = DS.Color.background
                let c2f = Frame(px: try XCTUnwrap(mr.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))), n: n)
                s.heat = false
                let c2 = Self.differing(c2f, printedHeat, where: outside), c2g = Self.grossly(c2f, printedHeat, where: outside)
                Self.dump(c2f, "XH1_control_solidflags_img1.png", mark: Self.grossMask(c2f, printedHeat, where: outside))
                Self.dump(printedHeat, "XH1_printed_heat_img1.png")
                lines.append("control (img1): the solid flags alone, outside \(String(format: "%.2f", 100 * (1 - c2.share))) % match, \(String(format: "%.2f", 100 * c2g)) % grossly off")
                XCTAssertGreaterThanOrEqual(c2g, 0.01, "★ RED CONTROL: the solid flags alone mis-sort the body (the far face over the Top)")
            }
            if n == 900, cam.name == Self.img5.name {
                // ★ RED CONTROL 1: R7-V's rule — the walls only in X-ray: the strips are the plain skin
                s.controlNoPrintedView = true
                let r7v = try frame(s, p, n: n, device: device)
                s.controlNoPrintedView = false
                let c1 = Self.differing(r7v, plain, where: fp.strips)
                lines.append("control (img5): R7-V's rule inside \(String(format: "%.1f", 100 * c1.share)) % differ")
                XCTAssertLessThan(c1.share, 0.60, "★ RED CONTROL: R7-V's rule shows no lattice inside the strips")
                // X-ray: R7-V's X-ray frame, byte for byte (the printed gate is off there)
                s.xrayOn = true
                let xr = try frame(s, p, n: n, device: device)
                s.controlNoPrintedView = true
                let xrR7V = try frame(s, p, n: n, device: device)
                s.controlNoPrintedView = false
                s.xrayOn = false
                XCTAssertEqual(xr.px, xrR7V.px, "★ X-ray: R7-V's frame, byte for byte")
                XCTAssertGreaterThan(Self.differing(xr, printed, where: fp.model).share, 0.3, "X-ray sees through the solid (not the printed view)")
            }
        }
        print("FLEX-R7X1-XH1 his strips, Finish None, img5 top, Heat off:\n  " + lines.joined(separator: "\n  "))
    }

    // MARK: - XH2: Covered, Skin, Rim

    func testCoveredIsThePlainModelSkinAndRimSitBetween() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (r, s, m) = try await hisStrips()
        let p = r.project
        s.xrayOn = false   // the subject: the default view, X-ray off (whatever the stage's default)
        let fp = try footprint(s, p, m, device: device)
        var share: [FlexibleFinish: Double] = [:]
        var lines: [String] = []
        for f in [FlexibleFinish.none, .skin, .rim, .covered] {
            if m.settings.finishMode != f {
                m.edit { $0.finish = f.rawValue }
                s.buildIfReady()
                try await waitFresh(m)
            }
            s.heat = false
            XCTAssertFalse(s.xrayOn, "premise: X-ray off")
            let printed = try frame(s, p, device: device)
            s.latticeOn = false
            let plain = try frame(s, p, device: device)
            s.latticeOn = true
            share[f] = Self.differing(printed, plain, where: fp.strips).share
            lines.append("\(f.rawValue): inside the strips \(String(format: "%.1f", 100 * share[f]!)) % differ · printed view \(s.printedView)")
        }
        XCTAssertLessThanOrEqual(share[.covered] ?? 1, 0.05, "★ Covered: the plain model")
        XCTAssertGreaterThanOrEqual(share[.none] ?? 0, 0.60, "★ None: the lattice")
        for f in [FlexibleFinish.skin, .rim] {
            XCTAssertLessThan(share[f] ?? 1, share[.none] ?? 0, "★ \(f.rawValue): part of the strips stays solid (the finish)")
            XCTAssertGreaterThan(share[f] ?? 0, share[.covered] ?? 1, "★ \(f.rawValue): the lattice shows where the finish leaves it open")
        }
        print("FLEX-R7X1-XH2 his strips, img5 top, Heat off:\n  " + lines.joined(separator: "\n  "))
    }
}
#endif
