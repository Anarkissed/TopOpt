// FlexibleR7X1VerifyHostedTests — round 7 batch X1's VERIFY fixes, by the shipping renderer (MeshRenderer's offscreen render
// of exactly what the main Flexible page hands MetalMeshView) on HIS pad with his live lattice (Group C's two 25 mm
// face-prisms — the strips of his img5), at img5's TOP camera with Heat ON (the page's default). Written BEFORE the code (the
// red run: round7/batch_x1/r7x1v_red_run.txt); each test runs its RED control inside. His words (2026-10-14, binding): "If
// the user adds x-ray, we see through the solid" (Q9); his img3: "The view of the heatmap doesn't actually change anything."
//   VH1  X-ray with Heat on, from above: inside the strips the LATTICE is seen (not one opaque heat-coloured square), and its
//        walls wear the heat (they differ from the density walls); with Group C picked, its face-prisms hold the lattice.
//        RED `controlHeatOnLid` (X1's first build: the opaque lid hid everything inside the strips).
//   VH2  The printed view (X-ray off) with Heat on: the heat is on the WALLS inside the strips, and the solid part outside
//        them is the plain part (no flat 0 mm lid); on the fixture with the whole Top latticed, the Squish row shows only
//        because heat is drawn. RED `controlHeatOnLid` (the walls by density, the 0 mm lid, a Squish row with no heat drawn).
#if canImport(MetalKit) && canImport(AppKit)
import XCTest
import AppKit
import MetalKit
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7X1VerifyHostedTests: XCTestCase {
    typealias H = FlexibleR7X1HostedTests
    typealias Cam = FlexibleRound6Tests.Cam

    func hisStrips() async throws -> (FlexibleHisProject.Restored, FlexibleMainStage, FlexibleStageModel) {
        let (r, s, m) = try await FlexibleR7M1Fixtures.hisPad(self, live: true)
        s.didExitSettings()
        s.apply(r.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) }
        s.refresh()
        return (r, s, m)
    }

    /// One frame of what the page hands MetalMeshView now (BGRA, n × n), its prisms included.
    func frame(_ s: FlexibleMainStage, _ p: ProjectModel, cam: Cam = r7x1Img5, n: Int = 900, device: MTLDevice) throws -> H.Frame {
        s.refresh()
        let settle = p.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        let mesh = try XCTUnwrap(s.mesh(p, on: .lattice))
        let mr = try FlexibleRound6EvidenceProbe().renderer(
            mesh: mesh, tints: s.tints(p, on: .lattice, roles: [:], stress: nil), dents: s.dents(p, on: .lattice),
            scale: s.dentScale(p, on: .lattice), bodyAlpha: s.bodyAlpha(p, on: .lattice) ?? 1, settle: settle, cam: cam,
            device: device, items: s.volumes(p, on: .lattice, drilledIn: false), layer: s.layer(p, stage: .lattice, pageUp: false))
        let bg = DS.Color.background
        return H.Frame(px: try XCTUnwrap(mr.renderOffscreen(size: n, clear: MTLClearColor(red: bg.r, green: bg.g, blue: bg.b, alpha: 1))), n: n)
    }

    /// The pixels that are not the background.
    static func modelPixels(_ f: H.Frame) -> [Bool] {
        let bg = DS.Color.background
        let br = Int((bg.b * 255).rounded()), bgc = Int((bg.g * 255).rounded()), bb = Int((bg.r * 255).rounded())
        var out = [Bool](repeating: false, count: f.n * f.n)
        for i in 0..<(f.n * f.n) {
            let d0 = abs(Int(f.px[4 * i]) - br), d1 = abs(Int(f.px[4 * i + 1]) - bgc), d2 = abs(Int(f.px[4 * i + 2]) - bb)
            out[i] = d0 + d1 + d2 > 9
        }
        return out
    }

    /// The share of `sel`'s pixels on an EDGE (the luminance steps to the right and below sum over 12 of 255): the lattice's
    /// walls and voids are full of them, a smooth heat lid or a glass over it has almost none (calibrated on the red run's
    /// frames inside his left strip: the opaque lid 0.9 %, the glass over it 2.0 %, the lattice seen in X-ray 50 %).
    static func detail(_ f: H.Frame, where sel: [Bool]) -> Double {
        func lum(_ i: Int) -> Double { 0.2126 * Double(f.px[4 * i + 2]) + 0.7152 * Double(f.px[4 * i + 1]) + 0.0722 * Double(f.px[4 * i]) }
        var n = 0, e = 0
        for y in 0..<(f.n - 1) { for x in 0..<(f.n - 1) {
            let i = y * f.n + x
            guard sel[i] else { continue }
            n += 1
            if abs(lum(i) - lum(i + 1)) + abs(lum(i) - lum(i + f.n)) > 12 { e += 1 }
        } }
        return n > 0 ? Double(e) / Double(n) : 0
    }

    // MARK: - VH1: X-ray with Heat on sees the lattice and its heat from above

    func testXrayWithHeatOnSeesTheLatticeAndItsHeatFromAbove() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (r, s, m) = try await hisStrips()
        let p = r.project
        let h = H()
        XCTAssertTrue(s.heat, "premise: Heat on (the default)")
        let fp = try h.footprint(s, p, m, device: device)
        XCTAssertGreaterThan(fp.strips.filter { $0 }.count, 900 * 900 / 50, "premise: the strips on screen")
        func shots() throws -> (xh: H.Frame, lid: H.Frame, xn: H.Frame) {
            s.xrayOn = true
            let xh = try frame(s, p, device: device)          // X-ray, Heat on
            s.latticeOn = false
            let lid = try frame(s, p, device: device)         // X-ray, Heat on, no walls: the lid alone
            s.latticeOn = true
            s.heat = false
            let xn = try frame(s, p, device: device)          // X-ray, Heat off: the walls by density
            s.heat = true
            s.xrayOn = false
            return (xh, lid, xn)
        }
        let a = try shots()
        let seen = H.differing(a.xh, a.lid, where: fp.strips), heated = H.differing(a.xh, a.xn, where: fp.strips)
        let walls = Self.detail(a.xh, where: fp.strips), lidDetail = Self.detail(a.lid, where: fp.strips)
        H.dump(a.xh, "VH1_xray_heat_img5.png"); H.dump(a.lid, "VH1_xray_heat_no_walls_img5.png"); H.dump(a.xn, "VH1_xray_heat_off_img5.png")
        XCTAssertGreaterThanOrEqual(walls, 0.20, "★ X-ray, Heat on, from above: the lattice is SEEN inside the strips (its walls' edges, not a smooth lid)")
        XCTAssertGreaterThanOrEqual(seen.share, 0.60, "★ …the frame is not the lid's")
        XCTAssertGreaterThanOrEqual(heated.share, 0.30, "★ …and its walls wear the heat (not the density ramp)")
        // ★ RED CONTROL: X1's first build — the heat on an opaque lid in X-ray
        // ★ RE-PINNED (R7-D2 — his answer 2 of 2026-10-17 evening, "X-ray on the main page shows EVERY face-prism faint, the
        // picked group's bright (even before a pick)", and answer 4, fainter glass over the open lattice): X-ray now draws every
        // face-prism faint, and that glass is fainter when the walls are drawn than in the lid-only frame, so under the opaque
        // lid the X-ray frame is no longer the lid frame pixel for pixel (the targeted suite measured: wall edges 5.9 %, differs
        // 82 % — was < 5 % and < 20 %). In the SHIPPING frame the control now proves the wall-edge measure only (far under the
        // 20 % bar; the faint prisms' outlines add about 1 %), and "differs from the lid" is no longer a signal there; the
        // X1 control as X1 measured it (no prism before a pick: `controlXrayPickedOnly`) still holds both, unchanged.
        s.controlHeatOnLid = true
        defer { s.controlHeatOnLid = false; FlexibleMainStage.controlXrayPickedOnly = false }
        let ctl = try shots()
        FlexibleMainStage.controlXrayPickedOnly = true
        let ctlX1 = try shots()
        FlexibleMainStage.controlXrayPickedOnly = false
        s.controlHeatOnLid = false
        let cSeen = H.differing(ctl.xh, ctl.lid, where: fp.strips), cWalls = Self.detail(ctl.xh, where: fp.strips)
        let cSeenX1 = H.differing(ctlX1.xh, ctlX1.lid, where: fp.strips), cWallsX1 = Self.detail(ctlX1.xh, where: fp.strips)
        H.dump(ctl.xh, "VH1_control_xray_heat_lid_img5.png"); H.dump(ctlX1.xh, "VH1_control_xray_heat_lid_x1prisms_img5.png")
        XCTAssertLessThan(cWalls, 0.10, "★ RED CONTROL: the opaque heat square hid the lattice (wall edges far under the 20 % bar; R7-D2's faint prism outlines aside)")
        XCTAssertLessThan(cWallsX1, 0.05, "★ RED CONTROL (X1's prisms): the opaque heat square hid the lattice (no wall edge)")
        XCTAssertLessThan(cSeenX1.share, 0.20, "★ RED CONTROL (X1's prisms): …its frame the lid's")
        // Group C picked: its face-prisms' extent, the lattice inside them (a pick re-reads the main page: the lattice is
        // waited for again)
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        p.selection.setActive(c.id)
        try await Task.sleep(nanoseconds: 600_000_000)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m.lattice != nil && !m.latticeBuilding && !m.latticeIsStale }
        try await FlexibleHisProject.waitFor(300, "the sims") { !m.squish.isEmpty && !m.squish.values.contains(.pending) }
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) }
        s.xrayOn = true
        let picked = try frame(s, p, device: device)
        s.latticeOn = false
        let pickedLid = try frame(s, p, device: device)
        s.latticeOn = true
        s.xrayOn = false
        let pickedWalls = Self.detail(picked, where: fp.strips)
        H.dump(picked, "VH1_xray_heat_groupC_picked_img5.png"); H.dump(pickedLid, "VH1_xray_heat_groupC_picked_no_walls_img5.png")
        XCTAssertGreaterThan(s.volumes(p, on: .lattice, drilledIn: false).count, 0, "premise: Group C's face-prisms drawn")
        XCTAssertGreaterThanOrEqual(pickedWalls, 0.15, "★ Group C picked: its face-prisms hold the lattice (not two empty boxes)")
        print("FLEX-R7X1V-H1 X-ray + Heat, img5 top, inside the strips: wall edges \(String(format: "%.1f", 100 * walls)) % of the pixels (the lid alone \(String(format: "%.1f", 100 * lidDetail)) %), the frame differs from the lid's at \(String(format: "%.1f", 100 * seen.share)) %, walls heated \(String(format: "%.1f", 100 * heated.share)) % (vs Heat off) · Group C picked: wall edges \(String(format: "%.1f", 100 * pickedWalls)) % · control (opaque lid): wall edges \(String(format: "%.1f", 100 * cWalls)) %, differs \(String(format: "%.1f", 100 * cSeen.share)) % · control with X1's prisms: wall edges \(String(format: "%.1f", 100 * cWallsX1)) %, differs \(String(format: "%.1f", 100 * cSeenX1.share)) %")
    }

    // MARK: - VH2: the printed view's heat is on the walls, not a 0 mm lid

    func testThePrintedViewsHeatIsOnTheWallsNotAFlatLid() async throws {
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let (r, s, m) = try await hisStrips()
        let p = r.project
        let h = H()
        XCTAssertFalse(s.xrayOn)
        XCTAssertTrue(s.printedView, "premise: the printed view (Finish None)")
        let fp = try h.footprint(s, p, m, device: device)
        let outside = H.eroded(zip(fp.model, fp.strips).map { $0 && !$1 }, n: 900, r: 3)
        func pair() throws -> (on: H.Frame, off: H.Frame, kinds: [FlexibleReadKind]) {
            s.heat = true
            let on = try frame(s, p, device: device)
            let kinds = s.legendKinds
            s.heat = false
            let off = try frame(s, p, device: device)
            s.heat = true
            return (on, off, kinds)
        }
        let a = try pair()
        let ins = H.differing(a.on, a.off, where: fp.strips), out = H.differing(a.on, a.off, where: outside)
        H.dump(a.on, "VH2_printed_heat_img5.png"); H.dump(a.off, "VH2_printed_heat_off_img5.png")
        XCTAssertGreaterThanOrEqual(ins.share, 0.30, "★ Heat on: the walls inside the strips wear the heat")
        XCTAssertLessThanOrEqual(out.share, 0.05, "★ …and the solid part is the plain part (no flat 0 mm lid)")
        XCTAssertTrue(a.kinds.contains(.dent), "the Squish row (the heat is drawn)")
        // ★ RED CONTROL: X1's first build — the walls by density, the heat on the solid part only (0 mm, flat)
        s.controlHeatOnLid = true
        let ctl = try pair()
        s.controlHeatOnLid = false
        let cIns = H.differing(ctl.on, ctl.off, where: fp.strips), cOut = H.differing(ctl.on, ctl.off, where: outside)
        H.dump(ctl.on, "VH2_control_printed_heat_img5.png")
        XCTAssertLessThan(cIns.share, 0.05, "★ RED CONTROL: Heat changed nothing inside the strips (his img3)")
        // ★ RE-PINNED (merge of X1 after M2 — ruling 3, his img3): M2 presses only the lattice sections, so even X1's first
        // build puts no flat 0 mm lid on the solid part (was cOut > 0.50 — on M1 the whole Top was pressed); the control stays
        // red inside the strips (Heat changed nothing there) and on the whole-Top fixture below
        XCTAssertLessThanOrEqual(cOut.share, 0.05, "★ RED CONTROL (M2): no lid on the solid part to change")
        var lines = ["his strips: inside \(String(format: "%.1f", 100 * ins.share)) % differ (Heat on vs off), outside \(String(format: "%.2f", 100 * out.share)) % · control inside \(String(format: "%.1f", 100 * cIns.share)) %, outside \(String(format: "%.1f", 100 * cOut.share)) %"]

        // ★ the fixture with the whole Top latticed (a1Project(3)'s Top face-prism): the Squish row only with heat drawn
        let r2 = try FlexiblePressFixtures.a1Project(3, self)
        let s2 = FlexibleMainStage()
        s2.reduceMotion = { true }
        let m2 = s2.model(for: r2.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m2.waitForIdle() }
        m2.openScene()
        try await FlexibleSquishFixture.settle(m2, "his pad (Top face-prism)")
        m2.edit({ $0.finish = FlexibleFinish.none.rawValue }, recompute: false)
        s2.didExitSettings()
        s2.apply(r2.project, owned: true, pageUp: false)
        try await FlexibleHisProject.waitFor(240, "the lattice") { m2.lattice != nil && !m2.latticeBuilding && !m2.latticeIsStale }
        try await FlexibleHisProject.waitFor(300, "the sims") { !m2.squish.isEmpty && !m2.squish.values.contains(.pending) }
        for _ in 0..<20 { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(s2.printedView, "premise: the printed view")
        s2.latticeOn = false
        let plain2 = try frame(s2, r2.project, cam: r7x1Img1, device: device)
        s2.latticeOn = true
        let model2 = Self.modelPixels(plain2)
        func topPair() throws -> (share: Double, kinds: [FlexibleReadKind]) {
            s2.heat = true
            let on = try frame(s2, r2.project, cam: r7x1Img1, device: device)
            let kinds = s2.legendKinds
            s2.heat = false
            let off = try frame(s2, r2.project, cam: r7x1Img1, device: device)
            s2.heat = true
            H.dump(on, "VH2_topprism_\(s2.controlHeatOnLid ? "control_" : "")heat_img1.png")
            return (H.differing(on, off, where: model2).share, kinds)
        }
        let top = try topPair()
        XCTAssertGreaterThanOrEqual(top.share, 0.10, "★ the whole Top latticed: Heat on colours its walls")
        XCTAssertTrue(top.kinds.contains(.dent), "★ …so the Squish row shows")
        XCTAssertFalse(top.kinds.contains(.lattice), "★ …and no density row (the walls wear the squish)")
        s2.controlHeatOnLid = true
        let topC = try topPair()
        s2.controlHeatOnLid = false
        XCTAssertLessThan(topC.share, 0.02, "★ RED CONTROL: no heat drawn anywhere on the whole-Top fixture…")
        XCTAssertTrue(topC.kinds.contains(.dent), "★ RED CONTROL: …yet the Squish row showed (the verify's finding)")
        lines.append("whole-Top fixture (img1): Heat on vs off \(String(format: "%.1f", 100 * top.share)) % of the model differ · legend \(top.kinds) · control \(String(format: "%.2f", 100 * topC.share)) %, legend \(topC.kinds)")
        print("FLEX-R7X1V-H2 the printed view, Heat on:\n  " + lines.joined(separator: "\n  "))
    }
}
#endif
