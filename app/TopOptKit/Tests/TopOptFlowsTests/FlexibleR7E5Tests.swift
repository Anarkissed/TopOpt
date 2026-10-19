// FlexibleR7E5Tests — round 7, batch R7-E5 (his answers of 2026-10-19 ~17:50, binding): "one more small lean front-end batch for
// edge groups now: Heat colours, X-ray showing the bend as a prism, Play following the drawn curve (not an even push)"; "Stamp turn:
// 0° = the long side along the edge (turning away counts up)"; and E4_01 ([Top] lost the flat prism's handles). FRONT-END only (his
// ruling of 2026-10-19 ~14:50): nothing reaches core's job. Each RED CONTROL runs inside its test and is asserted red. On HIS pad.
import XCTest
import simd
import TopOptDesign
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7E5Tests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias B = FlexiblePressCurveBaselines

    override func tearDown() {
        FlexibleFlatPrismUI.controlFacingNeedsAFrontFace = false
        FlexiblePressStamp.controlStoredTurn = false
        FlexiblePressPush.controlEvenPush = false
        FlexiblePressHeat.controlNoPressHeat = false
        FlexibleBendPrism.controlNoEdges = false
        super.tearDown()
    }

    func press(_ st: FlexibleStrip, _ d: SIMD3<Double>, _ h: Double) -> FlexiblePress {
        FlexiblePress(regions: st.members.map(\.root), direction: d, settings: FlexibleFaceSettings(faceRegionID: 0, deepestMM: h), strip: st)
    }

    // MARK: - (5) [Top] keeps the flat prism's handles (E4_01)

    func testTheTopViewKeepsTheFlatPrismsHandles() async throws {
        let (r, m) = try await F.hisPad(self)
        _ = r
        let e = try await F.edge16(m)
        let st = e.strip, d = try XCTUnwrap(st.halfway)
        let settle = m.project.force.settleRotation ?? simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))
        // the page's own camera for the view (FlexibleStagePage.turnToPressCurve: the eye, then OrbitCamera's pole clamp), its line of
        // sight back in the model's frame
        func ray(_ v: B.View) -> SIMD3<Double> {
            let eye = B.eye(v, arrow: settle.act(SIMD3<Float>(d)))
            var cam = OrbitCamera(target: .zero, distance: 100)
            let ae = OrbitCamera.azimuthElevation(forDirection: eye, currentAzimuth: cam.azimuth)
            cam.setOrientation(azimuth: ae.azimuth, elevation: ae.elevation)
            let size = CGSize(width: 1032, height: 1376)
            let r = CameraProjection(camera: cam, viewportSize: size).ray(throughViewPoint: CGPoint(x: size.width / 2, y: size.height / 2))!
            return SIMD3<Double>(settle.inverse.act(r.dir))
        }
        let dots = st.members.map { mb in simd_dot(FlexibleFlatPrism.inwardNormal(mb, toward: d)!, ray(.top)) }
        let l = try XCTUnwrap(FlexibleFlatPrism.line(st))
        print("FLEX-E5-5 Edge 16 from [Top]: members' inward·ray \(dots) · |edge·ray| \(abs(simd_dot(l.dir, ray(.top))))")
        XCTAssertTrue(dots.allSatisfy { abs($0) < 0.06 }, "premise (why E4_01 lost them): from [Top] both faces of Edge 16 are EDGE-ON (within the pole clamp)")
        XCTAssertTrue(FlexibleFlatPrismUI.facing(st, direction: d, ray: ray(.top)), "★ [Top] shows the chip, knob and boxes")
        XCTAssertTrue(FlexibleFlatPrismUI.facing(st, direction: d, ray: ray(.deg45)), "★ [45°] still does")
        let n = st.members.compactMap { FlexibleFlatPrism.inwardNormal($0, toward: d) }.reduce(SIMD3<Double>.zero, +)
        XCTAssertFalse(FlexibleFlatPrismUI.facing(st, direction: d, ray: simd_normalize(SIMD3<Double>.zero - n)), "★ behind the part: hidden")
        // RED CONTROL: E4's rule — the ray through the ANCHOR from a camera over the part (perspective: the press off the view's
        // centre, as the page pans it beside the panel), a member face turned toward that ray
        let mesh = try XCTUnwrap(m.project.viewerMesh)
        let c = FlexibleFlatPrism.cut(st, direction: d, depthMM: 3)
        let anchor = FlexibleFlatPrismUI.arrow(st, c, lengthMM: 20).anchor
        let centre = settle.act((mesh.bounds.min + mesh.bounds.max) / 2)
        let eye = B.eye(.top, arrow: settle.act(SIMD3<Float>(d)))
        var cam = OrbitCamera(target: centre, distance: Float(B.focus(st, c).radius) * 2.2 / sin(Float.pi / 8))
        let ae = OrbitCamera.azimuthElevation(forDirection: eye, currentAzimuth: cam.azimuth)
        cam.setOrientation(azimuth: ae.azimuth, elevation: ae.elevation)
        let size = CGSize(width: 1032, height: 1376)
        let proj = CameraProjection(camera: cam, viewportSize: size)
        let ap = try XCTUnwrap(proj.project(settle.act(SIMD3<Float>(anchor))))
        let anchorRay = SIMD3<Double>(settle.inverse.act(try XCTUnwrap(proj.ray(throughViewPoint: ap)).dir))
        let anchorDots = st.members.map { mb in simd_dot(FlexibleFlatPrism.inwardNormal(mb, toward: d)!, anchorRay) }
        print("FLEX-E5-5 RED CONTROL: the ray through the anchor at \(ap) — inward·ray \(anchorDots)")
        FlexibleFlatPrismUI.controlFacingNeedsAFrontFace = true
        XCTAssertFalse(FlexibleFlatPrismUI.facing(st, direction: d, ray: anchorRay), "RED CONTROL: E4's rule hides them from [Top]")
        FlexibleFlatPrismUI.controlFacingNeedsAFrontFace = false
        XCTAssertTrue(FlexibleFlatPrismUI.facing(st, direction: d, ray: ray(.top)), "★ the line of sight keeps them")
    }

    // MARK: - (4) the stamp's turn reads 0° with its long side along the edge

    func testTheStampTurnReadsFromItsLongSide() {
        typealias S = FlexiblePressStamp
        func stamp(_ w: Double, _ l: Double, _ rot: Double) -> FlexibleStampPlacement {
            FlexibleStampPlacement(source: .library("fingertip"), widthMM: w, lengthMM: l, rotationDeg: rot, centreU: 10, centreV: 0, weightKg: 5, rigid: false)
        }
        let seeded = stamp(10.8, 14.4, 90)   // E4's seed on Edge 16: the Fingertip, its long side along the edge
        XCTAssertEqual(S.shownTurn(seeded), 0, accuracy: 1e-9, "★ long side along the edge = 0°")
        XCTAssertEqual(S.shownTurn(stamp(10.8, 14.4, 120)), 30, accuracy: 1e-9, "★ turning away counts up")
        XCTAssertEqual(S.shownTurn(stamp(14.4, 10.8, 0)), 0, accuracy: 1e-9, "★ a stamp whose width is its long side: 0° too")
        XCTAssertEqual(S.storedTurn(shown: 30, seeded), 120, accuracy: 1e-9, "★ a typed 30° turns it 30° away from the edge")
        XCTAssertEqual(S.shownTurn(stamp(10.8, 14.4, S.storedTurn(shown: 45, seeded))), 45, accuracy: 1e-9, "★ round trip")
        // the long side really lies along the edge at 0° (the outline's axes: reach along the edge = its long side)
        XCTAssertEqual(S.reachAlong(seeded), 14.4, accuracy: 1e-9, "★ at 0° its reach along the edge is its long side")
        XCTAssertTrue(FlexibleRowCopy.Info.pressStampTurn.contains("long side"))
        S.controlStoredTurn = true
        XCTAssertEqual(S.shownTurn(seeded), 90, "RED CONTROL: E4's box read 90°")
        S.controlStoredTurn = false
    }

    // MARK: - (3) the push follows his drawing (pure, on Edge 16)

    func testThePushFollowsTheDrawnCurveAndTheStamp() async throws {
        let (r, m) = try await F.hisPad(self)
        _ = r
        let e = try await F.edge16(m)
        let st = e.strip, d = try XCTUnwrap(st.halfway)
        let c = FlexibleFlatPrism.cut(st, direction: d, depthMM: 6)
        var p = press(st, d, 6)
        let flat = FlexiblePressPush.samples(p, c)
        XCTAssertGreaterThan(flat.count, 500)
        XCTAssertEqual(flat.weight.min(), 1, "★ never edited: every weight 1 (R7-E3's even push, unchanged)")
        // every sample on a member face, inside the flat prism
        var off = 0.0
        for i in 0..<flat.count {
            let q = SIMD3(flat.xyz[3 * i], flat.xyz[3 * i + 1], flat.xyz[3 * i + 2])
            off = max(off, st.members.map { mb in abs(simd_dot(q - mb.origin, FlexibleFlatPrism.planeNormal(mb)!)) }.min()!)
            XCTAssertLessThanOrEqual(c.height(q), 6 + 1e-6)
        }
        XCTAssertLessThan(off, 1e-6, "★ the samples lie on the part's faces")
        // his first side softer: the across curve 0.2 at a quarter
        B.set(&p, .across, FlexCurve(x: [0, 0.25, 0.5, 0.75, 1], y: [1, 0.2, 1, 1, 1]))
        let drawn = FlexiblePressPush.samples(p, c)
        func meanWeight(_ s: FlexiblePressPush.Samples, member k: Int) -> Double {
            let n = FlexiblePressPush.n
            var sum = 0.0, cnt = 0.0
            for i in 0..<s.count { let j = i % (n + 1); if (k == 0 ? j < n / 2 : j > n / 2) { sum += s.weight[i]; cnt += 1 } }
            return sum / max(1, cnt)
        }
        let w0 = meanWeight(drawn, member: 0), w1 = meanWeight(drawn, member: 1)
        print("FLEX-E5-3 Edge 16 across [1, 0.2, 1, 1, 1]: mean weight first face \(w0) · second \(w1)")
        XCTAssertLessThan(w0, 0.75 * w1, "★ the first face is pressed less where he drew it softer")
        XCTAssertEqual(w1, 1, accuracy: 1e-6, "★ the second face as drawn (straight: full)")
        // the stamp: pressed only under it
        p.settings.shape = "stamp"
        p.settings.designStamp = FlexiblePressStamp.seed(st, c, library: m.library, weightKg: 5)
        let sp = try XCTUnwrap(p.settings.designStamp)
        let st2 = FlexiblePressPush.samples(p, c)
        let under = st2.weight.filter { $0 > 0 }.count
        print("FLEX-E5-3 stamp \(m.stampName(sp)) \(sp.widthMM) × \(sp.lengthMM): \(under) of \(st2.count) samples under it")
        XCTAssertGreaterThan(under, 10)
        XCTAssertLessThan(under, st2.count * 3 / 4, "★ only under the stamp")
        for i in 0..<st2.count where st2.weight[i] > 0 {
            let q = SIMD3(st2.xyz[3 * i], st2.xyz[3 * i + 1], st2.xyz[3 * i + 2])
            XCTAssertTrue(FlexiblePressPush.underStamp(q, st, sp, direction: d))
        }
        // the request carries it (never a job: FlexibleFERequest is the sim's only)
        let sim = FlexibleFERequest.pressSim(id: "group-9", presses: [FlexibleFERequest.PressPush(regions: p.regions, direction: d, weightN: 49,
                                                                                                    pushXYZ: st2.xyz, pushWeight: st2.weight)], voxels: 4)
        XCTAssertEqual(sim.pressed.first?.pushWeight, st2.weight, "★ the bridge request carries the drawn weights")
        FlexiblePressPush.controlEvenPush = true
        XCTAssertEqual(FlexiblePressPush.samples(p, c).weight.min(), 1, "RED CONTROL: R7-E3's even push ignores the stamp")
        FlexiblePressPush.controlEvenPush = false
    }

    // MARK: - (1)(2)(3) on the interim sim: it squishes where he drew; Heat on the footprint; X-ray's bend prism; no job

    func testAnEdgesGroupSquishesWhereHeDrewWearsHeatAndShowsItsBend() async throws {
        let r = try FlexiblePressFixtures.a1Project(3, self, facePrism: true)
        let stage = FlexibleMainStage()
        stage.reduceMotion = { false }
        let m = stage.model(for: r.project, materialsPath: FlexibleHisProject.materialsPath, stampsPath: FlexibleHisProject.stampsPath, persist: {})
        addTeardownBlock { @MainActor in await m.waitForIdle() }
        m.openScene()
        try await FlexibleHisProject.waitFor(120, "A1_0003: the scene") { m.sceneState == .ready }
        try await FlexibleSquishFixture.settle(m, "A1_0003")
        let e16 = try await F.edge16(m)
        let first = try await F.commit(m, e16.c)
        try await FlexibleHisProject.waitFor(240, "the part open again") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        await m.waitForIdle()
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: first.id))
        XCTAssertEqual(g.kind, .edges)
        let pid = first.id
        // his first side softer
        m.setPressCurve(pid, .across, FlexCurve(x: [0, 0.25, 0.5, 0.75, 1], y: [0.15, 0.15, 1, 1, 1]))
        let id = FlexibleSim.groupID(g.number)
        let want = try XCTUnwrap(m.pressSimWants.first { $0.sim.id == id })
        let p0 = try XCTUnwrap(m.press(pid)), cut0 = try XCTUnwrap(m.flatCut(pid))
        XCTAssertEqual(want.presses.first?.pushWeight, FlexiblePressPush.samples(p0, cut0).weight, "★ the sim presses where he drew")
        let lattice = try await FlexibleSquishFixture.build(m, "A1_0003 + Edge 16")
        func jobs() -> [String: String] {
            var out: [String: String] = [:]
            for send in FlexibleAngledGoldens.sends(m) { out[send.title] = (try? m.runJobJSON(resting: Set(send.resting))) ?? "throws" }
            return out
        }
        let jobBefore = jobs()
        try await FlexibleSquishFixture.solve(m, "A1_0003 + Edge 16")
        m.startSquishSims(first: id)
        try await FlexibleHisProject.waitFor(400, "the edges group's sim") { m.squish[id] != nil && m.squish[id] != .pending }
        await m.squishSolver.waitForIdle()
        let field = try XCTUnwrap(m.squish[id]?.field, "★ landed: \(m.squish[id]?.failure ?? "-")")
        XCTAssertEqual(field.generation, lattice.generation)
        let p = try XCTUnwrap(m.press(pid)), cut = try XCTUnwrap(FlexibleFlatPrism.cut(of: p))
        // measured on the footprint where he drew (the push's own samples: a quarter across each face — t 0.1…0.3 on the first, the
        // mirror 0.7…0.9 on the second)
        let probe = FlexiblePressPush.samples(p, cut)
        func sideMoves(_ f: FlexibleFEField) -> [Double] {
            let n = FlexiblePressPush.n
            return [0.1...0.3, 0.7...0.9].map { band in
                var pts: [Float] = []
                for i in 0..<probe.count where band.contains(Double(i % (n + 1)) / Double(n)) {
                    pts += [Float(probe.xyz[3 * i]), Float(probe.xyz[3 * i + 1]), Float(probe.xyz[3 * i + 2])]
                }
                let u = f.meshDisplacements(positions: pts)
                var along = 0.0
                for k in 0..<(u.count / 3) { along += simd_dot(SIMD3<Double>(Double(u[3 * k]), Double(u[3 * k + 1]), Double(u[3 * k + 2])), p.direction) }
                return along / Double(max(1, u.count / 3))
            }
        }
        let drawnMoves = sideMoves(field)

        // (1) HEAT on the footprint — the open group (the Squish page's tap), every vertex by its column, the legend's scale
        m.rail = .group(g.id)
        var shownViews = m.views; shownViews.remove(.heatOff); shownViews.remove(.heatAll); m.views = shownViews   // his Heat tap
        XCTAssertEqual(m.views.heatScope, .group, "premise: Heat shows the open group")
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m, maxEdgeMM: FlexibleSettingsSquish.overlayEdge(model: m)))
        let entries = FlexibleStagePage.pressHeat(model: m, views: m.views)
        XCTAssertEqual(entries.count, 1, "★ the open edges group's press has heat")
        let c = FlexibleStagePage.composeTints(model: m, overlay: overlay)
        let tris = FlexiblePressHeat.footprintTriangles(model: m, overlay: overlay, regions: p.regions)
        XCTAssertFalse(tris.isEmpty, "premise: the footprint is drawn")
        let e = try XCTUnwrap(entries.first)
        XCTAssertEqual(c.heatScaleMM, FlexiblePressHeat.top(entries), accuracy: 1e-9, "★ the legend's top is the press's own (no face heated beside it)")
        var painted = 0, total = 0, wrong = 0
        var shades = Set<Int>()
        let pos = overlay.mesh.flat.positions
        let t8 = try XCTUnwrap(c.tints)
        for t in tris { for j in 0..<3 {
            let v = 3 * t + j
            total += 1
            guard t8[8 * v + 3] > 0, t8[8 * v + 5] == 1 else { continue }
            painted += 1
            let q = SIMD3<Double>(Double(pos[3 * v]), Double(pos[3 * v + 1]), Double(pos[3 * v + 2]))
            if let col = FlexiblePressHeat.column(q, e.stack) {
                let want = FlexibleColours.depth(e.valuesMM[col], max: c.heatScaleMM)
                if SIMD4(t8[8 * v], t8[8 * v + 1], t8[8 * v + 2], t8[8 * v + 3]) != want { wrong += 1 }
                shades.insert(Int((e.valuesMM[col] / max(1e-9, c.heatScaleMM) * 20).rounded()))
            }
        } }
        print("FLEX-E5-1 heat: \(painted)/\(total) footprint vertices painted · \(wrong) off their column's colour · \(shades.count) shades · top \(c.heatScaleMM) mm")
        XCTAssertGreaterThan(Double(painted), 0.9 * Double(total), "★ the footprint wears the heat")
        XCTAssertEqual(wrong, 0, "★ every vertex by its own column on the legend's scale")
        XCTAssertGreaterThan(shades.count, 2, "★ graded, not one colour")
        XCTAssertTrue(FlexibleStagePage.heatDrawn(model: m, views: m.views), "★ the legend's heat rows show")
        // follows the group: a face group open → no heat on the edge's footprint
        if let fg = m.squeezeGroups.first(where: { $0.kind == .faces }) {
            m.rail = .group(fg.id)
            XCTAssertTrue(FlexibleStagePage.pressHeat(model: m, views: m.views).isEmpty, "★ heat follows the open group")
            m.rail = .group(g.id)
        }
        var hold = m.views; hold.heatHeld()
        XCTAssertEqual(FlexibleStagePage.pressHeat(model: m, views: hold).count, 1, "★ the 3-second hold: every group's")
        // the Lattice page's selector
        stage.pick(id)
        XCTAssertEqual(stage.mainPressHeatGroups, [g.number], "★ the Lattice page's heat follows the selector")
        FlexiblePressHeat.controlNoPressHeat = true
        let red = FlexibleStagePage.composeTints(model: m, overlay: overlay)
        let redPainted = tris.reduce(0) { n, t in n + (0..<3).filter { red.tints![8 * (3 * t + $0) + 5] == 1 }.count }
        XCTAssertEqual(redPainted, 0, "RED CONTROL: R7-E3's edges group wore no heat")
        XCTAssertFalse(FlexibleStagePage.heatDrawn(model: m, views: m.views), "RED CONTROL: no heat rows")
        FlexiblePressHeat.controlNoPressHeat = false

        // (2) X-RAY: the bend as a prism into the model — the footprint at rest and moved along the arrow
        var cache: (key: String, dents: [Float])?
        let sq = FlexibleSettingsSquish.shown(model: m, overlay: overlay, channels: c, feCache: &cache)
        XCTAssertTrue(sq.fe, "premise: the open edges group plays its field")
        let item = try XCTUnwrap(FlexibleBendPrism.item(model: m, overlay: overlay, dents: sq.dents, k: sq.exaggeration), "★ an edges group's bend prism")
        guard case .shell(let sh) = item.volume.shape else { return XCTFail("a shell") }
        var along = 0.0, mag = 0.0
        for i in sh.base.indices {
            let w = SIMD3<Double>(sh.offset[i] - sh.base[i])
            along += simd_dot(w, p.direction); mag += simd_length(w)
        }
        print("FLEX-E5-2 X-ray prism: \(sh.base.count) corners · deepest \(sh.reachedDepthMM) mm · along/|w| \(along / max(1e-12, mag))")
        XCTAssertGreaterThan(sh.reachedDepthMM, 0)
        XCTAssertGreaterThan(along, 0.5 * mag, "★ the wedge runs along the arrow, into the model")
        FlexibleBendPrism.controlNoEdges = true
        XCTAssertNil(FlexibleBendPrism.item(model: m, overlay: overlay, dents: sq.dents, k: sq.exaggeration), "RED CONTROL: R7-E3's guard, no prism")
        FlexibleBendPrism.controlNoEdges = false

        // (3) PLAY FOLLOWS THE DRAWING: the even push (RED CONTROL) solved for comparison — the softer side moves less, relatively
        let serial = field.serial
        FlexiblePressPush.controlEvenPush = true
        m.startPressSims()
        try await FlexibleHisProject.waitFor(400, "the even push's sim") { m.squish[id]?.field.map { $0.serial != serial } ?? false }
        await m.squishSolver.waitForIdle()
        let even = try XCTUnwrap(m.squish[id]?.field)
        FlexiblePressPush.controlEvenPush = false
        let evenMoves = sideMoves(even)
        let rDrawn = drawnMoves[0] / max(1e-12, drawnMoves[1]), rEven = evenMoves[0] / max(1e-12, evenMoves[1])
        print("FLEX-E5-3 sim: drawn (first face 0.15 out to a quarter) moves \(drawnMoves) ratio \(rDrawn) · RED CONTROL even push \(evenMoves) ratio \(rEven)")
        XCTAssertLessThan(rDrawn, 0.8 * rEven, "★ the first face (drawn softer) squishes relatively less than under the even push")

        // never a job
        XCTAssertTrue(m.sentPresses.isEmpty, "★ no press sent")
        XCTAssertEqual(jobs(), jobBefore, "★ every send's job bytes unchanged")
        XCTAssertEqual(m.notTunedLine(simID: id), FlexibleRowCopy.latticeNotTunedForPress, "★ the chip still says it")
    }
}
