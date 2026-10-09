// FlexiblePressAimTests — the arrow's maths (task 2026-10-07, angled presses, batch AP3; final spec §6 "The arrow" and
// §14's first ruling test, AS AMENDED by the reviewer's A4 — "a multi-face press never offers a snap to one of its own
// faces' normals (core refuses edge-on); offer only directions core accepts; a single-face press snaps to its own
// normal as 'straighten'" — and A8 — "build Z covers both straight down and straight up").
//
//   (1) the default arrow is 45.00° on an edge and 54.74° on a corner FROM EACH FACE, measured against core's own
//       per-member inward normals (cube60, the STEP cube, C1's pad, his r5, his A1_0003);
//   (2) snaps land EXACTLY (chip, knob, box at 0: the target's bits) and survive the project file;
//   (3) build Z is core's build direction, both ways — and is offered exactly where core builds it;
//   (4) A4: an edge or a corner never offers a member's own normal; one face offers [Straighten];
//   (5) every offered direction is one core builds (build_press_stack), on the cube edge, the cube corner and his
//       A1_0003's top/side edge — and every asked direction core refuses is not offered;
//   (6) the side verdict is core's (face_frame_cut with press_direction), never a Swift threshold;
//   (7) faces that face apart have no halfway;
//   (8) the degrees box (keypad + vertical drag) and its target rule;
//   (9) the knob's drag never points out of a face (1° short of edge-on), snaps exempt;
//  (10) looking along the arrow, the knob is a trackball;
//  (11) the camera turns across the arrow;
//  (12) the snap kind is saved with the press; [Straighten] puts the face back.
//
// Each test runs its RED control against the instrument the spec names. STEP parts need OCCT: a part the importer
// refuses is a COUNTED skip ("FLEX-AP SKIP …"), never a pass.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePressAimTests: XCTestCase {
    typealias G = FlexibleAngledGoldens
    typealias A = FlexiblePressAim

    /// The cube corner's angle from each face: acos(1/√3).
    static let cornerDeg = acos(1 / 3.0.squareRoot()) * 180 / .pi

    // MARK: - helpers

    /// print, flushed at once: a full-class run lost every buffered evidence line (each test alone kept them).
    static func say(_ s: String) {
        print(s)
        fflush(stdout)
    }

    /// The angle between two directions, degrees (atan2 of |a×b| and a·b: exact enough at 0° for a 1e-9 test).
    static func deg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        let u = simd_normalize(a), v = simd_normalize(b)
        return atan2(simd_length(simd_cross(u, v)), simd_dot(u, v)) * 180 / .pi
    }

    static func bits(_ v: SIMD3<Double>) -> [UInt64] { [v.x.bitPattern, v.y.bitPattern, v.z.bitPattern] }

    /// `v` turned by `deg` degrees about a unit axis perpendicular to it (toward `toward` when given).
    static func tilt(_ v: SIMD3<Double>, by deg: Double, toward: SIMD3<Double>? = nil) -> SIMD3<Double> {
        let n = simd_normalize(v)
        var w = toward ?? (abs(n.x) < 0.9 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0))
        w = simd_normalize(w - simd_dot(w, n) * n)
        let a = deg * .pi / 180
        return cos(a) * n + sin(a) * w
    }

    /// The region whose CORE load is `want` (within 1e-6), among the meet's pieces.
    static func region(_ m: FlexibleStageModel, load want: SIMD3<Double>) async throws -> Int {
        let meet = try XCTUnwrap(m.meet)
        for p in meet.pieces {
            if let f = try? await m.regionFrame(p.id), f.valid, simd_distance(f.load, want) < 1e-6 { return p.id }
        }
        throw XCTSkip("no region with core load \(want)")
    }

    /// The cube's (or the pad's) top, +X and +Y faces, found by core's loads.
    static func boxFaces(_ m: FlexibleStageModel) async throws -> (top: Int, x: Int, y: Int, bottom: Int) {
        (try await region(m, load: SIMD3(0, 0, -1)), try await region(m, load: SIMD3(-1, 0, 0)),
         try await region(m, load: SIMD3(0, -1, 0)), try await region(m, load: SIMD3(0, 0, 1)))
    }

    /// A STEP part's model, or a counted skip.
    func stepModel(_ label: String, _ test: String, _ make: (String) throws -> ProjectModel,
                   skips: inout [String]) async throws -> FlexibleStageModel? {
        do {
            return try await G.openModel(self, try make(test), label)
        } catch let s as XCTSkip {
            skips.append("\(label): \(s.message ?? "skipped")")
            return nil
        }
    }

    /// A chamfered block: the profile (x, z) (0,0) (40,0) (50,10) (50,20) (40,30) (0,30) extruded along y ∈ [0, 30] —
    /// a 45° chamfer above and below the x = 50 side. Its top–upper-chamfer edge is pressed into by straight DOWN
    /// over both faces (core builds it), its bottom–lower-chamfer edge by straight UP: A8's both senses.
    static func chamferProject() throws -> ProjectModel {
        let prof: [SIMD2<Double>] = [SIMD2(0, 0), SIMD2(40, 0), SIMD2(50, 10), SIMD2(50, 20), SIMD2(40, 30), SIMD2(0, 30)]
        let depth = 30.0
        var tris: [FlexiblePressFixtures.Tri] = []
        func p(_ q: SIMD2<Double>, _ y: Double) -> SIMD3<Double> { SIMD3(q.x, y, q.y) }
        let n = prof.count
        for i in 0..<n {
            let a = prof[i], b = prof[(i + 1) % n]
            tris.append((p(a, 0), p(b, 0), p(b, depth)))
            tris.append((p(a, 0), p(b, depth), p(a, depth)))
        }
        for i in 1..<(n - 1) {
            tris.append((p(prof[0], 0), p(prof[i], 0), p(prof[i + 1], 0)))
            tris.append((p(prof[0], depth), p(prof[i + 1], depth), p(prof[i], depth)))
        }
        // wind every triangle OUT of the (convex) part
        let c = SIMD3<Double>(25, depth / 2, 15)
        tris = tris.map { t in
            let nn = simd_cross(t.1 - t.0, t.2 - t.0)
            return simd_dot(nn, (t.0 + t.1 + t.2) / 3 - c) >= 0 ? t : (t.0, t.2, t.1)
        }
        let path = try FlexiblePressFixtures.write("chamfer_block.stl", FlexiblePressFixtures.asciiSTL("chamfer_block", tris))
        return try FlexiblePressFixtures.project(path: path, name: "chamfer block")
    }

    /// His A1_0003's top/side edge and a corner on it, from the numbered candidates: the lowest-numbered offered edge
    /// whose members are a region pressed straight down (core load −Z) and a side (core load horizontal).
    static func a1TopSide(_ m: FlexibleStageModel) async throws -> (edge: [Int], corner: [Int]) {
        let c = try await m.edgeCandidates()
        func load(_ r: Int) async throws -> SIMD3<Double> { try await m.regionFrame(r).load }
        var edge: [Int]? = nil, corner: [Int]? = nil
        for k in c.candidates where k.offered {
            var tops = 0, sides = 0
            for r in k.members {
                let l = try await load(r)
                if simd_distance(l, SIMD3(0, 0, -1)) < 1e-9 { tops += 1 } else if abs(l.z) < 1e-9 { sides += 1 }
            }
            if k.kind == .edge, edge == nil, tops == 1, sides == 1 { edge = k.members }
            if k.kind == .corner, corner == nil, tops == 1, sides == 2 { corner = k.members }
        }
        return (try XCTUnwrap(edge, "A1_0003 has a top/side edge"), try XCTUnwrap(corner, "A1_0003 has a top corner"))
    }

    // MARK: - (1) 45.00° and 54.74°, from each face, from core's normals

    /// ★ THE RULING'S FIRST TEST (spec §14). The default arrow (the halfway: Σ core's per-member inward normals,
    /// normalised) is 45.00° from each face on an edge and 54.74° (acos 1/√3) on a corner — measured against each
    /// member's CORE load (face_frame_cut through the open scene), within 1e-9°, on cube60, C1's pad, his r5 (edge
    /// Top A + 3, corner Top A + 3 + 2), his A1_0003 (its top/side edge and a corner) and the STEP cube (counted
    /// skip). It is the first target offered, and core builds it. RED CONTROL (run here): the oracle that sums
    /// area × load over core's region frames on C1's pad corner gives 15.79° / 78.90° — core's own no-direction
    /// press (its area-weighted union normal, asked of core) is that oracle, NOT the halfway.
    func testTheDefaultArrowIs45OnAnEdgeAnd5474OnACorner() async throws {
        var cases: [(String, FlexibleStageModel, [Int], Double)] = []
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let cf = try await Self.boxFaces(cube)
        cases.append(("cube60 edge", cube, [cf.top, cf.x], 45))
        cases.append(("cube60 corner", cube, [cf.top, cf.x, cf.y], Self.cornerDeg))
        let pad = try await G.openModel(self, try FlexiblePressFixtures.padProject(), "C1 pad")
        let pf = try await Self.boxFaces(pad)
        cases.append(("C1 pad edge", pad, [pf.top, pf.x], 45))
        cases.append(("C1 pad corner", pad, [pf.top, pf.x, pf.y], Self.cornerDeg))
        let r5 = try FlexiblePressFixtures.hisRound5(self)
        let rm = try await G.openModel(self, r5.project, "his r5")
        cases.append(("his r5 edge Top A + 3", rm, [FlexibleHisProject.topA, 3], 45))
        cases.append(("his r5 corner Top A + 3 + 2", rm, [FlexibleHisProject.topA, 3, 2], Self.cornerDeg))
        let a1 = try FlexiblePressFixtures.a1Project(3, self)
        let am = try await G.openModel(self, a1.project, "A1_0003")
        let ats = try await Self.a1TopSide(am)
        cases.append(("A1_0003 top/side edge", am, ats.edge, 45))
        cases.append(("A1_0003 top corner", am, ats.corner, Self.cornerDeg))
        var skips: [String] = []
        if let sc = try await stepModel("STEP cube", "FlexiblePressAimTests.testTheDefaultArrowIs45OnAnEdgeAnd5474OnACorner",
                                        FlexiblePressFixtures.stepCubeProject, skips: &skips) {
            let sf = try await Self.boxFaces(sc)
            cases.append(("STEP cube edge", sc, [sf.top, sf.x], 45))
            cases.append(("STEP cube corner", sc, [sf.top, sf.x, sf.y], Self.cornerDeg))
        }
        for (label, m, regions, want) in cases {
            let aim = try await m.pressAim(regions)
            let h = try XCTUnwrap(aim.halfway, "\(label): a halfway (\(aim.why ?? ""))")
            var line = "FLEX-AP3 DEFAULT \(label) \(regions.map { m.name($0) }):"
            for r in regions {
                let load = try await m.regionFrame(r).load   // core's own inward normal
                let a = Self.deg(h, load)
                line += String(format: " %@ %.2f°", m.name(r), a)
                XCTAssertEqual(a, want, accuracy: 1e-9, "★ \(label): \(m.name(r)) \(a)° from the arrow, core's normal")
            }
            Self.say(line)
            XCTAssertEqual(aim.offered.first?.kind, .halfway, "\(label): the halfway is the first target offered")
            XCTAssertEqual(aim.offered.first.map { Self.bits($0.direction) }, Self.bits(h), "\(label): the target IS the halfway")
            let v = try await m.pressVerdict(regions, direction: h)
            XCTAssertTrue(v.accepted, "\(label): core builds the halfway — \(v.reason)")
            XCTAssertEqual(aim.defaultRelease.map { Self.bits($0.direction) }, Self.bits(h), "\(label): a new press's aim IS the halfway")
            XCTAssertEqual(aim.defaultRelease?.snap, .halfway)
        }
        Self.say("FLEX-AP3 DEFAULT STEP skips \(skips.count)" + (skips.isEmpty ? "" : " — " + skips.joined(separator: "; ")))

        // ★ RED CONTROL: the area-weighted sum (core's no-direction default) on C1's pad corner
        let corner = [pf.top, pf.x, pf.y]
        var oracle = SIMD3<Double>.zero
        for r in corner { let f = try await pad.regionFrame(r); oracle += f.areaMM2 * f.load }
        oracle = simd_normalize(oracle)
        var angles: [Double] = []
        for r in corner { angles.append(Self.deg(oracle, try await pad.regionFrame(r).load)) }
        let coreDefault = try await pad.pressVerdict(corner, direction: nil)
        let padCorner = try await pad.pressAim(corner)
        let h = try XCTUnwrap(padCorner.halfway)
        Self.say(String(format: "FLEX-AP3 DEFAULT RED C1 pad corner, area × load oracle: %.2f° / %.2f° / %.2f° · core's no-direction press %.6f° from the oracle, %.2f° from the halfway",
                     angles[0], angles[1], angles[2], Self.deg(coreDefault.load, oracle), Self.deg(coreDefault.load, h)))
        XCTAssertEqual(angles[0], 15.79, accuracy: 0.01, "control: the oracle is 15.79° from the top")
        XCTAssertEqual(angles[1], 78.90, accuracy: 0.01, "control: and 78.90° from a side")
        XCTAssertTrue(coreDefault.accepted, coreDefault.reason)
        XCTAssertLessThan(Self.deg(coreDefault.load, oracle), 1e-6, "core's no-direction press IS the area-weighted oracle")
        XCTAssertGreaterThan(Self.deg(coreDefault.load, h), 30, "★ and NOT the halfway: the press must state its direction")
    }

    // MARK: - (2) exact snaps

    /// ★ SPEC "snaps land exactly". 8° off each target, the knob's release IS the target in every component's bit
    /// pattern; 13° off passes through, free; a chip tap is bit-equal; a press aimed so keeps those bits through the
    /// project file's JSON (ProjectStore's encoder). RED (1): GravityDirectionGizmo.snap on a part whose build
    /// direction is +Y snaps a direction 8° off model +Z to an UNREQUESTED "+Z". RED (2): a target through Float is
    /// not bit-equal.
    func testSnapsLandExactly() async throws {
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await Self.boxFaces(cube)
        var targets: [A.Target] = []
        for regions in [[f.top, f.x], [f.top, f.x, f.y], [f.top]] {
            let aim = try await cube.pressAim(regions)
            targets += aim.offered
            for t in aim.offered {
                for axis in [SIMD3<Double>(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)] where abs(simd_dot(axis, t.direction)) < 0.99 {
                    let near = Self.tilt(t.direction, by: 8, toward: axis)
                    let r = A.release(near, from: t.direction, targets: aim.offered, loads: aim.memberLoads)
                    XCTAssertEqual(Self.bits(r.direction), Self.bits(t.direction), "★ 8° off \(t.label) lands ON it, bit for bit")
                    XCTAssertEqual(r.snap, t.kind)
                    let far = Self.tilt(t.direction, by: 13, toward: axis)
                    let free = A.release(far, from: t.direction, targets: aim.offered, loads: [])
                    XCTAssertNil(free.snap, "13° off \(t.label) passes through")
                    XCTAssertEqual(Self.deg(free.direction, far), 0, accuracy: 1e-9, "unchanged")
                }
                XCTAssertEqual(Self.bits(A.chip(t).direction), Self.bits(t.direction), "★ the chip is the target, bit for bit")
                XCTAssertTrue(A.on(A.chip(t).direction, t))
            }
        }
        Self.say("FLEX-AP3 SNAP cube60 targets: " + targets.map { "\($0.label) \($0.direction)" }.joined(separator: " · "))
        XCTAssertFalse(targets.isEmpty)
        for t in targets {
            XCTAssertFalse(t.direction.x.sign == .minus && t.direction.x == 0, "no negative zero")
            XCTAssertFalse(t.direction.y.sign == .minus && t.direction.y == 0, "no negative zero")
            XCTAssertFalse(t.direction.z.sign == .minus && t.direction.z == 0, "no negative zero")
        }

        // through the stage model and the project file
        XCTAssertTrue(cube.press(f.bottom, kg: 5), "a face press, so the press below has a weight to take")
        let edge = try await cube.pressAim([f.top, f.x])
        let half = try XCTUnwrap(edge.offered.first)
        let id = try XCTUnwrap(cube.addPress(regions: [f.top, f.x], direction: Self.tilt(half.direction, by: 20), snap: nil, kg: 5))
        XCTAssertTrue(cube.aimPress(id, A.release(Self.tilt(half.direction, by: 8), from: half.direction,
                                                   targets: edge.offered, loads: edge.memberLoads)))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let back = try JSONDecoder().decode(FlexibleStageSettings.self, from: enc.encode(cube.settings))
        let p = try XCTUnwrap(back.press(id))
        Self.say("FLEX-AP3 SNAP stored \(p.direction) snap \(p.snap ?? "nil") · halfway \(half.direction)")
        XCTAssertEqual(Self.bits(p.direction), Self.bits(half.direction), "★ the knob's snap, through the file, bit for bit")
        XCTAssertEqual(p.snap, "halfway")

        // RED (1): the gravity gizmo's own snap set (model axes) on a part built along +Y
        let up = SIMD3<Double>(0, 1, 0)
        let gizmo = GravityDirectionGizmo.snap(Self.tilt(SIMD3(0, 0, 1), by: 8, toward: SIMD3(1, 0, 0)))
        let ours = A.snapped(Self.tilt(SIMD3(0, 0, 1), by: 8, toward: SIMD3(1, 0, 0)),
                             targets: A.candidates(memberLoads: [], ownLoad: nil, buildDir: up))
        Self.say("FLEX-AP3 SNAP RED gizmo snap 8° off +Z with build +Y: \(gizmo.label ?? "free") · ours \(ours?.label ?? "free")")
        XCTAssertEqual(gizmo.label, "+Z", "control: the gizmo snaps to an unrequested model axis")
        XCTAssertNil(ours, "★ our targets are core's build direction, not model axes")
        // RED (2): a Float round trip
        let viaFloat = SIMD3<Double>(SIMD3<Float>(half.direction))
        XCTAssertNotEqual(Self.bits(viaFloat), Self.bits(half.direction), "control: through Float it is not the target")
    }

    // MARK: - (3) build Z = core's build direction, both ways (A8)

    /// ★ A8. Build Z is ±core's build direction (the scene's `build`, −gravity), never model ±Z, BOTH ways, and is
    /// offered exactly where core builds it. On cube60 with gravity −Y the targets are (0, ∓1, 0); the top's are
    /// [Straighten] plus straight down / up asked of core (both edge-on: refused). On the chamfered block (gravity
    /// −Z) the top–upper-chamfer edge offers [Halfway, Straight down] and the bottom–lower-chamfer edge [Halfway,
    /// Straight up] — POSITIVE controls that the rule offers build Z at all, in each sense. RED: model ±Z.
    func testBuildZIsCoresBuildDirectionBothWays() async throws {
        let pm = try FlexiblePressFixtures.cube60Project()
        pm.force.setGravity(direction: SIMD3(0, -1, 0))
        let cube = try await G.openModel(self, pm, "cube60, gravity −Y")
        let build = try XCTUnwrap(cube.sceneInfo?.buildDir)
        Self.say("FLEX-AP3 BUILD cube60 gravity −Y: core's build direction \(build)")
        XCTAssertEqual(build, SIMD3(0, 1, 0), "premise: core builds along +Y")
        let top = try await Self.region(cube, load: SIMD3(0, 0, -1))
        let aim = try await cube.pressAim([top])
        let builds = aim.asked.filter { $0.target.kind == .buildDown || $0.target.kind == .buildUp }
        XCTAssertEqual(builds.map(\.target.kind), [.buildDown, .buildUp], "★ both ways are asked")
        XCTAssertEqual(builds.map { Self.bits($0.target.direction) }, [Self.bits(SIMD3(0, -1, 0)), Self.bits(SIMD3(0, 1, 0))],
                       "★ ±core's build direction, not model ±Z")
        XCTAssertTrue(builds.allSatisfy { !$0.accepted }, "edge-on to the top: core refuses both")
        XCTAssertEqual(aim.offered.map(\.kind), [.straighten])

        let block = try await G.openModel(self, try Self.chamferProject(), "chamfer block")
        let t = try await Self.region(block, load: SIMD3(0, 0, -1))
        let b = try await Self.region(block, load: SIMD3(0, 0, 1))
        let s2 = 1 / 2.0.squareRoot()
        let upperC = try await Self.region(block, load: SIMD3(-s2, 0, -s2))
        let lowerC = try await Self.region(block, load: SIMD3(-s2, 0, s2))
        let upper = try await block.pressAim([t, upperC])
        let lower = try await block.pressAim([b, lowerC])
        for (label, a) in [("top + upper chamfer", upper), ("bottom + lower chamfer", lower)] {
            Self.say("FLEX-AP3 BUILD chamfer \(label): asked " + a.asked.map { "\($0.target.label) \($0.accepted ? "built" : "refused '\($0.reason)'")" }.joined(separator: " · "))
        }
        XCTAssertEqual(upper.offered.map(\.kind), [.halfway, .buildDown], "★ straight DOWN is offered where core builds it")
        XCTAssertEqual(lower.offered.map(\.kind), [.halfway, .buildUp], "★ straight UP is offered where core builds it")
        XCTAssertEqual(upper.offered.last.map { Self.bits($0.direction) }, Self.bits(SIMD3(0, 0, -1)))
        XCTAssertEqual(lower.offered.last.map { Self.bits($0.direction) }, Self.bits(SIMD3(0, 0, 1)))
        for (a, regions) in [(upper, [t, upperC]), (lower, [b, lowerC])] {
            for o in a.offered {
                let v = try await block.pressVerdict(regions, direction: o.direction)
                XCTAssertTrue(v.accepted, "\(o.label): \(v.reason)")
            }
        }
        // RED: model ±Z on the gravity −Y cube
        let modelZ = [SIMD3<Double>(0, 0, -1), SIMD3(0, 0, 1)]
        XCTAssertFalse(builds.contains { b in modelZ.contains { Self.bits($0) == Self.bits(b.target.direction) } },
                       "★ control: model ±Z is not a build target when core builds along +Y")
    }

    // MARK: - (4) A4: never a member's own normal

    /// ★ A4. An edge or a corner never offers (nor asks) one of its own faces' normals: on a box each is EXACTLY
    /// edge-on to another member and core refuses it (asked here as the control, in core's words). The cube edge and
    /// corner offer [Halfway] alone (straight down / up are edge-on to a side: refused); the top alone offers
    /// [Straighten] (straight down is the same direction, dropped; straight up refused). Also on his r5 and A1_0003.
    /// RED: the spec's pre-amendment list (each member's normal as a chip).
    func testAMultiFacePressNeverOffersItsOwnFacesNormals() async throws {
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await Self.boxFaces(cube)
        let r5 = try FlexiblePressFixtures.hisRound5(self)
        let rm = try await G.openModel(self, r5.project, "his r5")
        let a1 = try FlexiblePressFixtures.a1Project(3, self)
        let am = try await G.openModel(self, a1.project, "A1_0003")
        let ats = try await Self.a1TopSide(am)
        let cases: [(String, FlexibleStageModel, [Int])] = [
            ("cube60 edge", cube, [f.top, f.x]), ("cube60 corner", cube, [f.top, f.x, f.y]),
            ("his r5 edge", rm, [FlexibleHisProject.topA, 3]), ("his r5 corner", rm, [FlexibleHisProject.topA, 3, 2]),
            ("A1_0003 edge", am, ats.edge), ("A1_0003 corner", am, ats.corner),
        ]
        for (label, m, regions) in cases {
            let aim = try await m.pressAim(regions)
            Self.say("FLEX-AP3 A4 \(label): asked " + aim.asked.map { "\($0.target.label) \($0.accepted ? "built" : "refused")" }.joined(separator: " · ")
                  + " → offered \(aim.offered.map(\.label))")
            XCTAssertEqual(aim.offered.map(\.kind), [.halfway], "★ \(label): the halfway alone")
            XCTAssertTrue(aim.asked.allSatisfy { [.halfway, .buildDown, .buildUp].contains($0.target.kind) },
                          "★ \(label): only the halfway and build Z are asked — no member chip, no straighten")
            for r in regions {
                let load = try await m.regionFrame(r).load
                // build Z may LIE along a member's normal (the top's is straight down): it is asked as build Z and core
                // decides — here it is edge-on to a side, refused, so never offered
                XCTAssertTrue(aim.asked.filter { Self.deg($0.target.direction, load) < 1e-9 }
                                .allSatisfy { ($0.target.kind == .buildDown || $0.target.kind == .buildUp) },
                              "\(label): \(m.name(r))'s normal is asked only as build Z")
                XCTAssertFalse(aim.offered.contains { Self.deg($0.direction, load) < 1e-9 },
                               "★ \(label): \(m.name(r))'s own normal is never offered")
                let v = try await m.pressVerdict(regions, direction: load)
                XCTAssertFalse(v.accepted, "control: core refuses \(m.name(r))'s normal for the \(label)")
                XCTAssertTrue(v.reason.contains("does not point into the part"), v.reason)
            }
        }
        let one = try await cube.pressAim([f.top])
        Self.say("FLEX-AP3 A4 cube60 top alone: asked " + one.asked.map { "\($0.target.label) \($0.accepted)" }.joined(separator: " · "))
        XCTAssertEqual(one.asked.map(\.target.kind), [.straighten, .buildUp], "straight down IS the top's normal: one chip")
        XCTAssertEqual(one.offered.map(\.kind), [.straighten], "★ one face: [Straighten]")
        let topOwn = try await cube.regionFrame(f.top).load
        XCTAssertEqual(one.offered.first.map { Self.bits($0.direction) }, Self.bits(topOwn + SIMD3(repeating: 0)),
                       "its own core normal")
    }

    // MARK: - (5) every offered direction is one core builds

    /// ★ THE AMENDMENT'S PROOF. Every OFFERED direction is one core builds (build_press_stack through the press
    /// verdict; face_frame_cut frames it), and every asked direction core refuses is NOT offered: the cube edge and
    /// corner, his A1_0003's top/side edge and corner, his r5's edge and corner, C1's pad, the chamfered block, the
    /// STEP cube (counted skip). The degrees box at its limit along its plane is built too; 1.5° past it, on the
    /// cube edge, core refuses (the 1° limit sits inside core's edge-on boundary).
    func testEveryOfferedDirectionIsOneCoreAccepts() async throws {
        var cases: [(String, FlexibleStageModel, [Int])] = []
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await Self.boxFaces(cube)
        cases += [("cube60 edge", cube, [f.top, f.x]), ("cube60 corner", cube, [f.top, f.x, f.y]), ("cube60 top", cube, [f.top])]
        let a1 = try FlexiblePressFixtures.a1Project(3, self)
        let am = try await G.openModel(self, a1.project, "A1_0003")
        let ats = try await Self.a1TopSide(am)
        cases += [("A1_0003 top/side edge", am, ats.edge), ("A1_0003 corner", am, ats.corner)]
        let r5 = try FlexiblePressFixtures.hisRound5(self)
        let rm = try await G.openModel(self, r5.project, "his r5")
        cases += [("his r5 edge", rm, [FlexibleHisProject.topA, 3]), ("his r5 corner", rm, [FlexibleHisProject.topA, 3, 2]),
                  ("his r5 Top B tilt", rm, [FlexibleHisProject.topB])]
        let pad = try await G.openModel(self, try FlexiblePressFixtures.padProject(), "C1 pad")
        let pf = try await Self.boxFaces(pad)
        cases += [("C1 pad edge", pad, [pf.top, pf.x]), ("C1 pad corner", pad, [pf.top, pf.x, pf.y])]
        let block = try await G.openModel(self, try Self.chamferProject(), "chamfer block")
        let s2 = 1 / 2.0.squareRoot()
        let bt = try await Self.region(block, load: SIMD3(0, 0, -1)), bc = try await Self.region(block, load: SIMD3(-s2, 0, -s2))
        cases += [("chamfer edge", block, [bt, bc]), ("chamfer face", block, [bc])]
        var skips: [String] = []
        if let sc = try await stepModel("STEP cube", "FlexiblePressAimTests.testEveryOfferedDirectionIsOneCoreAccepts",
                                        FlexiblePressFixtures.stepCubeProject, skips: &skips) {
            let sf = try await Self.boxFaces(sc)
            cases += [("STEP cube edge", sc, [sf.top, sf.x]), ("STEP cube corner", sc, [sf.top, sf.x, sf.y])]
        }
        var offered = 0, refused = 0
        for (label, m, regions) in cases {
            let aim = try await m.pressAim(regions)
            XCTAssertFalse(aim.offered.isEmpty, "\(label): something is offered")
            for a in aim.asked {
                let fp = a.target.kind == .straighten ? [regions[0]] : regions
                let v = try await m.pressVerdict(fp, direction: a.target.kind == .straighten ? nil : a.target.direction)
                XCTAssertEqual(v.accepted, a.accepted, "\(label) \(a.target.label): the offer IS core's verdict")
                if a.accepted {
                    offered += 1
                    let fr = try await m.regionFrame(regions[0], direction: a.target.direction)
                    XCTAssertTrue(fr.valid, "\(label) \(a.target.label): core frames it")
                } else {
                    refused += 1
                    XCTAssertFalse(aim.offered.contains(a.target), "★ \(label): \(a.target.label) core refuses is not offered")
                    XCTAssertFalse(a.reason.isEmpty, "core's words")
                }
            }
            // the box at its limit, along its plane from the selected target
            if let t = A.selected(nil, offered: aim.offered),
               let box = A.box(target: t, current: t.direction, fallbacks: aim.fallbacks, loads: aim.memberLoads), box.limit > 0 {
                let d = box.direction(box.limit)
                let v = try await m.pressVerdict(regions, direction: d)
                Self.say(String(format: "FLEX-AP3 OFFER %@: %@ · box limit %.4f° from %@ → core %@",
                             label, aim.offered.map(\.label).joined(separator: ", "), box.limit, t.label, v.accepted ? "builds" : "refuses '\(v.reason)'"))
                XCTAssertTrue(v.accepted, "★ \(label): the box's limit is built — \(v.reason)")
            }
        }
        Self.say("FLEX-AP3 OFFER totals: \(offered) offered, all built; \(refused) refused by core, none offered · STEP skips \(skips.count)"
              + (skips.isEmpty ? "" : " — " + skips.joined(separator: "; ")))
        // CONTROL: 1.5° past the cube edge's limit core refuses (the box stops 1° short of core's boundary)
        let edge = try await cube.pressAim([f.top, f.x])
        let half = try XCTUnwrap(edge.offered.first)
        let box = try XCTUnwrap(A.box(target: half, current: half.direction, fallbacks: edge.fallbacks, loads: edge.memberLoads))
        XCTAssertEqual(box.limit, 44, accuracy: 1e-6, "the cube edge: 1° short of edge-on to the side")
        let past = try await cube.pressVerdict([f.top, f.x], direction: box.direction(box.limit + 1.5))
        XCTAssertFalse(past.accepted, "control: past edge-on, core refuses")
    }

    // MARK: - (6) the side verdict is core's

    /// ★ "No Swift threshold": the side label reads core's FaceFrame.side for the STATED direction (face_frame_cut
    /// with press_direction). 14.9° off build Z is not side, 15.1° is. At the boundary (bisection on core's own
    /// answer, then every neighbouring direction ±40 ulps) the model's verdict IS core's, and an exact 15.0 — if core
    /// ever returns it — is not side (core's >). RED: a Swift copy (angle to MODEL +Z ≥ 15) calls a press 10° off
    /// core's build direction +Y a side press.
    func testSideVerdictIsCores() async throws {
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let top = try await Self.region(cube, load: SIMD3(0, 0, -1))
        func d(_ deg: Double) -> SIMD3<Double> { SIMD3(sin(deg * .pi / 180), 0, -cos(deg * .pi / 180)) }
        for (a, want) in [(14.9, false), (15.1, true), (0.0, false), (44.0, true)] {
            let s = try await cube.pressSide([top], direction: d(a))
            let side = try XCTUnwrap(s, "core frames the top")
            Self.say(String(format: "FLEX-AP3 SIDE %.1f° → core build angle %.12f side %@", a, side.buildAngleDeg, "\(side.side)"))
            XCTAssertEqual(side.side, want, "★ \(a)°: core's verdict")
        }
        // the boundary, on core's own answer
        var lo = 14.9, hi = 15.1
        for _ in 0..<80 {
            let mid = (lo + hi) / 2
            if mid <= lo || mid >= hi { break }
            let s = try await cube.regionFrame(top, direction: d(mid))
            if s.side { hi = mid } else { lo = mid }
        }
        var exact: Double? = nil
        var seen = 0
        var x = lo
        for _ in 0..<40 { x = x.nextDown }
        for _ in 0..<80 {
            let dir = d(x)
            let side = try await cube.pressSide([top], direction: dir)
            let model = try XCTUnwrap(side)
            let core = try await cube.regionFrame(top, direction: dir)
            XCTAssertEqual(model.side, core.side, "★ the model's verdict is core's at \(x)°")
            XCTAssertEqual(model.side, core.buildAngleDeg > 15, "core's own rule: more than 15°")
            if core.buildAngleDeg == 15 { exact = x; XCTAssertFalse(model.side, "★ exactly 15.0 is not side (core's >)") }
            seen += 1
            x = x.nextUp
        }
        Self.say("FLEX-AP3 SIDE boundary: \(seen) directions around \(lo)° — core's verdict everywhere; exact 15.0 "
              + (exact.map { "at \($0)°, not side" } ?? "never returned by core in this window (its angles step past it)"))
        // RED: a Swift copy against model +Z on a part built along +Y
        let pm = try FlexiblePressFixtures.cube60Project()
        pm.force.setGravity(direction: SIMD3(0, -1, 0))
        let yc = try await G.openModel(self, pm, "cube60, gravity −Y")
        let face = try await Self.region(yc, load: SIMD3(0, -1, 0))   // the y = 60 face, pressed straight down
        let ten = Self.tilt(SIMD3(0, -1, 0), by: 10, toward: SIMD3(1, 0, 0))
        let sideTen = try await yc.pressSide([face], direction: ten)
        let s = try XCTUnwrap(sideTen)
        let swiftCopy = Self.deg(ten, SIMD3(0, 0, -1)) >= 15
        Self.say(String(format: "FLEX-AP3 SIDE RED 10° off build +Y: core build angle %.4f side %@ · a Swift copy against model Z says side %@",
                     s.buildAngleDeg, "\(s.side)", "\(swiftCopy)"))
        XCTAssertFalse(s.side, "★ core: 10° off ITS build direction is not side")
        XCTAssertTrue(swiftCopy, "control: the Swift copy calls it side")
        XCTAssertEqual(FlexibleScene.sideStackDeg, 15, "core's number, bridged for the (i) text only")
        XCTAssertTrue(A.sideInfo(sideStackDeg: FlexibleScene.sideStackDeg).contains("15\u{00B0}"))
    }

    // MARK: - (7) faces that face apart

    /// Top + bottom have no halfway (the sum has no length); top + side + bottom neither (the sum is the side's
    /// normal, edge-on to the top and the bottom). On the cube the page says why in one line; on the rounded slab the
    /// side wall has no core normal at all (its normals cancel) and core's words say so. RED: a halfway without the
    /// into-every-member check returns the side's normal for top + side + bottom.
    func testOpposingFacesHaveNoHalfway() async throws {
        let top = SIMD3<Double>(0, 0, -1), bottom = SIMD3<Double>(0, 0, 1), side = SIMD3<Double>(-1, 0, 0)
        XCTAssertNil(A.halfway([top, bottom]))
        XCTAssertNil(A.halfway([top, side, bottom]), "★ the sum does not press the top or the bottom")
        XCTAssertNotNil(A.halfway([top, side]))
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await Self.boxFaces(cube)
        let apart = try await cube.pressAim([f.top, f.bottom])
        Self.say("FLEX-AP3 APART cube60 top + bottom: halfway \(apart.halfway.map { "\($0)" } ?? "none") · '\(apart.why ?? "")' · offered \(apart.offered.map(\.label))")
        XCTAssertNil(apart.halfway)
        XCTAssertEqual(apart.why, "These faces face apart \u{00B7} no one direction")
        XCTAssertLessThanOrEqual(apart.why?.count ?? 99, 44, "one line")
        XCTAssertEqual(apart.offered, [], "core builds nothing over faces that do not touch")

        let slab = try await G.openModel(self, try FlexiblePressFixtures.roundedSlabProject(), "rounded slab")
        let st = try await Self.region(slab, load: SIMD3(0, 0, -1))
        let meet = try XCTUnwrap(slab.meet)
        var wall: Int? = nil
        for p in meet.pieces where p.id != st {
            let fr = try await slab.regionFrame(p.id)
            if !fr.valid { wall = p.id; break }
        }
        if let w = wall {
            let a = try await slab.pressAim([st, w])
            Self.say("FLEX-AP3 APART rounded slab top + wall \(w): halfway \(a.halfway.map { "\($0)" } ?? "none") · '\(a.why ?? "")' · offered \(a.offered.map(\.label))")
            XCTAssertNil(a.halfway, "★ a member core cannot frame has no halfway")
            XCTAssertTrue(a.why?.contains("cancel") ?? false, "core's words: \(a.why ?? "")")
        } else {
            Self.say("FLEX-AP3 APART rounded slab: every piece is framed by core (no wrapped wall in this build)")
        }
        // RED: without the check, top + side + bottom gives the side's normal
        var s = SIMD3<Double>.zero
        for l in [top, side, bottom] { s += l }
        XCTAssertEqual(simd_normalize(s), side, "control: the bare sum is the side's normal")
    }

    // MARK: - (8) the degrees box

    /// ★ The degrees box: a number box (FlexNumberBox — keypad + vertical drag) showing the degrees off the SELECTED
    /// target (the stored snap kind when offered, else the first offered target). On the target it scrubs toward the
    /// first member's core normal (an edge) or core's frame X (a tilt); off it, along the great circle through the
    /// arrow. 0 is the target bit for bit; 20 is 20° in that plane; it stops 1° short of edge-on (44° on the cube
    /// edge, 89° on a face); a typed 60 is kept to 44 with the box's own note; a scrub moves in whole degrees; a
    /// commit keeps the snap kind. RED: a box that scrubs in a fixed model-axis plane leaves the members' plane.
    func testTheDegreesBoxScrubsFromTheTarget() async throws {
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await Self.boxFaces(cube)
        let edge = try await cube.pressAim([f.top, f.x])
        let half = try XCTUnwrap(A.selected(nil, offered: edge.offered))
        XCTAssertEqual(half.kind, .halfway, "the target rule: the first offered")
        XCTAssertEqual(A.selected(.face(f.top), offered: edge.offered)?.kind, .halfway, "a legacy snap: the default")
        let box = try XCTUnwrap(A.box(target: half, current: half.direction, fallbacks: edge.fallbacks, loads: edge.memberLoads))
        XCTAssertEqual(edge.box(current: half.direction, snap: .halfway), box, "the set's box is the same rule")
        let topLoad = try await cube.regionFrame(f.top).load
        let xLoad = try await cube.regionFrame(f.x).load
        XCTAssertEqual(box.value, 0)
        XCTAssertEqual(Self.bits(box.direction(0)), Self.bits(half.direction), "★ 0 IS the target")
        let d20 = box.direction(20)
        XCTAssertEqual(Self.deg(d20, half.direction), 20, accuracy: 1e-9)
        XCTAssertLessThan(abs(simd_dot(simd_cross(half.direction, topLoad), d20)), 1e-12, "★ toward the first member's normal")
        XCTAssertLessThan(Self.deg(d20, topLoad), Self.deg(half.direction, topLoad), "toward it, not away")
        XCTAssertEqual(box.limit, 44, accuracy: 1e-6, "1° short of edge-on to the side")
        XCTAssertEqual(Self.deg(box.direction(box.limit), xLoad), 89, accuracy: 1e-6)
        let spec = box.spec
        Self.say("FLEX-AP3 BOX cube edge: \(spec.text)\(spec.unit) range \(spec.range) step \(spec.step) · 20° → \(d20)")
        XCTAssertEqual(spec.unit, "\u{00B0}")
        XCTAssertEqual(spec.range.upperBound, 44, accuracy: 1e-6)
        XCTAssertEqual(spec.typed(60) ?? -1, spec.range.upperBound, accuracy: 1e-12, "a typed 60 is kept to the limit")
        XCTAssertNotNil(spec.typedNote(60, committed: spec.typed(60)), "and the box says so")
        let scrubbed = FlexNumberScrub.scrub(raw: 0, deltaY: -40, spec: spec)
        XCTAssertEqual(scrubbed.shown, scrubbed.shown.rounded(), "a scrub moves in whole degrees")
        XCTAssertGreaterThan(scrubbed.shown, 0, "up = more")
        // off the target: the plane goes through the arrow
        let off = try XCTUnwrap(A.box(target: half, current: d20, fallbacks: edge.fallbacks, loads: edge.memberLoads))
        XCTAssertEqual(off.value, 20, accuracy: 1e-9)
        XCTAssertLessThan(Self.deg(off.direction(20), d20), 1e-9, "the box reads back where it put the arrow")
        // a tilt: core's frame X
        let one = try await cube.pressAim([f.top])
        let st = try XCTUnwrap(A.selected(nil, offered: one.offered))
        XCTAssertEqual(st.kind, .straighten)
        let tb = try XCTUnwrap(A.box(target: st, current: st.direction, fallbacks: one.fallbacks, loads: one.memberLoads))
        let coreX = try await cube.regionFrame(f.top).xAxis
        XCTAssertLessThan(simd_distance(tb.plane, coreX), 1e-12, "★ a tilt scrubs toward core's frame X")
        XCTAssertEqual(tb.limit, 89, accuracy: 1e-6, "1° short of edge-on to the face itself")
        // a commit keeps the snap kind; 0 puts it back on the target exactly
        XCTAssertTrue(cube.press(f.bottom, kg: 5))
        let id = try XCTUnwrap(cube.addPress(regions: [f.top, f.x], direction: half.direction, snap: "halfway", kg: 5))
        XCTAssertTrue(cube.aimPress(id, box.release(20)))
        XCTAssertEqual(cube.press(id)?.snap, "halfway", "★ the box measures from its target: the kind stays")
        XCTAssertEqual(cube.press(id).map { Self.bits($0.direction) }, Self.bits(d20))
        XCTAssertTrue(cube.aimPress(id, box.release(0)))
        XCTAssertEqual(cube.press(id).map { Self.bits($0.direction) }, Self.bits(half.direction), "★ back ON the target")
        // RED: a fixed model-axis plane (toward +X) leaves the members' plane
        let wrong = simd_normalize(cos(20 * Double.pi / 180) * half.direction + sin(20 * Double.pi / 180)
                                   * simd_normalize(SIMD3(0, 1, 0) - simd_dot(SIMD3(0, 1, 0), half.direction) * half.direction))
        XCTAssertGreaterThan(abs(simd_dot(simd_cross(half.direction, topLoad), wrong)), 0.1, "control: a model-axis plane is not the members'")
    }

    // MARK: - (9) the knob never points out of a face

    /// ★ The knob (GravityDirectionGizmo's drag, the knob at the arrow's TAIL) on the cube edge, seen from +Y: a drag
    /// far past the side face is held 1° short of edge-on to it (dot = sin 1°), and core builds what it holds; a drag
    /// 8° off the halfway snaps onto it exactly. Snaps are exempt from the limit (a target inside the 1° band still
    /// lands). RED: a release with no clamp points out of the side face (core refuses it).
    func testTheDragNeverPointsOutOfAFace() async throws {
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await Self.boxFaces(cube)
        let edge = try await cube.pressAim([f.top, f.x])
        let half = try XCTUnwrap(edge.offered.first)
        let anchor = try XCTUnwrap(cube.meet?.anchor(regions: [f.top, f.x], direction: half.direction))
        let view = SIMD3<Double>(0, -1, 0)
        let L = A.arrowLength(boundsDiagonalMM: 60 * 3.0.squareRoot())
        func ray(_ at: SIMD3<Double>) -> PrimitiveGizmo.Ray { PrimitiveGizmo.Ray(origin: at - 500 * view, dir: view) }
        let drag = A.Drag(direction: half.direction, anchor: anchor, length: L, grab: ray(anchor - half.direction * L),
                          viewDir: view, targets: edge.offered, loads: edge.memberLoads)
        XCTAssertLessThan(simd_distance(drag.knob, anchor - half.direction * L), 1e-9, "★ the knob is the TAIL")
        // far past the side (x) face
        let far = drag.step(ray(drag.knob + SIMD3(-2 * L, 0, 0)))
        let pointed = drag.pointed(ray(drag.knob + SIMD3(-2 * L, 0, 0)))
        let xLoad = edge.memberLoads[1]
        Self.say(String(format: "FLEX-AP3 DRAG pointed %.4f° off the side's normal (past edge-on) → held at %.9f°, snap %@",
                     Self.deg(pointed, xLoad), Self.deg(far.direction, xLoad), far.snap?.raw ?? "free"))
        XCTAssertGreaterThan(Self.deg(pointed, xLoad), 90, "premise: the finger points out of the side")
        XCTAssertNil(far.snap)
        XCTAssertEqual(simd_dot(far.direction, xLoad), sin(Double.pi / 180), accuracy: 1e-9, "★ 1° short of edge-on")
        XCTAssertTrue(A.admissible(far.direction, loads: edge.memberLoads))
        let v = try await cube.pressVerdict([f.top, f.x], direction: far.direction)
        XCTAssertTrue(v.accepted, "core builds what the knob holds — \(v.reason)")
        // 8° off the halfway: exact
        let nearTail = anchor - Self.tilt(half.direction, by: 8, toward: SIMD3(1, 0, -1)) * L
        let snap = drag.step(ray(nearTail))
        XCTAssertEqual(snap.snap, .halfway)
        XCTAssertEqual(Self.bits(snap.direction), Self.bits(half.direction), "★ on the halfway, bit for bit")
        // snaps are exempt: a target 0.5° short of edge-on still lands
        let load = SIMD3<Double>(0, 0, -1)
        let banded = A.Target(kind: .buildDown, direction: Self.tilt(SIMD3(1, 0, 0), by: 0.5, toward: load))
        XCTAssertFalse(A.admissible(banded.direction, loads: [load]), "premise: inside the 1° band")
        let r = A.release(Self.tilt(banded.direction, by: 3, toward: load), from: load, targets: [banded], loads: [load])
        XCTAssertEqual(Self.bits(r.direction), Self.bits(banded.direction), "★ snaps are exempt")
        // RED: no clamp
        let bare = try await cube.pressVerdict([f.top, f.x], direction: pointed)
        XCTAssertFalse(bare.accepted, "control: unclamped, it points out of the side and core refuses")
    }

    // MARK: - (10) the trackball

    /// Looking ALONG the arrow (|view · arrow| > 0.9) the knob is a screen trackball: 0.5° per point, then snapped
    /// or clamped like the knob. At 30° off the arrow it is the knob again. RED: the knob alone cannot tilt an arrow
    /// seen end-on (its drag plane faces the arrow: a sideways drag moves the tail along the arrow's own line).
    func testLookingAlongTheArrowTheKnobIsATrackball() {
        let d = simd_normalize(SIMD3<Double>(-1, 0, -1))
        XCTAssertTrue(A.isTrackball(viewDir: d, direction: d), "end-on")
        XCTAssertTrue(A.isTrackball(viewDir: Self.tilt(d, by: 20), direction: d), "20° off: |cos| 0.94")
        XCTAssertFalse(A.isTrackball(viewDir: Self.tilt(d, by: 30), direction: d), "30° off: the knob")
        let up = SIMD3<Double>(0, 1, 0), right = simd_normalize(simd_cross(d, up))
        let tb = A.Trackball(direction: d, right: right, up: up, targets: [], loads: [])
        let moved = tb.step(dx: 10, dy: 0)
        XCTAssertEqual(Self.deg(moved.direction, d), 5, accuracy: 1e-9, "★ 0.5° per point")
        XCTAssertEqual(Self.deg(tb.step(dx: 0, dy: 10).direction, d), 5, accuracy: 1e-9)
        let snapped = A.Trackball(direction: Self.tilt(d, by: 6, toward: up), right: right, up: up,
                                  targets: [A.Target(kind: .halfway, direction: d)], loads: []).step(dx: 1, dy: 0)
        XCTAssertEqual(Self.bits(snapped.direction), Self.bits(d), "it snaps like the knob")
        // RED: the knob end-on — a sideways drag on the plane facing the arrow barely turns it
        let anchor = SIMD3<Double>(0, 0, 0)
        let drag = A.Drag(direction: d, anchor: anchor, length: 30, grab: PrimitiveGizmo.Ray(origin: -d * 30 - d * 500, dir: d),
                          viewDir: d, targets: [], loads: [])
        let knob = drag.pointed(PrimitiveGizmo.Ray(origin: -d * 30 - d * 500 + SIMD3(0, 0.5, 0), dir: d))
        Self.say(String(format: "FLEX-AP3 TRACKBALL end-on: a 0.5 mm knob drag turns the arrow %.3f°, the trackball 10 pt %.3f°",
                     Self.deg(knob, d), Self.deg(moved.direction, d)))
    }

    // MARK: - (11) the camera across the arrow

    /// ★ D-AP-13. His r5 corner (Top A + 3 + 2) seen from the home view (azimuth 45°, elevation 30°) is nearly
    /// end-on; cameraAcross picks a view at least 50° off the arrow's line, nearest the members' outward side, and
    /// the arrow keeps 60 pt (it grows up to 2×). RED: cameraRegion(load:) looks straight along the arrow (under 10°).
    func testTheCameraLooksAcrossTheArrow() async throws {
        let r5 = try FlexiblePressFixtures.hisRound5(self)
        let rm = try await G.openModel(self, r5.project, "his r5")
        let corner = [FlexibleHisProject.topA, 3, 2]
        let aim = try await rm.pressAim(corner)
        let h = try XCTUnwrap(aim.halfway)
        let settle = simd_quatf(from: SIMD3<Float>(0, 0, -1), to: SIMD3<Float>(0, -1, 0))   // gravity −Z → down
        let line = simd_normalize(settle.act(SIMD3<Float>(Float(h.x), Float(h.y), Float(h.z))))
        func off(_ v: SIMD3<Float>) -> Float { acos(min(1, abs(simd_dot(simd_normalize(v), line)))) * 180 / .pi }
        let home = SIMD3<Float>(cos(Float.pi / 6) * sin(Float.pi / 4), sin(Float.pi / 6), cos(Float.pi / 6) * cos(Float.pi / 4))
        let across = try XCTUnwrap(FlexibleFixPopup.cameraAcross(arrow: h, memberLoads: aim.memberLoads, settle: settle))
        let naive = try XCTUnwrap(FlexibleFixPopup.cameraRegion(load: h, settle: settle))
        Self.say(String(format: "FLEX-AP3 CAMERA r5 corner: home %.1f° off the arrow · cameraAcross %@ %.1f° · cameraRegion(load:) %@ %.1f°",
                     off(home), across.id, off(across.direction), naive.id, off(naive.direction)))
        XCTAssertGreaterThanOrEqual(off(across.direction), 50 - 1e-4, "★ across the arrow")
        var out = SIMD3<Float>.zero
        for l in aim.memberLoads { out -= settle.act(SIMD3<Float>(Float(l.x), Float(l.y), Float(l.z))) }
        XCTAssertGreaterThan(simd_dot(across.direction, simd_normalize(out)), 0, "it sees the members' outside")
        XCTAssertLessThan(off(naive.direction), 10, "control: the face-on rule looks along it")
        // 60 pt on screen
        XCTAssertEqual(A.arrowLength(boundsDiagonalMM: 100), 25)
        XCTAssertEqual(A.arrowLength(boundsDiagonalMM: 20), 15)
        XCTAssertEqual(A.arrowLength(boundsDiagonalMM: 1000), 80)
        XCTAssertEqual(A.arrowLength(boundsDiagonalMM: 100, pointsPerMM: 1), 50, "grown, at most 2×")
        XCTAssertEqual(A.arrowLength(boundsDiagonalMM: 100, pointsPerMM: 2), 30, accuracy: 1e-12, "grown to 60 pt")
        XCTAssertEqual(A.arrowLength(boundsDiagonalMM: 100, pointsPerMM: 3), 25, "already 75 pt")
    }

    // MARK: - (12) the snap kind is saved

    /// ★ The snap kind is stored on AP1's FlexiblePress (its optional `snap`, no migration): "halfway",
    /// "straighten", "build:down", "build:up" round-trip; AP1's "face:3" and "build" still decode; a free release
    /// omits the key. [Straighten] on a tilted press puts the face back where it sat, its settings intact (the job
    /// as before the tilt). RED: a store through Float changes the bits.
    func testTheSnapKindIsSavedWithThePress() async throws {
        for raw in ["halfway", "straighten", "build:down", "build:up", "face:3", "build"] {
            XCTAssertEqual(FlexiblePress.Snap(raw)?.raw, raw, "\(raw) round-trips")
        }
        XCTAssertNil(FlexiblePress.Snap("sideways"))
        let block = try await G.openModel(self, try Self.chamferProject(), "chamfer block")
        let s2 = 1 / 2.0.squareRoot()
        let t = try await Self.region(block, load: SIMD3(0, 0, -1)), c = try await Self.region(block, load: SIMD3(-s2, 0, -s2))
        let bottom = try await Self.region(block, load: SIMD3(0, 0, 1))
        XCTAssertTrue(block.press(bottom, kg: 5))
        let aim = try await block.pressAim([t, c])
        XCTAssertEqual(aim.offered.map(\.kind), [.halfway, .buildDown])
        var ids: [(UUID, A.Target)] = []
        for target in aim.offered {
            let id = try XCTUnwrap(block.addPress(regions: [t, c], direction: Self.tilt(target.direction, by: 30), snap: nil, kg: 5))
            XCTAssertTrue(block.aimPress(id, A.chip(target)))
            ids.append((id, target))
        }
        let free = try XCTUnwrap(block.addPress(regions: [t, c], direction: Self.tilt(aim.offered[0].direction, by: 20), snap: "halfway", kg: 5))
        XCTAssertTrue(block.aimPress(free, A.Release(direction: Self.tilt(aim.offered[0].direction, by: 25), snap: nil)))
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = try enc.encode(block.settings)
        let back = try JSONDecoder().decode(FlexibleStageSettings.self, from: data)
        for (id, target) in ids {
            let p = try XCTUnwrap(back.press(id))
            XCTAssertEqual(p.snap, target.kind.raw, "★ the kind is saved")
            XCTAssertEqual(Self.bits(p.direction), Self.bits(target.direction), "★ the target's bits, through the file")
        }
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let presses = try XCTUnwrap(json["presses"] as? [[String: Any]])
        Self.say("FLEX-AP3 SAVE snaps in the file: \(presses.map { $0["snap"] as? String ?? "—" })")
        XCTAssertEqual(presses.map { $0["snap"] as? String }, ["halfway", "build:down", nil], "a free release omits it")
        XCTAssertNil(back.press(free)?.snap)

        // [Straighten]: a tilted face goes back where it sat, intact
        let before = block.settings.faces
        let up = try await Self.region(block, load: SIMD3(-1, 0, 0))   // the x = 50 side
        XCTAssertTrue(block.press(up, kg: 3))
        let pressed = block.settings.faces
        let one = try await block.pressAim([up])
        let st = try XCTUnwrap(one.offered.first { $0.kind == .straighten })
        let tilted = try XCTUnwrap(block.tilt(up, direction: Self.tilt(st.direction, by: 15), snap: nil))
        XCTAssertNil(block.settings.face(up), "premise: the face is a press now")
        XCTAssertTrue(block.aimPress(tilted, A.chip(st)))
        XCTAssertNil(block.press(tilted), "★ [Straighten]: the press is gone")
        XCTAssertEqual(block.settings.faces, pressed, "★ the face is back where it sat, its settings intact")
        XCTAssertNotEqual(before, pressed, "premise: the press added a face")
        // RED: a direction stored through Float
        let viaFloat = SIMD3<Double>(SIMD3<Float>(aim.offered[0].direction))
        XCTAssertNotEqual(Self.bits(viaFloat), Self.bits(aim.offered[0].direction), "control: through Float it is not the target")
    }

    // MARK: - (13) a one-region press over 2+ faces

    /// ★ Spec §6 (critique core-purity 7): a ONE-region press whose region spans 2+ faces (a Surface cut of a union,
    /// "faces 1+3 · A") takes its halfway over its MEMBER FACES, each framed by core with the region's cuts
    /// (face_frame_cut of that face's triangles, clipped) — 45.00° from each on C1's pad, top + x = 100 side cut at
    /// y = 50. Its [Straighten] is core's own load of the whole region (area-weighted), offered beside the halfway
    /// (both built by core). CONTROL (run here): that own load is 11.31° from the top, not 45° — the region's frame is
    /// not the halfway. (Added in the implementation commit, after the tests-first red run; its control runs here.)
    func testAMultiFaceRegionsHalfwayRunsOverItsFaces() async throws {
        let pm = try FlexiblePressFixtures.padProject()
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let top = FlexibleSquishFixture.face(mesh, axis: 2, value: 20), side = FlexibleSquishFixture.face(mesh, axis: 0, value: 100)
        var model = FaceRegionModel()
        let whole = model.union(faces: [FaceID(top), FaceID(side)], named: "top+side")
        let kids = model.splitManual(whole, point: SIMD3(50, 50, 10), normal: SIMD3(0, 1, 0))
        pm.faceRegions = model
        let m = try await G.openModel(self, pm, "C1 pad, top + side cut at y = 50")
        let sector = try XCTUnwrap(kids.map { FlexibleRegions.sectorBase + $0 }.first)
        let faces = m.regions.faces(of: sector, mesh: m.project.viewerMesh)
        XCTAssertEqual(Set(faces), [top, side], "premise: one region over two faces")
        let aim = try await m.pressAim([sector])
        let h = try XCTUnwrap(aim.halfway, aim.why ?? "")
        var line = "FLEX-AP3 MULTIFACE \(m.name(sector)) faces \(faces):"
        for f in faces {
            let load = try await m.regionFrame(sector, face: f).load   // core's, clipped by the region's cuts
            line += String(format: " face %d %.2f°", f, Self.deg(h, load))
            XCTAssertEqual(Self.deg(h, load), 45, accuracy: 1e-9, "★ 45.00° from face \(f), core's normal of that face")
        }
        let own = try await m.regionFrame(sector).load
        let topLoad = try await m.regionFrame(sector, face: top).load
        line += String(format: " · its own core load %.2f° from the top · asked %@ · offered %@", Self.deg(own, topLoad),
                       aim.asked.map { "\($0.target.label) \($0.accepted ? "built" : "refused")" }.joined(separator: ", "),
                       aim.offered.map(\.label).joined(separator: ", "))
        Self.say(line)
        XCTAssertEqual(aim.offered.map(\.kind), [.straighten, .halfway], "★ its straighten and its halfway, both built")
        XCTAssertEqual(aim.offered.first.map { Self.bits($0.direction) }, Self.bits(own + SIMD3(repeating: 0)))
        XCTAssertEqual(Self.deg(own, topLoad), 11.31, accuracy: 0.01, "control: the region's own frame is area-weighted")
        XCTAssertGreaterThan(Self.deg(own, h), 30, "control: and not the halfway")
    }
}
