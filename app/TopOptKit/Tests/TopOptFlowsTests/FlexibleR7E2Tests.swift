// FlexibleR7E2Tests — round 7, batch R7-E2: the edge/corner FLAT PRISM SENT TO CORE. Written FIRST, against stubs (red run:
// round7/batch_e2/e2_red_run.txt); each RED CONTROL runs inside its test.
// The reviewer's ruling (angled presses, 2026-10-07 — binding): "Never write a job core refuses. Angled presses go into the job
// only once core's schema accepts them (probe-gated)"; "Under an angled press, the preview lattice is graded by that press's own
// design along the arrow, and blended into the neighbouring faces' lattices by core's conflict rule"; the test "after it: a
// cube-corner press's frame, columns and exit links match core's to the bit"; "every existing face press is unchanged: job
// bytes and stage hashes identical"; the rim ruling's first test ("on the cube edge and the cube corner, the default press has 0
// beyond-data columns"). The A3 refusal in plain words (2026-10-10 19:40); one group per export, said first (M1 ruling 4).
// His answer (2026-10-18 ~16:50): "CORE: do NOT ask #361 yet … ship the twist with its honest line saying how close core's
// profile is."
//   E2-1 the press is a design target through its synthetic key (FlexibleSquishTarget)
//   E2-2 the default map is the flat prism in core's numbers (FlexiblePressShape), the across axis read from core's frame
//   E2-3 a twist says how far off core's profile is
//   E2-4 a press is sent only when core takes it (FlexiblePressSupport's gate) — the entry's bits
//   E2-5 the cube corner's (and his pad's corner's) frame, columns and exit links match core's run to the bit
//   E2-6 shared_footprint in plain words, with 1–3 fixes; the app's pre-check stops the send
//   E2-7 the lattice is graded along the arrow (core's field with the press key)
//   E2-8 the rim default: 0 beyond-data columns on the cube edge and corner
//   E2-9 one group per export, said first; step ② names the edges group
//   E2-10 face presses unchanged; with presses only the appended entries
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleR7E2Tests: XCTestCase {
    typealias F = FlexibleFlatPrismFixtures
    typealias G = FlexibleAngledGoldens
    typealias S = FlexiblePressShape

    override func tearDown() {
        FlexiblePressShape.controlAcrossIsY = false
        FlexiblePressShape.controlSilent = false
        FlexibleJob.controlPressAsFaces = false
        FlexibleStageModel.controlStripPresses = false
        FlexibleStageModel.controlHoldIgnoresPresses = false
        FlexiblePressSupport.apiVersion = { FlexibleScene.pressApiVersion }
        FlexibleCore.controlNoRunStacks = false
        super.tearDown()
    }

    // MARK: - fixtures

    /// Wait until core's gate has a settled verdict on press `id` (in the job, or a reason that is not "still designing").
    @discardableResult
    func settled(_ m: FlexibleStageModel, _ id: UUID, _ what: String, timeout: Double = 180) async throws -> FlexiblePressSupport.Verdict {
        try await FlexibleHisProject.waitFor(timeout, "\(what): core's verdict") {
            guard let v = m.pressSupport[id] else { return false }
            if v.inJob { return true }
            switch v.reason {
            case .designing?, .notStacked("")?, nil: return false
            default: return true
            }
        }
        await m.waitForIdle()
        return try XCTUnwrap(m.pressSupport[id])
    }

    /// Wait until the press is registered under a key other than `old` and core's design on it is in.
    func redesigned(_ m: FlexibleStageModel, _ id: UUID, from old: Int?, _ what: String) async throws -> Int {
        try await FlexibleHisProject.waitFor(180, "\(what): registered again and designed") {
            guard let k = m.pressKey(id), k != old else { return false }
            return m.pressDesign(id) != nil
        }
        await m.waitForIdle()
        return try XCTUnwrap(m.pressKey(id))
    }

    /// His pad (A1_0003 + the Top's 20 mm face-prism), with `rest` faces resting first; Edge 16 (Face 3 + Face 2) picked at 5 kg.
    func padEdge16(rest: [Int] = []) async throws -> (FlexibleHisProject.Restored, FlexibleStageModel, FlexiblePress) {
        let (r, m) = try await F.hisPad(self)
        for f in rest { m.rest(f) }
        if !rest.isEmpty { try await FlexibleSquishFixture.settle(m, "his pad, \(rest) resting") }
        let press = try await F.commit(m, try await F.edge16(m).c, kg: 5)
        return (r, m, press)
    }

    /// The cube's corner whose members are its +X, +Y, +Z faces (its halfway along −(1, 1, 1)/√3).
    func cubeCorner(_ m: FlexibleStageModel) async throws -> FlexibleEdgeCandidates.Candidate {
        let pick = try await F.M2.pickMode(m)
        let mesh = try XCTUnwrap(m.project.viewerMesh)
        let s = FlexiblePressFixtures.cubeSideMM
        func faceAt(_ axis: Int) -> Int { FlexibleSquishFixture.face(mesh, axis: axis, value: Float(s)) }
        let want: Set<Int> = [faceAt(0), faceAt(1), faceAt(2)]
        return try XCTUnwrap(F.corner(m, pick, faces: want), "the cube's +X +Y +Z corner")
    }

    static func a(_ d: Double) -> String { String(format: "%a", d) }
    static func a3(_ v: SIMD3<Double>) -> String { "\(a(v.x)) \(a(v.y)) \(a(v.z))" }
    static func bits(_ v: SIMD3<Double>) -> [UInt64] { [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }
    static func angleDeg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(Swift.max(-1, Swift.min(1, simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi
    }

    /// ★ THE BIT DUMP the ruling's test compares: core's frame, every column (u, v, entry_t, exit_t, lattice_mm, exit_face) and the
    /// exit links, each Double as %a.
    static func dump(_ s: FlexStackInfo, perturbEntry: Bool = false) -> String {
        var out = ["frame load \(a3(s.load)) x \(a3(s.xAxis)) y \(a3(s.yAxis)) centroid \(a3(s.centroid))",
                   "uv min \(a(s.uMin)) \(a(s.vMin)) extent \(a(s.uExtentMM)) \(a(s.vExtentMM)) area \(a(s.areaMM2)) projected \(a(s.projectedAreaMM2))",
                   "build \(a(s.buildAngleDeg)) side \(s.side) tied \(s.principalAxisTied) pitch \(a(s.pitchMM)) grid \(s.nu)x\(s.nv) footprint \(s.footprintRegionIDs)"]
        for (k, c) in s.columns.enumerated() {
            let e = perturbEntry && k == s.columns.count / 2 ? c.entryT.nextUp : c.entryT
            out.append("col \(c.iu) \(c.iv) u \(a(c.uMM)) v \(a(c.vMM)) entry \(a(e)) exit \(a(c.exitT)) lattice \(a(c.latticeMM)) exitFace \(c.exitFace)")
        }
        for l in s.exitFaces { out.append("exit face \(l.id) \(a(l.fraction))") }
        out.append("exit unresolved \(a(s.exitUnresolvedFraction))")
        return out.joined(separator: "\n")
    }

    /// The columns at the footprint's rim (a missing neighbour in core's column grid).
    static func rim(_ st: FlexStackInfo) -> [Int] {
        st.columns.indices.filter { k in
            let c = st.columns[k]
            return [(1, 0), (-1, 0), (0, 1), (0, -1)].contains { st.column(c.iu + $0.0, c.iv + $0.1) < 0 }
        }
    }

    // MARK: - E2-1

    /// The press is a DESIGN TARGET through its synthetic key: target(key) is the press's settings (faceRegionID = key), key(key)
    /// works, setTarget routes through setPress (regions[0] restored); the design pipeline designs Edge 16 on CORE's press stack —
    /// designs[key] exists, its columns are the press stack's, its S is core's squish_fraction of the press's map. RED CONTROL: the
    /// first member's own key designs along its face's normal, 45° off the arrow.
    func testAPressIsADesignTarget() async throws {
        let (_, m, press) = try await padEdge16()
        try await settled(m, press.id, "Edge 16")
        let key = try XCTUnwrap(m.pressKey(press.id), "registered")
        let k = FlexFaceKey(region: key, rotation: 0)
        XCTAssertEqual(m.pressDesignKey(press.id), k, "★ its design key is its synthetic key")
        XCTAssertEqual(m.key(key), k, "★ key(r) works for a synthetic id")
        XCTAssertEqual(m.pressID(forKey: key), press.id)
        let t = try XCTUnwrap(m.target(key), "★ target(synthetic) is the press")
        XCTAssertEqual(t.faceRegionID, key, "★ … with faceRegionID = the key")
        XCTAssertEqual(t.weightKg, press.settings.weightKg)
        XCTAssertEqual(t.deepestMM, press.settings.deepestMM)
        XCTAssertEqual(m.target(1), m.settings.face(1), "a face's target is its own settings")
        let d = try XCTUnwrap(m.designs[k], "★ designs[key] exists")
        let st = try XCTUnwrap(m.pressStack(press.id))
        XCTAssertNil(d.refusal)
        XCTAssertEqual(d.columns.count, st.columns.count, "★ designed on core's press stack (its columns)")
        let map = try XCTUnwrap(m.pressMap(press.id))
        let coreS = try await m.frameWorker.withScene { try $0.squishFraction(face: key, rotation: 0, map: map) }
        XCTAssertEqual(d.columns.map(\.s), coreS, "★ its S is core's squish_fraction of the press's map")
        // ★ the arrow is core's load on that stack; the first member's own stack (RED CONTROL) is along its face, 45° off
        let unit = try XCTUnwrap(FlexiblePressAim.unit(press.direction))
        let member = try await m.frameWorker.withScene { try $0.stack(face: press.regions[0], rotation: 0) }
        func alongArrow(_ load: SIMD3<Double>) -> Bool { Self.bits(load) == Self.bits(unit) }
        print("FLEX-E2-1 Edge 16 key \(key) · columns \(st.columns.count) · press load \(st.load) · first member's \(member.load) (\(Self.angleDeg(member.load, unit))°)")
        XCTAssertTrue(alongArrow(st.load), "★ designed along the arrow")
        XCTAssertFalse(alongArrow(member.load), "★ RED CONTROL: the first member's key is along its face's normal")
        XCTAssertEqual(Self.angleDeg(member.load, unit), 45, accuracy: 1e-6, "RED CONTROL: 45° off on a box edge")
        // setTarget: a press through setPress, its regions[0] restored
        var t2 = t
        t2.weightKg = 7
        m.setTarget(t2)
        let after = try XCTUnwrap(m.press(press.id))
        XCTAssertEqual(after.settings.weightKg, 7, "★ setTarget stores the press's settings")
        XCTAssertEqual(after.settings.faceRegionID, press.regions[0], "★ … with its regions[0] restored")
        XCTAssertEqual(after.regions, press.regions)
    }

    // MARK: - E2-2 + E2-3

    /// The default map IS the flat prism in core's numbers: per core column, core's S·h vs δ_k = (t_A + h) − entry_t_k. Untwisted
    /// Edge 16 at h = 6 and h = 14 (core's X flips from along to across): within 2 % of h; the rim's columns follow the flat prism
    /// to its 0 (|S − δ/h| ≤ 0.02). The cube corner at halfway, centre_edge: within one pitch over h. RED CONTROL: X assumed along
    /// the edge — at h = 14 the tent lies along the 20 mm edge.
    func testTheDefaultMapIsTheFlatPrismInCoresNumbers() async throws {
        let (_, m, press) = try await padEdge16()
        try await settled(m, press.id, "Edge 16")
        var key: Int? = nil
        for (h, across) in [(6.0, false), (14.0, true)] {
            let old = m.pressKey(press.id)
            let why = await m.setFlatCut(press.id, depthMM: h, direction: press.direction, snap: press.snap)
            XCTAssertNil(why, "Edge 16 at \(h) mm")
            key = try await redesigned(m, press.id, from: old, "h \(h)")   // (a re-cut opens a new scene: a new key, never reused)
            let k = try XCTUnwrap(key)
            let st = try XCTUnwrap(m.pressStack(press.id)), apexT = try XCTUnwrap(m.pressRegistrations[press.id]?.apexT)
            let shape = try XCTUnwrap(m.pressShape(press.id))
            XCTAssertEqual(S.acrossIsX(st, shape), across, "★ h \(h): the across axis is core's \(across ? "X" : "Y") (u \(st.uExtentMM) × v \(st.vExtentMM))")
            let map = try XCTUnwrap(m.pressMap(press.id))
            XCTAssertEqual(map.mode, "both")
            for c in [map.x, map.y] { XCTAssertEqual(FlexibleCore.penCurveError(x: c.x, y: c.y), "", "★ core's pen-curve rules hold") }
            let coreS = try await m.frameWorker.withScene { try $0.squishFraction(face: k, rotation: 0, map: map) }
            let delta = S.delta(st, apexT: apexT, depthMM: h)
            let off = S.offPercent(s: coreS, delta: delta, depthMM: h)
            let rimWorst = Self.rim(st).map { Swift.abs(coreS[$0] - delta[$0] / h) }.max() ?? 0
            print("FLEX-E2-2 Edge 16 h \(h): across \(across ? "X" : "Y") · u \(st.uExtentMM) v \(st.vExtentMM) · columns \(st.columns.count) · off \(off)% · rim |S − δ/h| ≤ \(rimWorst)")
            XCTAssertLessThanOrEqual(off, 2, "★ h \(h): core's S·h within 2 % of the flat prism")
            XCTAssertLessThanOrEqual(rimWorst, 0.02, "★ h \(h): the rim follows the flat prism to 0")
            if h == 14 {
                // ★ RED CONTROL: X assumed along the edge
                S.controlAcrossIsY = true
                let wrong = S.map(st, apexT: apexT, depthMM: h, press: shape)
                S.controlAcrossIsY = false
                let wrongS = try await m.frameWorker.withScene { try $0.squishFraction(face: k, rotation: 0, map: wrong) }
                let wrongOff = S.offPercent(s: wrongS, delta: delta, depthMM: h)
                print("FLEX-E2-2 RED CONTROL h 14, X assumed along the edge: off \(wrongOff)%")
                XCTAssertGreaterThan(wrongOff, 2, "★ RED CONTROL: the tent along the 20 mm edge is far off")
            }
        }
        // the cube's corner at halfway: centre_edge, within one pitch over h
        let (_, cm) = try await F.cube(self)
        let corner = try await F.commit(cm, try await cubeCorner(cm))
        let old = cm.pressKey(corner.id)
        _ = await cm.setFlatCut(corner.id, depthMM: 10, direction: corner.direction, snap: corner.snap)
        let ck = try await redesigned(cm, corner.id, from: old, "the cube corner at 10 mm")
        let st = try XCTUnwrap(cm.pressStack(corner.id)), apexT = try XCTUnwrap(cm.pressRegistrations[corner.id]?.apexT)
        let map = try XCTUnwrap(cm.pressMap(corner.id))
        XCTAssertEqual(map.mode, "centre_edge", "★ a corner: core's centre_edge")
        XCTAssertEqual(map.centreEdge, FlexCurve(x: [0, 1], y: [0, 1]), "★ C = [(0, 0), (1, 1)]")
        let coreS = try await cm.frameWorker.withScene { try $0.squishFraction(face: ck, rotation: 0, map: map) }
        let off = S.offPercent(s: coreS, delta: S.delta(st, apexT: apexT, depthMM: 10), depthMM: 10)
        print("FLEX-E2-2 cube corner h 10: columns \(st.columns.count) · pitch \(st.pitchMM) · off \(off)% (one pitch / h = \(100 * st.pitchMM / 10)%) · halfway \(corner.direction)")
        XCTAssertLessThanOrEqual(off, 100 * st.pitchMM / 10, "★ within one pitch over h")
        XCTAssertEqual(Self.angleDeg(corner.direction, -SIMD3(1, 1, 1)), 0, accuracy: 1e-9, "premise: along −(1, 1, 1)/√3")
    }

    /// A TWIST says how far off core's profile is: Edge 16 at 10.6 mm twisted 15° — "Twisted · squish shape up to N% off", N from
    /// core's columns (the design's S vs δ_k); untwisted, no twist line. RED CONTROL: silent.
    func testATwistSaysHowFarOff() async throws {
        let (_, m, press) = try await padEdge16()
        try await settled(m, press.id, "Edge 16")
        var old = m.pressKey(press.id)
        let at10 = await m.setFlatCut(press.id, depthMM: 10.6, direction: press.direction, snap: press.snap)
        XCTAssertNil(at10)
        _ = try await redesigned(m, press.id, from: old, "10.6 mm")
        let untwisted = m.pressWarning(press.id)?.line
        print("FLEX-E2-3 untwisted: '\(untwisted ?? "-")' · off \(m.pressOffPercent(press.id) ?? -1)%")
        XCTAssertFalse(untwisted?.hasPrefix("Twisted") ?? false, "★ untwisted: no twist line")
        old = m.pressKey(press.id)
        let tw = await m.setFlatAngle(press.id, degrees: 15, tilt: false)
        XCTAssertNil(tw, "a typed twist of 15°")
        _ = try await redesigned(m, press.id, from: old, "twisted 15°")
        let p = try XCTUnwrap(m.press(press.id))
        let f = try XCTUnwrap(FlexibleFlatPrismUI.frame(m, press.id))
        let phi = FlexibleFlatPrismAngles.decompose(f, p.direction).phi
        print("FLEX-E2-3 typed 15° → stored twist \(phi)° (\(m.lastFlatStop?.line ?? "no stop"))")
        XCTAssertGreaterThanOrEqual(phi, 5, "premise: twisted (15° typed; the lattice may land it short, said)")
        let shape = try XCTUnwrap(m.pressShape(press.id))
        XCTAssertTrue(S.twisted(shape), "★ core's t of the two ends differ")
        let d = try XCTUnwrap(m.pressDesign(press.id))
        let st = try XCTUnwrap(m.pressStack(press.id)), apexT = try XCTUnwrap(m.pressRegistrations[press.id]?.apexT)
        let h = try XCTUnwrap(FlexibleFlatPrism.depth(of: p))
        let n = S.offPercent(s: d.columns.map(\.s), delta: S.delta(st, apexT: apexT, depthMM: h), depthMM: h)
        XCTAssertEqual(m.pressOffPercent(press.id) ?? -1, n, accuracy: 1e-9, "★ N from core's columns")
        let line = m.pressWarning(press.id)?.line
        print("FLEX-E2-3 twisted 15°: '\(line ?? "-")' · N \(n)% · map \(m.pressMap(press.id).map { "\($0.mode) x \($0.x.y.count) pts y \($0.y.y.count) pts" } ?? "-")")
        XCTAssertGreaterThan(n, S.warnPercent, "premise: a 15° twist is more than 2 % off a product map")
        XCTAssertEqual(line, FlexibleRowCopy.twistOff(n), "★ the card says how far off: '\(FlexibleRowCopy.twistOff(n))'")
        XCTAssertLessThanOrEqual(line?.count ?? 99, 44)
        // ★ RED CONTROL: silent
        S.controlSilent = true
        let silent = m.pressWarning(press.id)?.line
        S.controlSilent = false
        XCTAssertFalse(silent?.hasPrefix("Twisted") ?? false, "★ RED CONTROL: a silent twist says nothing of its shape")
    }

    // MARK: - E2-4

    /// A press is SENT ONLY WHEN CORE TAKES IT. The gate as a pure function: every condition set false keeps the press out, each
    /// with its own line (≤ 44). On his pad: Edge 16 in the job; the edges group's send writes ONE loaded entry AFTER the face
    /// entries — face_region_ids = its pieces in member order, press_direction = its bits, deepest = h, mode/curves = the design's
    /// map — and core's own parser reads it back so. RED CONTROLS: (1) an API stub returning 1 closes the gate; (2) an encoder that
    /// writes the pieces as plain face entries.
    func testAPressIsSentOnlyWhenCoreTakesIt() async throws {
        // the pure gate
        let pid = UUID()
        let all = FlexiblePressSupport.Facts(schema: true, bridge: true, api: 2, stacked: nil, twoEntries: nil, shared: nil,
                                             designed: true, designRefusal: nil, conflict: nil)
        XCTAssertTrue(FlexiblePressSupport.verdict(all).inJob, "★ everything holds: in the job")
        let shared = FlexibleSharedFootprint(press: pid, pressName: "Edge 16", otherRegion: 3, otherPress: nil, otherName: "Face 3", mm2: 84.85)
        let cases: [(String, FlexiblePressSupport.Facts)] = [
            ("schema", { var f = all; f.schema = false; return f }()),
            ("bridge", { var f = all; f.bridge = false; return f }()),
            ("api 1", { var f = all; f.api = 1; return f }()),
            ("not stacked", { var f = all; f.stacked = "Edge 16 · arrow doesn't push into Face 3"; return f }()),
            ("two entries", { var f = all; f.twoEntries = FlexibleRowCopy.pressTwoEntries("Face 3"); return f }()),
            ("shared", { var f = all; f.shared = shared; return f }()),
            ("designing", { var f = all; f.designed = false; return f }()),
            ("refused", { var f = all; f.designed = false; f.designRefusal = FlexibleRowCopy.pressNotDesigned("no squish data"); return f }()),
            ("conflict", { var f = all; f.conflict = FlexibleRowCopy.pressConflict("Edge 16", "Edge 18"); return f }()),
        ]
        var lines = Set<String>()
        for (what, f) in cases {
            let v = FlexiblePressSupport.verdict(f)
            print("FLEX-E2-4 gate \(what): inJob \(v.inJob) · '\(v.line ?? "-")'")
            XCTAssertFalse(v.inJob, "★ \(what) false keeps the press out")
            let line = try XCTUnwrap(v.line, "\(what): its line")
            XCTAssertLessThanOrEqual(line.count, 44)
            if !["schema", "bridge", "api 1"].contains(what) { XCTAssertTrue(lines.insert(line).inserted, "\(what): its own line") }
        }
        XCTAssertEqual(FlexiblePressSupport.verdict(cases[0].1).line, FlexibleRowCopy.pressNotSent, "core's side closed: 'Set up · core support pending'")
        XCTAssertEqual(FlexiblePressSupport.verdict(cases[5].1).line, "Edge 16 and Face 3 share 85 mm\u{00B2}")
        XCTAssertTrue(FlexiblePressSupport.schemaTakesPresses(), "★ core's schema takes face_region_ids + press_direction (the probe, its control parsing)")

        // his pad: rest Groups 2 and 3 so the job's one group is the edges group alone
        let (r, m, press) = try await padEdge16(rest: [2, 3, 4, 5])
        let v = try await settled(m, press.id, "Edge 16")
        XCTAssertTrue(v.inJob, "★ Edge 16 is in the job: \(v.line ?? "")")
        XCTAssertTrue(m.sentPresses.contains(press.id))
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: press.id))
        XCTAssertTrue(m.sentSqueezeGroups.contains { $0.id == g.id }, "★ its group is sent")
        let hold = try XCTUnwrap(m.coreHold, "Group 1 (the Top) beside the edges group: one group per export")
        let send = try XCTUnwrap(hold.fixes.first { $0.scope == "Group \(g.number) only" }, "a send of the edges group alone")
        let job = try m.runJobJSON(resting: Set(send.resting))
        let block = try FlexibleCore.parseJobBlock(job)
        let loaded = block.faces.filter { $0.role == "loaded" }
        XCTAssertEqual(loaded.count, 1, "★ one loaded entry: the press")
        let e = try XCTUnwrap(block.faces.last)
        XCTAssertEqual(e.footprintRegionIDs, press.regions.isEmpty ? [] : try XCTUnwrap(m.press(press.id)).regions, "★ face_region_ids = its pieces in member order")
        XCTAssertEqual(e.faceRegionID, try XCTUnwrap(m.press(press.id)).regions.first)
        let pd = try XCTUnwrap(e.pressDirection, "★ press_direction stated")
        XCTAssertEqual(Self.bits(pd), Self.bits(try XCTUnwrap(m.press(press.id)).direction), "★ its bits, through core's own parser")
        XCTAssertEqual(e.deepestMM, try XCTUnwrap(m.press(press.id)).settings.deepestMM, "★ deepest = h")
        let map = try XCTUnwrap(m.pressMap(press.id))
        XCTAssertEqual(e.map.mode, map.mode, "★ the design's map")
        XCTAssertEqual(e.map.x, map.x)
        XCTAssertEqual(e.map.y, map.y)
        XCTAssertEqual(e.weightN, try XCTUnwrap(m.press(press.id)).settings.weightN, accuracy: 1e-12)
        // the face entries come first, the press last
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(job.utf8)) as? [String: Any])
        let faces = try XCTUnwrap((obj["flexible"] as? [String: Any])?["faces"] as? [[String: Any]])
        XCTAssertNotNil(faces.last?["face_region_ids"], "★ the press entry is written after the face entries")
        XCTAssertTrue(faces.dropLast().allSatisfy { $0["face_region_ids"] == nil && $0["press_direction"] == nil }, "★ every other entry is a face's")
        print("FLEX-E2-4 his pad, Edge 16 sent: entries \(faces.count) · press \(e.footprintRegionIDs) dir \(pd) h \(e.deepestMM) mode \(e.map.mode)")
        _ = r
        // ★ RED CONTROL (1): core's press API answered 1 — the gate closes
        FlexiblePressSupport.apiVersion = { 1 }
        m.pressSupportMemo = nil
        let closed = m.pressSupport[press.id]
        FlexiblePressSupport.apiVersion = { FlexibleScene.pressApiVersion }
        m.pressSupportMemo = nil
        print("FLEX-E2-4 RED CONTROL api 1: inJob \(closed?.inJob ?? true) · '\(closed?.line ?? "-")'")
        XCTAssertEqual(closed?.inJob, false, "★ RED CONTROL: an API of 1 keeps the press out")
        XCTAssertEqual(closed?.line, FlexibleRowCopy.pressNotSent)
        // ★ RED CONTROL (2): an encoder writing the pieces as plain face entries
        FlexibleJob.controlPressAsFaces = true
        let plain = try m.runJobJSON(resting: Set(send.resting))
        FlexibleJob.controlPressAsFaces = false
        let pb = try FlexibleCore.parseJobBlock(plain)
        print("FLEX-E2-4 RED CONTROL pieces as faces: \(pb.faces.map { "\($0.faceRegionID)\($0.footprintRegionIDs.isEmpty ? "" : " \($0.footprintRegionIDs)")" })")
        XCTAssertFalse(pb.faces.contains { !$0.footprintRegionIDs.isEmpty || $0.pressDirection != nil },
                       "★ RED CONTROL: the plain encoder states no footprint and no direction — core would press each piece along its own face")
    }

    // MARK: - E2-5

    /// ★ THE RULING'S TEST: "after it: a cube-corner press's frame, columns and exit links match core's to the bit." The cube's
    /// corner along −(1, 1, 1)/√3, and his pad's Top corner (Faces 1 + 2 + 3): a %a dump of the press stack the app reads (core's,
    /// through its synthetic key on the open scene) equals the stack core's own RUN built from the job's entry (A5). RED
    /// CONTROLS: the same press stated with its direction one ulp off differs; the comparison catches one column's entry + 1 ulp.
    func testCubeCornerFrameColumnsAndExitLinksMatchCoreToTheBit() async throws {
        for which in ["cube", "his pad"] {
            let m: FlexibleStageModel
            let c: FlexibleEdgeCandidates.Candidate
            if which == "cube" {
                m = try await F.cube(self).1
                c = try await cubeCorner(m)
            } else {
                let (_, pm) = try await F.hisPad(self)
                for f in [2, 3, 4, 5] { pm.rest(f) }
                try await FlexibleSquishFixture.settle(pm, "his pad, 2–5 resting")
                m = pm
                let pick = try await F.M2.pickMode(m)
                c = try XCTUnwrap(F.corner(m, pick, faces: [1, 2, 3]), "his Top corner: Faces 1 + 2 + 3")
            }
            let press = try await F.commit(m, c)
            let v = try await settled(m, press.id, which)
            XCTAssertTrue(v.inJob, "\(which): the corner is in the job (\(v.line ?? ""))")
            let key = try XCTUnwrap(m.pressKey(press.id))
            let mine = try await m.frameWorker.withScene { try $0.stack(face: key, rotation: 0) }
            let resting = m.coreHold?.fixes.first { f in
                guard let g = m.squeezeGroup(ofPress: press.id) else { return false }
                return f.scope == "Group \(g.number) only"
            }?.resting ?? []
            let job = try m.runJobJSON(resting: Set(resting))
            let file = try XCTUnwrap(m.project.importedFile)
            let dir = (file.path as NSString).deletingLastPathComponent
            let out = FileManager.default.temporaryDirectory.appendingPathComponent("flex-e2-bit-\(UUID().uuidString)").path
            addTeardownBlock { try? FileManager.default.removeItem(atPath: out) }
            let run = try FlexibleCore.runJob(jobJSON: job, jobDir: dir, outDir: out, materialsPath: FlexibleHisProject.materialsPath, fingerprint: "e2")
            XCTAssertNil(run.refusal, "\(which): core ran it (\(run.refusal?.reason ?? ""))")
            let regs = try XCTUnwrap(m.press(press.id)).regions
            let theirs = try XCTUnwrap(run.stacks.first { $0.footprintRegionIDs == regs }, "★ \(which): the run's press stack (A5)")
            let a = Self.dump(mine), b = Self.dump(theirs)
            let differ = zip(a.components(separatedBy: "\n"), b.components(separatedBy: "\n")).filter { $0 != $1 }.count
            print("FLEX-E2-5 \(which) corner: columns \(mine.columns.count) / \(theirs.columns.count) · dump \(a.utf8.count) bytes · lines differing \(differ) · load \(Self.a3(mine.load)) · exits \(mine.exitFaces.map(\.id))")
            XCTAssertEqual(a, b, "★ \(which): frame, columns and exit links match core's run to the bit")
            // ★ RED CONTROL: the comparison sees one column's entry + 1 ulp
            XCTAssertNotEqual(Self.dump(mine, perturbEntry: true), b, "★ RED CONTROL: entry_t + 1 ulp is caught")
            // ★ RED CONTROL: the same press with its direction one ulp off — core builds another stack
            var objc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(job.utf8)) as? [String: Any])
            var flex = try XCTUnwrap(objc["flexible"] as? [String: Any])
            var faces = try XCTUnwrap(flex["faces"] as? [[String: Any]])
            let idx = try XCTUnwrap(faces.firstIndex { $0["press_direction"] != nil })
            let d = try XCTUnwrap(m.press(press.id)).direction
            faces[idx]["press_direction"] = [d.x.nextUp, d.y, d.z]
            flex["faces"] = faces
            objc["flexible"] = flex
            let off = String(decoding: try JSONSerialization.data(withJSONObject: objc, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)
            let run2 = try FlexibleCore.runJob(jobJSON: off, jobDir: dir, outDir: out + "-ulp", materialsPath: FlexibleHisProject.materialsPath, fingerprint: "e2")
            addTeardownBlock { try? FileManager.default.removeItem(atPath: out + "-ulp") }
            let other = try XCTUnwrap(run2.stacks.first { $0.footprintRegionIDs == theirs.footprintRegionIDs })
            print("FLEX-E2-5 \(which) RED CONTROL direction x + 1 ulp: dump differs \(Self.dump(other) != a)")
            XCTAssertNotEqual(Self.dump(other), a, "★ RED CONTROL: the direction one ulp off is another stack")
        }
    }

    // MARK: - E2-6

    /// ★ shared_footprint IN PLAIN WORDS (the reviewer's ruling 2026-10-10 19:40): Edge 16 beside Face 3 pressed WHOLE (its strip
    /// piece lies on Face 3): the app's pre-check keeps Edge 16 out of the job — "Edge 16 and Face 3 share 85 mm²" (≤ 44) with 1–3
    /// fixes, each ONE undo step that lets it back in; core's own refusal of a job carrying both (code shared_footprint) reads the
    /// same. RED CONTROL: core's raw sentence ("presses … share surface (face region …") behind "Core refused it".
    func testSharedFootprintInPlainWords() async throws {
        let (r, m, press) = try await padEdge16(rest: [2, 3, 4, 5])
        let v0 = try await settled(m, press.id, "Edge 16")
        XCTAssertTrue(v0.inJob, "premise: Edge 16 in the job")
        let label = try XCTUnwrap(press.strip?.label)
        // Face 3 pressed whole again (a stale project: its own sector, Edge 16's piece, inside it)
        m.edit { s in var f = FlexibleFaceSettings(faceRegionID: 3); f.weightKg = 5; s.setFace(f) }
        try await FlexibleHisProject.waitFor(60, "the pre-check") { m.pressSupport[press.id]?.inJob == false }
        let v = try XCTUnwrap(m.pressSupport[press.id])
        guard case .shared(let sh)? = v.reason else { return XCTFail("★ the shared surface keeps it out: \(String(describing: v.reason))") }
        let piece = try XCTUnwrap(m.press(press.id)?.regions.first { m.regions.faces(of: $0, mesh: m.project.viewerMesh) == [3] })
        let area = F.M2.area(m, piece, face: 3)
        print("FLEX-E2-6 shared: '\(v.line ?? "-")' · \(sh.mm2) mm² (Edge 16's piece on Face 3: \(area)) · fixes \(m.pressWarning(press.id)?.fixes.map(\.title) ?? [])")
        XCTAssertEqual(v.line, "\(label) and Face 3 share \(Int(area.rounded())) mm\u{00B2}", "★ in his words")
        XCTAssertLessThanOrEqual(v.line?.count ?? 99, 44)
        XCTAssertFalse(m.sentPresses.contains(press.id), "★ the pre-check stops the send")
        XCTAssertFalse(try m.runJobJSON(resting: Set(m.coreHold?.fixes.first?.resting ?? [])).contains("press_direction"), "★ no press is written")
        let fixes = try XCTUnwrap(m.pressWarning(press.id)?.fixes)
        XCTAssertTrue((1...3).contains(fixes.count), "★ 1–3 fixes: \(fixes.map(\.title))")
        XCTAssertTrue(fixes.contains(.remove(press.id, label: label)), "[Remove \(label)]")
        XCTAssertTrue(fixes.contains(.rest(3, name: "Face 3")), "[Face 3 rests]")
        // each fix: ONE undo step, and the press is back in the job (or gone, for Remove)
        for f in fixes {
            r.project.sealUndoStep()   // (the edit before is its own step)
            let before = r.project.undo.past.count
            let why = await m.applyPressFix(f)
            XCTAssertNil(why, "\(f.title)")
            try await F.M2.reopen(m, f.title)
            XCTAssertEqual(r.project.undo.past.count, before + 1, "★ \(f.title): one undo step")
            if case .remove = f {
                XCTAssertNil(m.press(press.id), "★ removed")
            } else {
                let back = try await settled(m, press.id, f.title)
                XCTAssertTrue(back.inJob, "★ \(f.title): back in the job")
            }
            r.project.performUndo(); try await F.M2.reopen(m, "undo \(f.title)")
        }
        // core's own refusal: the edges group's job with Face 3 loaded beside the press
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: press.id))
        let send = try XCTUnwrap(m.coreHold?.fixes.first { $0.scope == "Group \(g.number) only" })
        m.edit { s in s.setFace(FlexibleFaceSettings(faceRegionID: 3, role: "resting")) }
        try await FlexibleHisProject.waitFor(120, "Edge 16 back in") { m.pressSupport[press.id]?.inJob == true }
        var obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try m.runJobJSON(resting: Set(send.resting)).utf8)) as? [String: Any])
        var flex = try XCTUnwrap(obj["flexible"] as? [String: Any])
        var faces = try XCTUnwrap(flex["faces"] as? [[String: Any]])
        let i3 = try XCTUnwrap(faces.firstIndex { ($0["face_region_id"] as? Int) == 3 })
        faces[i3] = try FlexibleJob.faceEntry(FlexibleFaceSettings(faceRegionID: 3, weightKg: 5), finish: .covered, stamps: [:])
        flex["faces"] = faces; obj["flexible"] = flex
        let both = String(decoding: try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .prettyPrinted]), as: UTF8.self)
        let file = try XCTUnwrap(r.project.importedFile)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("flex-e2-shared-\(UUID().uuidString)").path
        addTeardownBlock { try? FileManager.default.removeItem(atPath: out) }
        let run = try FlexibleCore.runJob(jobJSON: both, jobDir: (file.path as NSString).deletingLastPathComponent, outDir: out,
                                          materialsPath: FlexibleHisProject.materialsPath, fingerprint: "e2")
        let refusal = try XCTUnwrap(run.refusal, "core refuses the job")
        XCTAssertEqual(refusal.code, "shared_footprint")
        let line = FlexibleCoreRunReport.refusalLine(refusal, names: { m.coreRegionName($0) })
        let raw = FlexibleCoreRunReport.refusalLine(refusal)
        print("FLEX-E2-6 core's refusal: '\(refusal.reason)' → '\(line)' · RED CONTROL '\(raw)'")
        XCTAssertEqual(line, "Core refused it: " + "\(label) and Face 3 share \(Int(area.rounded())) mm\u{00B2}", "★ core's refusal in his words")
        XCTAssertTrue(raw.contains("face region") || raw.contains("presses"), "★ RED CONTROL: core's raw sentence")
        XCTAssertFalse(line.contains("face region"))
        let warn = FlexibleRowCopy.faceWarning(refusalCode: refusal.code, refusalReason: refusal.reason, unreachedColumns: 0, side: false,
                                               names: { m.coreRegionName($0) })
        XCTAssertEqual(warn, "\(label) and Face 3 share \(Int(area.rounded())) mm\u{00B2}", "★ the face's warning line too")
    }

    // MARK: - E2-7

    /// ★ THE LATTICE IS GRADED ALONG THE ARROW (the ruling's item 6): his pad, Group 1 (the Top) and the edges group with Edge 16
    /// sent — the built lattice's field is core's: the Top's field and core's field over the PRESS KEY, the firmer per voxel; under
    /// Edge 16 it differs from E1's (presses stripped). The press is no longer "pending". RED CONTROL: designInputs still stripping
    /// presses — the lattice as E1 built it.
    func testTheLatticeIsGradedAlongTheArrow() async throws {
        let (_, m, press) = try await padEdge16(rest: [2, 3, 4, 5])
        let v0 = try await settled(m, press.id, "Edge 16")
        XCTAssertTrue(v0.inJob, "premise: Edge 16 in the job")
        XCTAssertNotEqual(m.pressWarning(press.id)?.line, FlexibleRowCopy.pressNotSent, "★ no longer pending")
        m.keepCombinedField = true
        _ = try await FlexibleSquishFixture.build(m, "Edge 16 sent")
        let built = try XCTUnwrap(m.lastCombinedField)
        let key = try XCTUnwrap(m.pressKey(press.id))
        let top = m.loadedKeys   // Group 1: the Top (its loaded faces — 2…5 rest)
        XCTAssertFalse(top.isEmpty, "premise: Group 1 presses")
        let b = m.build
        let topField = try await m.frameWorker.withScene { try $0.densityField(faces: top.map(\.region), rotations: top.map(\.rotation), build: b) }
        let pressField = try await m.frameWorker.withScene { try $0.densityField(faces: [key], rotations: [0], build: b) }
        let expect = FlexibleGroupField.firmer([topField, pressField]).field
        XCTAssertEqual(built.density, expect.density, "★ the lattice is core's fields, the press's over its key, the firmer per voxel")
        let under = pressField.density.indices.filter { pressField.density[$0] > 0 }
        XCTAssertGreaterThan(under.count, 0, "premise: core's press field grades voxels")
        // ★ RED CONTROL: E1's rule — presses stripped from the lattice's key and from its build
        FlexibleStageModel.controlStripPresses = true
        m.discardLattice()
        _ = try await FlexibleSquishFixture.build(m, "presses stripped")
        let e1 = try XCTUnwrap(m.lastCombinedField)
        FlexibleStageModel.controlStripPresses = false
        let moved = under.filter { built.density[$0] != e1.density[$0] }.count
        print("FLEX-E2-7 his pad, Edge 16: voxels under the press \(under.count) · differing from E1's lattice \(moved) · lattice voxels \(built.density.filter { $0 >= 0 }.count)")
        XCTAssertNotEqual(e1.density, built.density, "★ RED CONTROL: stripped, the lattice is E1's")
        XCTAssertGreaterThan(moved, 0, "★ under Edge 16 the lattice now follows core's design along the arrow")
    }

    // MARK: - E2-8

    /// ★ THE RIM RULING'S FIRST TEST: on the cube edge and the cube corner, the default press (3 mm, halfway) has 0 beyond-data
    /// columns (the flat prism is its own fade to 0 at the rim).
    func testRimDefault() async throws {
        for which in ["edge", "corner"] {
            let (_, m) = try await F.cube(self)
            let c: FlexibleEdgeCandidates.Candidate
            if which == "edge" {
                let pick = try await F.M2.pickMode(m)
                c = try XCTUnwrap(F.anyEdge(pick))
            } else {
                c = try await cubeCorner(m)
            }
            let press = try await F.commit(m, c)
            try await settled(m, press.id, "cube \(which)")
            let d = try XCTUnwrap(m.pressDesign(press.id), "cube \(which): designed")
            print("FLEX-E2-8 cube \(which) at \(press.settings.deepestMM) mm: columns \(d.columns.count) · beyond data \(d.beyondData) · ok \(d.ok) · no lattice \(d.noLattice)")
            XCTAssertEqual(press.settings.deepestMM, FlexibleFlatPrism.defaultDepthMM)
            XCTAssertEqual(d.beyondData, 0, "★ cube \(which): 0 beyond-data columns at the default")
            XCTAssertGreaterThan(d.columns.count, 0)
        }
    }

    // MARK: - E2-9

    /// ★ ONE GROUP PER EXPORT, SAID FIRST (M1 ruling 4): his pad, Group 1 (the Top) beside the edges group (Edge 16 + Edge 18, both
    /// sent): the notice shows before Export, a send per group, none dropped; the edges group's send carries both presses and no
    /// loaded face; Group 1's carries no press. With the edges group the only one sent, step ② reads "Group 2 · 11 lb · 2 edges ·
    /// bead 0.45 mm". RED CONTROL: the hold before E2 (a sent press's group not counted) — Ready with both, one dropped.
    func testOneGroupPerExportSaid() async throws {
        let (_, m) = try await F.hisPad(self)
        for f in [2, 3, 4, 5] { m.rest(f) }
        try await FlexibleSquishFixture.settle(m, "his pad, 2–5 resting")
        let pick = try await F.M2.pickMode(m)
        let e16 = try XCTUnwrap(F.M2.edge(m, pick, faces: [3, 2])), e18 = try XCTUnwrap(F.M2.edge(m, pick, faces: [3, 4]))
        m.toggleEdgePick(e16.number); m.toggleEdgePick(e18.number)
        let doneWhy = try await F.M2.done(m, kg: 5)
        XCTAssertNil(doneWhy)
        let ps = m.presses.filter { $0.strip != nil }
        XCTAssertEqual(ps.count, 2)
        for p in ps {
            let v = try await settled(m, p.id, p.strip?.label ?? "")
            XCTAssertTrue(v.inJob, "\(p.strip?.label ?? ""): sent")
        }
        let g = try XCTUnwrap(m.squeezeGroup(ofPress: ps[0].id))
        XCTAssertEqual(m.sentSqueezeGroups.map(\.number), [1, g.number], "premise: Group 1 and the edges group, both sent")
        XCTAssertEqual(m.coreHoldKind, .squeezeGroups, "★ the notice shows before Export")
        let hold = try XCTUnwrap(m.coreHold)
        let titles = hold.fixes.map(\.title)
        print("FLEX-E2-9 hold '\(hold.line)' · why '\(hold.why)' · sends \(titles)")
        XCTAssertTrue(titles.contains("Send Group 1 only") && titles.contains("Send Group \(g.number) only"), "★ a send per group: \(titles)")
        for f in hold.fixes {
            let job = try m.runJobJSON(resting: Set(f.resting))
            let block = try FlexibleCore.parseJobBlock(job)
            let presses = block.faces.filter { !$0.footprintRegionIDs.isEmpty }
            let faces = block.faces.filter { $0.footprintRegionIDs.isEmpty && $0.role == "loaded" }
            print("FLEX-E2-9 [\(f.title)] presses \(presses.count) · loaded faces \(faces.map(\.faceRegionID))")
            if f.title == "Send Group 1 only" {
                XCTAssertEqual(presses.count, 0, "★ Group 1's job carries no press")
                XCTAssertEqual(Set(faces.map(\.faceRegionID)), Set(m.squeezeGroups.first { $0.number == 1 }?.regions ?? []), "Group 1's faces")
            } else {
                XCTAssertEqual(presses.count, 2, "★ the edges group's job carries both presses")
                XCTAssertTrue(faces.isEmpty, "★ and no loaded face")
            }
        }
        // the edges group the only one sent: step ② names it
        let group1 = m.squeezeGroups.first { $0.number == 1 }?.regions ?? []
        for r in group1 { m.rest(r) }
        try await FlexibleHisProject.waitFor(60, "Group 1 rests") { m.sentSqueezeGroups.count == 1 }
        let summary = try XCTUnwrap(FlexibleLatticeCard.jobSummary(model: m), "★ step ② names the edges group")
        let g2 = try XCTUnwrap(m.squeezeGroup(ofPress: ps[0].id))
        let expect = FlexibleRowCopy.edgesJobSummary(group: FlexibleRowCopy.groupName(g2.number),
                                                     weight: FlexibleRowCopy.squeezeValue(m.groupForce(g2), unit: m.weightUnit),
                                                     edges: 2, corners: 0, beadMM: m.project.printParams.strutLineWidthMM)
        print("FLEX-E2-9 step ②: '\(summary)'")
        XCTAssertEqual(summary, expect)
        XCTAssertTrue(summary.contains("2 edges") && summary.hasSuffix("bead 0.45 mm"), "★ '\(summary)'")
        XCTAssertLessThanOrEqual(summary.count, 44)
        for r in group1 { m.press(r) }
        try await FlexibleHisProject.waitFor(60, "Group 1 back") { m.sentSqueezeGroups.count == 2 }
        // ★ RED CONTROL: the hold before E2 — Ready with both groups, the edges group dropped without a word
        FlexibleStageModel.controlHoldIgnoresPresses = true
        let kind = m.coreHoldKind
        FlexibleStageModel.controlHoldIgnoresPresses = false
        print("FLEX-E2-9 RED CONTROL hold kind: \(String(describing: kind))")
        XCTAssertNil(kind, "★ RED CONTROL: no notice — one group would be dropped unsaid")
    }

    // MARK: - E2-10

    /// ★ FACE PRESSES UNCHANGED. No presses: C1's pad's run-job bytes are the golden's. With presses: the job is the faces' job
    /// with ONLY the press entries appended (every face line as it was). Positive control: a face weight +0.001 kg changes ONE
    /// line.
    func testFacePressesUnchanged() throws {
        try G.assertGolden(try G.padPureRunJob(), "c1_pad_pure_run_job.json")
        let s = FlexibleStageTests.settings()
        let plain = try FlexibleJob.runJobJSON(FlexibleStageTests.inputs(s))
        var withPress = FlexibleStageTests.inputs(s)
        withPress.presses = [FlexibleJob.PressEntry(id: UUID(), regions: [2, 3], direction: simd_normalize(SIMD3(-1, -1, 0)), weightN: 49.03325,
                                                    map: FlexMap(mode: "both", x: .flat, y: FlexCurve(x: [0, 0.5, 1], y: [0, 1, 0]), centreEdge: .flat, deepestMM: 3))]
        withPress.settings.presses = [FlexiblePress(id: withPress.presses[0].id, regions: [2, 3], direction: withPress.presses[0].direction,
                                                    snap: "halfway", settings: FlexibleFaceSettings(faceRegionID: 2))]
        let both = try FlexibleJob.runJobJSON(withPress)
        let a = plain.components(separatedBy: "\n"), b = both.components(separatedBy: "\n")
        // b = a with one contiguous block inserted (the press entry, after the face entries)
        var p = 0
        while p < a.count, p < b.count, a[p] == b[p] { p += 1 }
        var q = 0
        while q < a.count - p, q < b.count - p, a[a.count - 1 - q] == b[b.count - 1 - q] { q += 1 }
        let inserted = Array(b[p..<(b.count - q)])
        let removed = Array(a[p..<(a.count - q)])
        print("FLEX-E2-10 with a press: \(inserted.count) line(s) inserted at line \(p + 1), \(removed.count) changed")
        XCTAssertTrue(removed.allSatisfy { $0.trimmingCharacters(in: .whitespaces) == "}" || $0.trimmingCharacters(in: .whitespaces) == "}," },
                      "★ no face line changes (only the closing brace of the last face entry gains its comma): \(removed)")
        XCTAssertTrue(inserted.contains { $0.contains("\"face_region_ids\"") } && inserted.contains { $0.contains("\"press_direction\"") },
                      "★ only the press entry is added")
        // positive control: a face weight +0.001 kg moves exactly one line
        let heavier = try G.padPureRunJob(weightDeltaKg: 0.001)
        XCTAssertEqual(G.lineDiff(heavier, try G.padPureRunJob()).count, 1, "control: one line")
    }
}
