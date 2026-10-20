// FlexibleU1Tests — round 7, step U1: his front-end notes of 2026-10-20 (items 1–4 and 6), on HIS pad as he left it at 13:46
// that day (round7/batch_u1/his_live_1020, copied from the simulator, never written). Each RED control is asserted red
// inside its test. Pictures (13" portrait) only with FLEX_U1_DIR=<dir>.
//   1 the Top bends with the side (Bend, the column preview)      — testTheTopBendsWithTheSide
//   2 a stamp never leaves the model                                — testAStampNeverLeavesTheModel
//   3 an edge's card is a face's table; no "long"/"cross"           — testAnEdgeCardReadsLikeAFaceAndTheCameraStaysPut (hosted)
//   4 the camera moves only when he moves it                        — same hosted test
//   6 no rods in the middle of the lattice                          — testNoRodsInTheLattice
#if canImport(AppKit) && canImport(MetalKit)
import XCTest
import SwiftUI
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

private final class U1Win: NSWindow {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { true }
}

@MainActor
final class FlexibleU1Tests: XCTestCase {
    static var liveDir: URL {
        FlexibleHisProject.repoRoot.appendingPathComponent("docs/handoffs/evidence/2026-09-29-flexible-screens/round7/batch_u1/his_live_1020", isDirectory: true)
    }
    static var dir: URL? { ProcessInfo.processInfo.environment["FLEX_U1_DIR"].map { URL(fileURLWithPath: $0, isDirectory: true) } }
    static let p13 = CGSize(width: 1032, height: 1376)
    final class Frames { var all: [String: CGRect] = [:] }
    struct Host { let window: NSWindow; let view: NSView; let size: CGSize; let frames: Frames }
    var log: [String] = []

    // MARK: his pad

    func hisPad(lattice: Bool) async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let r = try FlexibleHisProject.restore(Self.liveDir, asSaved: true)
        addTeardownBlock { r.cleanup() }
        let s = FlexibleMainStage()
        s.reduceMotion = { true }
        let m = s.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        m.keepCombinedField = true
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleSquishFixture.settle(m, "his pad of 10-20")
        if lattice {
            s.didExitSettings()
            s.apply(r.project, owned: true, pageUp: false)
            try await FlexibleHisProject.waitFor(300, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        }
        return (r, s, m)
    }

    // MARK: 6 — the rods

    /// His img_1020_10: thin violet rods standing in the lattice. Cause: core's field leaves whole voxel columns EMPTY inside
    /// the part where a voxel centre lies exactly on the pad's top/bottom diagonal (each is two triangles split along x = y);
    /// each column cut a hole straight through the lattice and the walls ended at it with their violet cut faces.
    func testNoRodsInTheLattice() async throws {
        let (r, _, m) = try await hisPad(lattice: true)
        let f = try XCTUnwrap(m.lastCombinedField, "the kept field")
        let part = try XCTUnwrap(r.project.viewerMesh)
        let b = m.build
        func inputs(_ seam: Bool) throws -> FlexibleLatticeInputs {
            try FlexibleLatticeBuilder.inputs(field: f, part: part, topology: b.topology, beadsPerWall: b.beadsPerWall,
                                              beadWidthMM: b.beadWidthMM, buildDir: m.sceneInfo?.buildDir ?? SIMD3(0, 0, 1),
                                              skinOffFaces: [], finish: m.settings.finishMode, seamFill: seam)
        }
        /// Columns holding a non-lattice voxel with lattice on both sides (x or y) — a hole through the lattice.
        func holes(_ mk: FlexGrid) -> [SIMD2<Int>: Int] {
            var out: [SIMD2<Int>: Int] = [:]
            for k in 0..<mk.nz { for j in 1..<(mk.ny - 1) { for i in 1..<(mk.nx - 1) where mk.at(i, j, k) < 0.5 {
                if (mk.at(i - 1, j, k) >= 0.5 && mk.at(i + 1, j, k) >= 0.5) || (mk.at(i, j - 1, k) >= 0.5 && mk.at(i, j + 1, k) >= 0.5) {
                    out[SIMD2(i, j), default: 0] += 1
                }
            } } }
            return out
        }
        // RED CONTROL: the mask as core gives it — the holes, on the diagonal, every layer
        let control = try inputs(false)
        let before = holes(control.mask)
        log.append("control: \(before.count) hole columns \(before.sorted { $0.key.x < $1.key.x }.map { "(\($0.key.x),\($0.key.y))×\($0.value)" })")
        XCTAssertGreaterThanOrEqual(before.count, 1, "RED CONTROL: core's field has the holes")
        XCTAssertTrue(before.keys.allSatisfy { $0.x == $0.y }, "premise: on the x = y diagonal (the top's and bottom's shared edge)")
        XCTAssertTrue(before.values.allSatisfy { $0 >= f.nz - 1 }, "premise: whole columns")
        // the fix: the page's own lattice (built through the builder) and the builder itself
        let fixed = try inputs(true)
        XCTAssertEqual(holes(fixed.mask).count, 0, "no hole left through the lattice")
        XCTAssertGreaterThan(fixed.seamFilled, 0)
        let shown = try XCTUnwrap(m.lattice).inputs
        XCTAssertEqual(holes(shown.mask).count, 0, "the lattice the page draws has no hole")
        XCTAssertEqual(shown.mask.values, fixed.mask.values, "the page's mask is the builder's")
        // nothing else moved: only voxels core had left out, each between lattice of ONE region
        var changed = 0
        for v in 0..<fixed.mask.values.count where fixed.mask.values[v] != control.mask.values[v] {
            changed += 1
            XCTAssertEqual(control.mask.values[v], 0)
            XCTAssertEqual(f.owner[v], -1, "only a voxel core left out")
        }
        // (the put-back columns' top voxels, outside the part by core's rule, then join through the R7 mask-to-surface fill)
        XCTAssertGreaterThanOrEqual(changed, fixed.seamFilled)
        XCTAssertLessThanOrEqual(changed - fixed.seamFilled, before.count, "at most one surface voxel per column on top")
        log.append("fixed: \(fixed.seamFilled) voxels put back, 0 hole columns")
        if Self.dir != nil { try latticePair(part: part, lattice: try XCTUnwrap(m.lattice), control: control) }
        flush("U1_lines_rods.txt")
    }

    // MARK: 1 — the Top bends with the side

    /// His img_1020_7: Face 3's stamp bent the side; the Top over its pocket stayed flat (the column preview: the Top's two big
    /// triangles took the ramp only at their corners — on the edge's ends and the far side, all 0 — so they never moved).
    func testTheTopBendsWithTheSide() async throws {
        let (r, _, m) = try await hisPad(lattice: false)
        let key = try XCTUnwrap(m.loadedKeys.first { $0.region == 3 }, "Face 3 pressed")
        let st = try XCTUnwrap(m.stacks[key])
        let g = try XCTUnwrap(m.squeezeGroup(of: 3), "Face 3's group")
        let topZ = try XCTUnwrap(r.project.viewerMesh).bounds.max.z
        func measure() throws -> (side: Double, top: Double, topN: Int) {
            let edge = FlexibleSettingsSquish.pageEdge(model: m)
            let o = try XCTUnwrap(edge.map { FlexiblePageChannels.overlay(model: m, maxEdgeMM: $0, maxTriangles: FlexibleSettingsSquish.columnMaxTriangles) }
                                  ?? FlexiblePageChannels.overlay(model: m))
            let d = FlexibleSettingsSquish.columnDents(model: m, overlay: o, regions: Set(g.regions))
            let pos = o.mesh.flat.positions
            let l = SIMD3<Float>(st.load)
            var side = 0.0, top = 0.0, topN = 0
            let start = try XCTUnwrap(o.flatStart[key])
            for v in 0..<(pos.count / 3) {
                let p = SIMD3<Float>(pos[v * 3], pos[v * 3 + 1], pos[v * 3 + 2])
                let mv = Double(simd_dot(SIMD3(d[v * 3], d[v * 3 + 1], d[v * 3 + 2]), l))
                let t = Double(simd_dot(p - SIMD3<Float>(st.centroid), l))
                if v >= start, v < start + st.columns.count * 6, p.z > topZ - 2 { side = max(side, mv) }   // Face 3's map, its top row
                else if abs(p.z - topZ) < 1e-3, t > 0.5, t < 12 { top = max(top, mv); topN += 1 }          // the Top over the pocket
            }
            return (side, top, topN)
        }
        FlexibleSettingsSquish.controlColumnFlatNeighbours = true
        let red = try measure()
        FlexibleSettingsSquish.controlColumnFlatNeighbours = false
        let now = try measure()
        log.append(String(format: "control: side %.2f mm · Top over the pocket %.2f mm (%d vertices)", red.side, red.top, red.topN))
        log.append(String(format: "fixed:   side %.2f mm · Top over the pocket %.2f mm (%d vertices)", now.side, now.top, now.topN))
        XCTAssertGreaterThan(red.side, 0.5, "premise: Face 3's stamp bends the side's top row")
        XCTAssertLessThan(red.top, 0.1 * red.side, "RED CONTROL: the Top stays flat")
        XCTAssertGreaterThan(now.top, 0.6 * now.side, "the Top over the pocket follows the side's bend")
        XCTAssertEqual(now.side, red.side, accuracy: 0.02 * red.side, "the side's own bend is unchanged")
        if Self.dir != nil { try bendPicture(r.project, m, group: g, face: key, stack: st) }
        flush("U1_lines_bend.txt")
    }

    // MARK: 2 — a stamp never leaves the model

    func testAStampNeverLeavesTheModel() async throws {
        let (_, _, m) = try await hisPad(lattice: false)
        let st = try XCTUnwrap(m.stack(3))
        XCTAssertNotNil(m.settings.face(3)?.designStamp, "premise: Face 3's four-fingers stamp")
        // inside the face: exactly where he drags it
        m.moveStamp(3, to: SIMD2(60, 10))
        var p = try XCTUnwrap(m.settings.face(3)?.designStamp)
        XCTAssertEqual(p.centreU, 60, accuracy: 1e-9); XCTAssertEqual(p.centreV, 10, accuracy: 1e-9)
        // far off the face: it stops while some of it still presses — partly off is fine
        m.moveStamp(3, to: SIMD2(-300, 10))
        p = try XCTUnwrap(m.settings.face(3)?.designStamp)
        log.append(String(format: "face stamp %.1f × %.1f mm on Face 3 (%.0f × %.0f mm): dragged to (-300, 10) → (%.2f, %.2f)", p.widthMM, p.lengthMM, st.uExtentMM, st.vExtentMM, p.centreU, p.centreV))
        XCTAssertTrue(FlexibleStageModel.stampPresses(SIMD2(p.centreU, p.centreV), stamp: p, stack: st), "some of it presses the face")
        XCTAssertLessThan(p.centreU, 0, "partly off the face is allowed (its centre is past the edge)")
        XCTAssertFalse(FlexibleStageModel.stampPresses(SIMD2(p.centreU - 1, p.centreV), stamp: p, stack: st), "it stopped at the last place that presses")
        m.moveStamp(3, to: SIMD2(50, 400))
        p = try XCTUnwrap(m.settings.face(3)?.designStamp)
        XCTAssertTrue(FlexibleStageModel.stampPresses(SIMD2(p.centreU, p.centreV), stamp: p, stack: st), "off the top too")
        log.append(String(format: "dragged to (50, 400) → (%.2f, %.2f)", p.centreU, p.centreV))
        // RED CONTROL: before U1 it went where the finger went — off the model, lost
        FlexibleStageModel.controlStampLeavesFace = true
        m.moveStamp(3, to: SIMD2(-300, 10))
        FlexibleStageModel.controlStampLeavesFace = false
        p = try XCTUnwrap(m.settings.face(3)?.designStamp)
        XCTAssertEqual(p.centreU, -300, accuracy: 1e-9, "RED CONTROL")
        XCTAssertFalse(FlexibleStageModel.stampPresses(SIMD2(p.centreU, p.centreV), stamp: p, stack: st), "RED CONTROL: lost")
        // an edge's stamp: its centre stays on the edge's span (R7-E4's slide), so half of it always presses
        let edge = try XCTUnwrap((m.settings.presses ?? []).first { $0.settings.designStamp != nil && $0.strip != nil }, "an edge stamp in his pad")
        let s = try XCTUnwrap(edge.strip), sp = try XCTUnwrap(edge.settings.designStamp)
        let line = try XCTUnwrap(FlexibleFlatPrism.line(s)), range = try XCTUnwrap(FlexiblePressStamp.range(s, sp))
        for k in [-1000.0, 1000.0] {
            let q = FlexiblePressStamp.dragged(s, sp, by: line.dir * k)
            XCTAssertTrue(range.contains(q.centreU) && q.centreV == 0, "\(s.label): \(k) mm → on the edge")
        }
        flush("U1_lines_stamp.txt")
    }

    // MARK: 3 + 4 — the edge card is a face's table; the camera stays where he put it (hosted, 13" portrait)

    func testAnEdgeCardReadsLikeAFaceAndTheCameraStaysPut() async throws {
        let (r, _, m) = try await hisPad(lattice: false)
        let g = try XCTUnwrap(m.squeezeGroups.first { $0.kind == .edges && $0.presses.count >= 2 }, "his edges group")
        let presses = g.presses.compactMap { m.press($0) }.filter { $0.strip != nil }
        XCTAssertGreaterThanOrEqual(presses.count, 2)
        for p in presses { m.setPressShape(p.id, "curves") }
        // 3: no "Across" / "Along" at the curves' end handles
        let a = presses[0]
        XCTAssertTrue(FlexiblePressCurveLayer.drawn(model: m, press: a.id, projection: nil).allSatisfy { $0.label.isEmpty }, "no words")
        FlexiblePressCurveLayer.controlCurveWords = true
        XCTAssertEqual(FlexiblePressCurveLayer.drawn(model: m, press: a.id, projection: nil).map(\.label), ["Across", "Along"], "RED CONTROL")
        FlexiblePressCurveLayer.controlCurveWords = false
        let loop = FlexibleSquishLoop()
        let h = host(FlexibleStagePage(project: r.project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)
        m.rail = .group(g.id)
        m.selectedPress = a.id
        pump(2)
        func order(_ what: String) -> [String: (shape: CGRect?, deepest: CGRect?)] {
            var out: [String: (CGRect?, CGRect?)] = [:]
            for p in presses { let l = p.strip!.label; out[l] = (h.frames.all["pressShape-\(l)"], h.frames.all["flatRow-deepest-\(l)"]) }
            log.append("\(what): " + out.sorted { $0.key < $1.key }.map { "\($0.key) shape \($0.value.0.map { "\(Int($0.minY))" } ?? "-") deepest \($0.value.1.map { "\(Int($0.minY))" } ?? "-")" }.joined(separator: " · "))
            return out
        }
        // a face's order: Shape, then Deepest squish, then the edge's own Tilt / Twist — on every press
        for (l, f) in order("U1") {
            let s = try XCTUnwrap(f.shape, "\(l): Shape on every press"), d = try XCTUnwrap(f.deepest, "\(l): Deepest squish")
            XCTAssertLessThanOrEqual(s.maxY, d.minY + 1, "\(l): Shape above Deepest squish")
            if let t = h.frames.all["flatRow-twist-\(l)"] { XCTAssertLessThan(d.maxY, t.minY + 1, "\(l): Twist after Deepest squish") }
        }
        try shot("U1_02_13p_edge_card_like_a_face_no_curve_words.png", h, settle: 1.5)
        FlexibleEdgeGroupRows.controlShapeAfterAngles = true
        m.selectedPress = presses[1].id   // (a change the card re-renders on)
        pump(1.5)
        let red = order("RED CONTROL")
        FlexibleEdgeGroupRows.controlShapeAfterAngles = false
        m.selectedPress = a.id
        let rs = red.values.compactMap { f -> Bool? in guard let s = f.shape, let d = f.deepest else { return nil }; return s.minY > d.maxY - 1 }
        XCTAssertTrue(rs.contains(true) || red.values.contains { $0.shape == nil }, "RED CONTROL: Shape after the angles / only on one press")
        pump(1.5)
        // 4: the camera stays where he put it — on selecting another press, on [Done]'s request, on a typed depth
        let cm = try XCTUnwrap(cameraModel(h), "the page's camera")
        func cam() -> [Float] { let c = cm.camera; return [c.azimuth, c.elevation, c.distance, c.target.x, c.target.y, c.target.z] }
        let c0 = cam()
        m.selectedPress = presses[1].id
        pump(2)
        m.flatCameraRequest = presses[1].id   // (what [Done] / an added press asks)
        pump(2)
        if let d = FlexibleFlatPrism.depth(of: presses[1]) {
            var done = false
            Task { @MainActor in _ = await m.setFlatCut(presses[1].id, depthMM: d + 0.5, direction: m.flatCut(presses[1].id)?.direction ?? presses[1].direction, snap: presses[1].snap); done = true }
            pumpUntil(30) { done }
            pump(1)
        }
        let c1 = cam()
        log.append("camera before \(c0) after \(c1)")
        for i in c0.indices { XCTAssertEqual(c0[i], c1[i], accuracy: 1e-4, "the camera did not move (\(i))") }
        XCTAssertNil(m.flatCameraRequest, "the request is consumed")
        // RED CONTROL: R7-E1 / R7-E4's turn on selecting a press
        FlexibleStagePage.controlAutoCamera = true
        m.selectedPress = presses[0].id
        pump(2)
        FlexibleStagePage.controlAutoCamera = false
        let c2 = cam()
        XCTAssertTrue(c0.indices.contains { abs(c0[$0] - c2[$0]) > 1e-3 }, "RED CONTROL: the camera turned by itself")
        flush("U1_lines_card_camera.txt")
    }

    // MARK: pictures

    func bendPicture(_ project: ProjectModel, _ m: FlexibleStageModel, group g: FlexibleSqueezeGroup, face key: FlexFaceKey, stack st: FlexStackInfo) throws {
        m.rail = .group(g.id)
        m.select(3)
        var v = m.views; v.remove(.play); v.insert(.bend); m.views = v
        let loop = FlexibleSquishLoop()
        let h = host(FlexibleStagePage(project: project, model: m, loop: loop, onExit: {}), size: Self.p13)
        pump(3)
        // looking at Face 3 and the Top, 35° up (his img_1020_7 shows the side and the Top together)
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let out = settle.act(-SIMD3<Float>(st.load))
        let eye = simd_normalize(out + SIMD3<Float>(0, 1.0, 0) + simd_cross(out, SIMD3<Float>(0, 1, 0)) * 0.45)
        if let cm = cameraModel(h) {
            var c = cm.camera
            let ae = OrbitCamera.azimuthElevation(forDirection: eye, currentAzimuth: c.azimuth)
            c.setOrientation(azimuth: ae.azimuth, elevation: ae.elevation)
            // the part up and right of the panel (as he would pan it)
            let rot = c.viewRotation().transpose   // (world → view; its rows are the view's axes in the world)
            c.target -= rot * SIMD3<Float>(1, 0, 0) * 22 + rot * SIMD3<Float>(0, 1, 0) * 18
            c.distance *= 0.75
            cm.adopt(c)
        }
        try shot("U1_01_13p_bend_face3_stamp_top_follows.png", h, settle: 3)
        // 2's picture rides here: the stamp dragged far off the side stops with part of it still on
        m.moveStamp(3, to: SIMD2(-300, 10))
        var w = m.views; w.remove(.bend); m.views = w
        try shot("U1_03_13p_face3_stamp_dragged_off_stops_on_the_edge.png", h, settle: 2)
    }

    func latticePair(part: ViewerMesh, lattice g: FlexibleGeneratedLattice, control: FlexibleLatticeInputs) throws {
        guard let device = MTLCreateSystemDefaultDevice(), let mr = MeshRenderer(device: device, sampleCount: 4) else { return }
        let bg = MTLClearColor(red: 0.11, green: 0.12, blue: 0.14, alpha: 1)
        mr.setMesh(part)
        mr.beginSettle(to: simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0)), duration: 0)
        mr.camera.setOrientation(azimuth: 0.78, elevation: 0.55)
        mr.camera.distance *= 0.62
        let n = 1800
        func frame(_ inputs: FlexibleLatticeLayerInputs?) throws -> CGImage {
            _ = mr.applyFlexibleLattice(inputs, device: device)
            mr.flexibleLattice?.hidden = false
            mr.setBodyAlpha(FlexibleStagePage.xrayBodyAlpha)
            var px = try XCTUnwrap(mr.renderOffscreen(size: n, clear: bg))
            for k in stride(from: 0, to: px.count, by: 4) { px.swapAt(k, k + 2); px[k + 3] = 255 }
            let ctx = try XCTUnwrap(CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                              space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
            return try XCTUnwrap(ctx.makeImage())
        }
        let full0 = try frame(FlexibleLatticeLayerInputs(lattice: control, faces: g.squishFaces, token: -7001))
        let full1 = try frame(FlexibleLatticePreview.inputs(xray: true, lattice: g, building: false))
        // cropped to where the two frames differ (the holes), padded, so the rods read at the page's scale
        func rgba(_ i: CGImage) -> [UInt8] {
            var b = [UInt8](repeating: 0, count: n * n * 4)
            let c = CGContext(data: &b, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: CGColorSpaceCreateDeviceRGB(),
                              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            c.draw(i, in: CGRect(x: 0, y: 0, width: n, height: n))
            return b
        }
        let a0 = rgba(full0), a1 = rgba(full1)
        var lo = (x: n, y: n), hi = (x: 0, y: 0), differ = 0
        for y in 0..<n { for x in 0..<n {
            let k = (y * n + x) * 4
            if abs(Int(a0[k]) - Int(a1[k])) + abs(Int(a0[k + 1]) - Int(a1[k + 1])) + abs(Int(a0[k + 2]) - Int(a1[k + 2])) > 30 {
                differ += 1; lo = (min(lo.x, x), min(lo.y, y)); hi = (max(hi.x, x), max(hi.y, y))
            }
        } }
        log.append("lattice frames differ on \(differ) px, box \(lo)…\(hi)")
        let side = max(240, max(hi.x - lo.x, hi.y - lo.y) + 80)
        let cx = differ > 0 ? (lo.x + hi.x) / 2 : n / 2, cy = differ > 0 ? (lo.y + hi.y) / 2 : n / 2
        let crop = CGRect(x: max(0, min(n - side, cx - side / 2)), y: max(0, min(n - side, cy - side / 2)), width: min(side, n), height: min(side, n))
        let before = try XCTUnwrap(full0.cropping(to: crop)), after = try XCTUnwrap(full1.cropping(to: crop))
        let S = 900, W = 2 * S + 24
        let ctx = try XCTUnwrap(CGContext(data: nil, width: W, height: S, bitsPerComponent: 8, bytesPerRow: W * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        ctx.setFillColor(CGColor(gray: 0, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: W, height: S))
        ctx.draw(before, in: CGRect(x: 0, y: 0, width: S, height: S))
        ctx.draw(after, in: CGRect(x: S + 24, y: 0, width: S, height: S))
        try writePNG(try XCTUnwrap(ctx.makeImage()), "U1_04_lattice_rods_before_after.png")
    }

    // MARK: the harness (the R7-E5 probe's)

    func pump(_ s: Double) {
        let end = Date().addingTimeInterval(s)
        while Date() < end { _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.02)) }
    }
    @discardableResult
    func pumpUntil(_ t: Double, _ c: () -> Bool) -> Bool {
        let end = Date().addingTimeInterval(t)
        while !c() { if Date() > end { return false }; _ = RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return true
    }
    func host<V: View>(_ v: V, size: CGSize) -> Host {
        let frames = Frames()
        let root = AnyView(v.onPreferenceChange(FlexibleKeepOutKey.self) { frames.all = $0 }.environment(\.colorScheme, .dark))
        let hv = NSHostingView(rootView: root)
        hv.frame = CGRect(origin: .zero, size: size)
        _ = NSApplication.shared
        let w = U1Win(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height),
                      styleMask: [.borderless], backing: .buffered, defer: false)
        w.appearance = NSAppearance(named: .darkAqua)
        w.contentView = hv
        w.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        w.orderFrontRegardless()
        w.makeKey()
        hv.layoutSubtreeIfNeeded()
        addTeardownBlock { @MainActor in w.orderOut(nil); w.contentView = nil }
        return Host(window: w, view: hv, size: size, frames: frames)
    }
    func mtkViews(_ v: NSView) -> [MTKView] {
        var out: [MTKView] = []
        if let m = v as? MTKView { out.append(m) }
        for s in v.subviews { out += mtkViews(s) }
        return out
    }
    func stageMTK(_ h: Host) -> MTKView? {
        mtkViews(h.view).filter { $0.delegate is MeshRenderer }.max { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }
    }
    func cameraModel(_ h: Host) -> OrbitCameraModel? {
        guard let mtk = stageMTK(h) else { return nil }
        for g in mtk.gestureRecognizers {
            guard let t = g.target else { continue }
            for c in Mirror(reflecting: t).children where c.label == "cameraModel" {
                if let cm = c.value as? OrbitCameraModel { return cm }
            }
        }
        return nil
    }
    func writePNG(_ img: CGImage, _ name: String) throws {
        guard let dir = Self.dir else { return }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent(name)
        let dest = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(dest, img, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
    }
    func flush(_ file: String) {
        print("FLEX-U1 " + log.joined(separator: "\n  "))
        if let d = Self.dir { try? (log.joined(separator: "\n") + "\n").write(to: d.appendingPathComponent(file), atomically: true, encoding: .utf8) }
    }

    /// The page as he sees it: its renderer offscreen (its camera, its viewport) under the hosted chrome.
    func shot(_ name: String, _ h: Host, settle: Double = 0.8) throws {
        pump(settle)
        guard Self.dir != nil else { return }
        let hv = h.view
        hv.layoutSubtreeIfNeeded()
        let rep = try XCTUnwrap(hv.bitmapImageRepForCachingDisplay(in: hv.bounds))
        hv.cacheDisplay(in: hv.bounds, to: rep)
        let cg = try XCTUnwrap(rep.cgImage)
        let PW = cg.width, PH = cg.height
        let scale = CGFloat(PW) / h.size.width
        var chrome = [UInt8](repeating: 0, count: PW * PH * 4)
        let cctx0 = try XCTUnwrap(CGContext(data: &chrome, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        cctx0.draw(cg, in: CGRect(x: 0, y: 0, width: PW, height: PH))
        let bg = DS.Color.background
        let gr = Int((bg.r * 255).rounded()), gg = Int((bg.g * 255).rounded()), gb = Int((bg.b * 255).rounded())
        var probe = (0, 0, 0, 0)
        var modelImg: CGImage?
        var placed = CGRect.zero
        if let mtk = stageMTK(h), let r = mtk.delegate as? MeshRenderer {
            var vf = mtk.convert(mtk.bounds, to: hv)
            if !hv.isFlipped { vf.origin.y = hv.bounds.height - vf.maxY }
            let cx = Int(vf.midX * scale), cy = Int(vf.midY * scale)
            let i = (cy * PW + cx) * 4
            probe = (Int(chrome[i]), Int(chrome[i + 1]), Int(chrome[i + 2]), Int(chrome[i + 3]))
            if probe.0 + probe.1 + probe.2 > 60 { probe = (0, 0, 0, 0) }
            let saved = r.camera
            var cam = saved
            let W = vf.width, H = vf.height
            let side: CGFloat
            if W > H { cam.fovY = 2 * atan(tan(saved.fovY / 2) * Float(W / H)); side = W } else { side = H }
            r.camera = cam
            let n = Int((side * scale).rounded())
            let px = r.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
            r.camera = saved
            if var m = px {
                for k in stride(from: 0, to: m.count, by: 4) { m.swapAt(k, k + 2); m[k + 3] = 255 }
                let mctx = try XCTUnwrap(CGContext(data: &m, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4,
                                                   space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue))
                modelImg = mctx.makeImage()
                placed = CGRect(x: (vf.midX - side / 2) * scale, y: (h.size.height - vf.midY - side / 2) * scale, width: side * scale, height: side * scale)
            }
        }
        for k in stride(from: 0, to: chrome.count, by: 4) {
            let a = chrome[k + 3]
            let isBG = abs(Int(chrome[k]) - gr) <= 3 && abs(Int(chrome[k + 1]) - gg) <= 3 && abs(Int(chrome[k + 2]) - gb) <= 3 && a == 255
            let isProbe = probe.3 > 0 && abs(Int(chrome[k]) - probe.0) <= 2 && abs(Int(chrome[k + 1]) - probe.1) <= 2 && abs(Int(chrome[k + 2]) - probe.2) <= 2 && Int(a) == probe.3
            if isBG || isProbe { chrome[k] = 0; chrome[k + 1] = 0; chrome[k + 2] = 0; chrome[k + 3] = 0 }
        }
        let cctx = try XCTUnwrap(CGContext(data: &chrome, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                           space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        let cimg = try XCTUnwrap(cctx.makeImage())
        let out = try XCTUnwrap(CGContext(data: nil, width: PW, height: PH, bitsPerComponent: 8, bytesPerRow: PW * 4,
                                          space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
        out.setFillColor(CGColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))
        out.fill(CGRect(x: 0, y: 0, width: PW, height: PH))
        if let mi = modelImg { out.draw(mi, in: placed) }
        out.draw(cimg, in: CGRect(x: 0, y: 0, width: PW, height: PH))
        try writePNG(try XCTUnwrap(out.makeImage()), name)
    }
}
#endif
