// FlexiblePressAimReviewTests — the AP3 verifiers' findings, confirmed and fixed (task 2026-10-07, angled presses,
// batch AP3 REVIEW; FlexiblePressAim / FlexibleStageModel+Aim).
//
//   (1) BLOCKER: the degrees box on a TILTED face press tilts it. It straightened it: the box measures from
//       [Straighten], so every commit carried that kind, and aimPress read ANY release of that kind as the command;
//   (2) every free direction the app allows (the knob's clamp, the box's limit) is one core builds, on curved members
//       too (M2's corners #11 [33, 34, 57] and #12 [34, 36, 56], the one-fillet slab's wrapped wall): the 1° limit is
//       held against core's normal of EVERY triangle core checks, not each member's average;
//   (3) core's refusals read as ONE plain line of at most 44 characters in the app's names; core's sentence, its
//       sector ids renamed, stays behind the (i);
//   (4) [Straighten] is offered only where core builds it BOTH ways — the face press it turns back into, and the
//       stated direction it stores when it stays a press (a face that wraps past 180°: core refuses the latter);
//   (5) the screen shows a snap only while the arrow IS on its target (D-AP3-1);
//   (6) a target core builds inside the 1° band leaves the box and the knob free (they keep its own margin).
//
// Each test runs its RED control against the instrument the finding names, so a green run also shows each check can
// fail. STEP parts need OCCT: a part the importer refuses is a COUNTED skip ("FLEX-AP SKIP …"), never a pass.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePressAimReviewTests: XCTestCase {
    typealias G = FlexibleAngledGoldens
    typealias A = FlexiblePressAim
    typealias T = FlexiblePressAimTests

    static func say(_ s: String) { T.say(s) }

    /// `n` directions spread evenly over the sphere (a Fibonacci lattice): the same set on every run.
    static func sphere(_ n: Int) -> [SIMD3<Double>] {
        let golden = Double.pi * (3 - 5.0.squareRoot())
        return (0..<n).map { i in
            let y = 1 - 2 * (Double(i) + 0.5) / Double(n)
            let r = (1 - y * y).squareRoot()
            let a = golden * Double(i)
            return SIMD3(r * cos(a), y, r * sin(a))
        }
    }

    /// A 270° pie (r 20 mm, 20 mm tall): its curved wall is ONE pseudo-face whose normals spread past 180°.
    static func pieProject() throws -> ProjectModel {
        var outline: [SIMD2<Double>] = [SIMD2(0, 0)]
        let n = 48, r = 20.0
        for k in 0...n {
            let a = (-135.0 + 270.0 * Double(k) / Double(n)) * .pi / 180
            outline.append(SIMD2(r * cos(a), r * sin(a)))
        }
        let path = try FlexiblePressFixtures.write("pie270.stl",
                                                   FlexiblePressFixtures.asciiSTL("pie270", FlexiblePressFixtures.extrudedTriangles(outline, height: 20)))
        return try FlexiblePressFixtures.project(path: path, name: "pie 270")
    }

    // MARK: - (1) the degrees box on a tilted face press

    /// ★ BLOCKER. His top face, tilted 15°: the box measures from [Straighten] and shows 15. He types 20: the press
    /// STAYS, 20° off, bit for bit box.direction(20), its kind kept ("straighten" — what the box measures from,
    /// D-AP3-1); 10 keeps it too. The box at 0, the [Straighten] chip and a knob snap onto it turn it back into the
    /// face, intact. RED (the AP3 code): the 20 straightened the press away and lost the tilt.
    func testTheDegreesBoxTiltsATiltedFacePress() async throws {
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await T.boxFaces(cube)
        XCTAssertTrue(cube.press(f.bottom, kg: 5))
        XCTAssertTrue(cube.press(f.top, kg: 3))
        let faceBefore = try XCTUnwrap(cube.settings.face(f.top))
        let one = try await cube.pressAim([f.top])
        let st = try XCTUnwrap(one.offered.first { $0.kind == .straighten })
        let away = SIMD3<Double>(1, 0, 0)
        func tilted(_ deg: Double) throws -> UUID {
            try XCTUnwrap(cube.tilt(f.top, direction: T.tilt(st.direction, by: deg, toward: away), snap: nil), "premise: the top tilts")
        }
        let id = try tilted(15)
        let p15 = try XCTUnwrap(cube.press(id))
        let box = try XCTUnwrap(one.box(current: p15.direction, snap: p15.snapTarget))
        XCTAssertEqual(box.target.kind, .straighten, "premise: a tilt's box measures from [Straighten]")
        XCTAssertEqual(box.value, 15, accuracy: 1e-9)
        let r20 = box.release(20)
        XCTAssertFalse(r20.exact, "20° off its target is not exact")
        XCTAssertTrue(cube.aimPress(id, r20))
        let p20 = cube.press(id)
        Self.say("FLEX-AP3R BOX tilt 15° → box 20: " + (p20.map { String(format: "press kept, %.9f° off straight, snap %@", T.deg($0.direction, st.direction), $0.snap ?? "nil") }
                                                         ?? "press GONE — the face is back: \(cube.settings.face(f.top) != nil)"))
        let kept = try XCTUnwrap(p20, "★ the box's 20° keeps the tilt")
        XCTAssertEqual(T.bits(kept.direction), T.bits(box.direction(20)), "★ the typed 20°, bit for bit")
        XCTAssertEqual(T.deg(kept.direction, st.direction), 20, accuracy: 1e-9)
        XCTAssertEqual(kept.snap, "straighten", "the box measures from [Straighten]: the kind stays (D-AP3-1)")
        XCTAssertNil(cube.settings.face(f.top), "the face is still a press")
        // less tilt, from the press as stored
        let box20 = try XCTUnwrap(one.box(current: kept.direction, snap: kept.snapTarget))
        XCTAssertEqual(box20.value, 20, accuracy: 1e-9)
        XCTAssertTrue(cube.aimPress(id, box20.release(10)))
        let p10 = try XCTUnwrap(cube.press(id), "★ 10° keeps the tilt too")
        XCTAssertEqual(T.deg(p10.direction, st.direction), 10, accuracy: 1e-9)
        // the box at 0 IS [Straighten]: the face goes back, intact
        let box10 = try XCTUnwrap(one.box(current: p10.direction, snap: p10.snapTarget))
        let r0 = box10.release(0)
        XCTAssertTrue(r0.exact, "0 is the target, bit for bit")
        XCTAssertEqual(T.bits(r0.direction), T.bits(st.direction))
        XCTAssertTrue(cube.aimPress(id, r0))
        XCTAssertNil(cube.press(id), "★ the box at 0 straightens")
        XCTAssertEqual(cube.settings.face(f.top), faceBefore, "★ the face is back, its settings intact")
        // the chip, and a knob snap onto [Straighten]
        let id2 = try tilted(15)
        XCTAssertTrue(cube.aimPress(id2, A.chip(st)))
        XCTAssertNil(cube.press(id2), "★ the [Straighten] chip straightens")
        let id3 = try tilted(15)
        let knob = A.release(T.tilt(st.direction, by: 8, toward: SIMD3(0, 1, 0)), from: T.tilt(st.direction, by: 15, toward: away),
                             targets: one.offered, loads: one.footprintNormals)
        XCTAssertEqual(knob.snap, .straighten)
        XCTAssertTrue(knob.exact, "a knob snap is exact")
        XCTAssertTrue(cube.aimPress(id3, knob))
        XCTAssertNil(cube.press(id3), "★ a knob snap onto [Straighten] straightens")
        XCTAssertEqual(cube.settings.face(f.top), faceBefore)
        // a free knob release keeps the press, with no kind
        let id4 = try tilted(15)
        let free = A.release(T.tilt(st.direction, by: 30, toward: away), from: T.tilt(st.direction, by: 15, toward: away),
                             targets: one.offered, loads: one.footprintNormals)
        XCTAssertNil(free.snap)
        XCTAssertFalse(free.exact)
        XCTAssertTrue(cube.aimPress(id4, free))
        XCTAssertEqual(cube.press(id4).map { T.bits($0.direction) }, T.bits(free.direction), "a free release is stored")
    }

    // MARK: - (2) every direction the app allows is one core builds

    /// ★ MAJOR. From the default arrow, the knob is dragged toward 64 directions spread over the sphere and the box is
    /// taken to its limit on planes through the first 16: core builds EVERY direction the app allows — on the
    /// one-fillet slab's top + the wall that wraps its fillet (flat, fillet, flat: one pseudo-face) and on the M2's
    /// corners #11 [33, 34, 57] and #12 [34, 36, 56] (counted skip without OCCT). The limit holds against core's
    /// inward normal of every triangle core checks (each member's member faces, as build_press_stack does). RED
    /// CONTROL (run here): the same drags and boxes held against each member's AVERAGE normal (the AP3 rule) give
    /// directions core refuses, on the slab alone and on the M2.
    func testEveryDirectionTheAppAllowsIsOneCoreBuilds() async throws {
        var cases: [(String, FlexibleStageModel, [Int])] = []
        let slab = try await G.openModel(self, try FlexiblePressFixtures.oneFilletSlabProject(), "one-fillet slab")
        let top = try await T.region(slab, load: SIMD3(0, 0, -1))
        var wall: Int? = nil
        for p in try XCTUnwrap(slab.meet).pieces where p.id != top {
            let fr = try await slab.regionFrame(p.id)
            if fr.valid, abs(fr.load.z) < 1e-9, fr.normalSpreadDeg > 45 { wall = p.id; break }
        }
        let w = try XCTUnwrap(wall, "premise: the slab's side wraps its fillet (one pseudo-face)")
        cases.append(("one-fillet slab top + wrapped wall", slab, [top, w]))
        var skips: [String] = []
        do {
            let m2 = try await G.openModel(self, try FlexiblePressFixtures.m2Project("FlexiblePressAimReviewTests.testEveryDirectionTheAppAllowsIsOneCoreBuilds"), "M2 stand")
            let c = try await m2.edgeCandidates()
            for (n, want) in [(11, [33, 34, 57]), (12, [34, 36, 56])] {
                let k = try XCTUnwrap(c.candidates.first { $0.number == n }, "M2 has a candidate #\(n)")
                XCTAssertEqual(Set(k.members), Set(want), "premise: M2 corner #\(n) is the verifier's")
                cases.append(("M2 corner #\(n) \(k.members)", m2, k.members))
            }
        } catch let s as XCTSkip {
            skips.append("M2: \(s.message ?? "skipped")")
        }
        let far = Self.sphere(64)
        var refusedTotal = 0, askedTotal = 0, controlTotal = 0, slabControl = 0
        for (label, m, regions) in cases {
            let aim = try await m.pressAim(regions)
            let def = try XCTUnwrap(aim.defaultRelease, "\(label): a default arrow (\(aim.why ?? ""))")
            let target = try XCTUnwrap(A.selected(def.snap, offered: aim.offered))
            XCTAssertGreaterThan(aim.footprintNormals.count, aim.memberLoads.count, "\(label): core's normal of every footprint triangle")
            var dirs: [(String, SIMD3<Double>)] = [], ctrl: [(String, SIMD3<Double>)] = []
            for d in far {
                let r = A.release(d, from: def.direction, targets: aim.offered, loads: aim.footprintNormals)
                if r.snap == nil { dirs.append(("knob", r.direction)) }
                let c = A.release(d, from: def.direction, targets: aim.offered, loads: aim.memberLoads)
                if c.snap == nil { ctrl.append(("knob", c.direction)) }
            }
            for (_, d) in dirs.prefix(16) {
                if let b = aim.box(current: d, snap: def.snap), b.limit > 0 { dirs.append(("box limit", b.direction(b.limit))) }
            }
            for (_, d) in ctrl.prefix(16) {
                if let b = A.box(target: target, current: d, fallbacks: aim.fallbacks, loads: aim.memberLoads), b.limit > 0 {
                    ctrl.append(("box limit", b.direction(b.limit)))
                }
            }
            var bad: [String] = []
            for (kind, d) in dirs {
                let v = try await m.pressVerdict(regions, direction: d)
                askedTotal += 1
                if !v.accepted { bad.append("\(kind) \(d): \(v.reason)") }
            }
            var controlBad: [String] = []
            for (kind, d) in ctrl {
                let v = try await m.pressVerdict(regions, direction: d)
                if !v.accepted { controlBad.append("\(kind): \(m.plainLine(v.reason))") }
            }
            refusedTotal += bad.count
            controlTotal += controlBad.count
            if m === slab { slabControl = controlBad.count }
            Self.say("FLEX-AP3R ALLOW \(label): \(aim.footprintNormals.count) footprint normals (members \(aim.memberLoads.count)) · "
                     + "\(dirs.count) allowed directions asked, core refused \(bad.count) · CONTROL by members' averages: \(ctrl.count) asked, core refused \(controlBad.count)"
                     + (controlBad.isEmpty ? "" : " — e.g. " + controlBad.prefix(2).joined(separator: "; ")))
            XCTAssertEqual(bad.count, 0, "★ \(label): every direction the app allows is built by core — " + bad.prefix(3).joined(separator: " | "))
        }
        Self.say("FLEX-AP3R ALLOW totals: \(askedTotal) allowed directions, core refused \(refusedTotal) · control refused \(controlTotal) · STEP skips \(skips.count)"
                 + (skips.isEmpty ? "" : " — " + skips.joined(separator: "; ")))
        XCTAssertGreaterThan(slabControl, 0, "control: held by each member's average, the slab's drags pull on its wrapped wall")
        if skips.isEmpty { XCTAssertGreaterThan(controlTotal, slabControl, "control: and on the M2's corners") }
    }

    // MARK: - (3) core's refusals in plain words

    /// ★ MAJOR. Core's refusal of a press reads as ONE plain line of at most 44 characters in the app's names, with
    /// no "press_direction" and no raw "face region N"; core's sentence stays behind the (i), its sector ids renamed
    /// ("face region 1000103" → his Top A). His r5 edge Top A + 3 pressed along face 3's normal (edge-on to Top A);
    /// every refused target on the cube, his r5 and A1_0003 edges and corners; the rounded slab's wall that has no
    /// core normal (`why` ≤ 44, core's words in `whyDetail`). RED CONTROL: core's own sentence is 118+ characters.
    func testCoreRefusalsReadAsOnePlainLine() async throws {
        let r5 = try FlexiblePressFixtures.hisRound5(self)
        let rm = try await G.openModel(self, r5.project, "his r5")
        let topA = FlexibleHisProject.topA
        let edge = [topA, 3]
        let side = try await rm.regionFrame(3).load
        let v = try await rm.pressVerdict(edge, direction: side)
        XCTAssertFalse(v.accepted, "premise: along face 3's normal, Top A is edge-on")
        XCTAssertTrue(v.reason.contains("face region \(topA)"), "premise: core names the sector by its id — \(v.reason)")
        let detail = rm.text(v.reason), line = rm.plainLine(v.reason)
        Self.say("FLEX-AP3R WORDS r5 edge along face 3's normal: core '\(v.reason)' (\(v.reason.count)) → (i) '\(detail)' → line '\(line)' (\(line.count))")
        XCTAssertGreaterThan(v.reason.count, 44, "control: core's own sentence does not fit one line")
        XCTAssertFalse(detail.contains("face region \(topA)"), "★ the (i) names the sector the app's way")
        XCTAssertTrue(detail.contains(rm.name(topA)), "★ … as the app names it: \(detail)")
        XCTAssertLessThanOrEqual(line.count, 44, "★ one line")
        XCTAssertFalse(line.contains("press_direction"), "★ plain words")
        XCTAssertFalse(line.contains("face region"), "★ the app's names")
        XCTAssertTrue(line.contains(rm.displayName(topA)), "★ it names Top A: \(line)")

        // every refused target, on the AP3 fixtures
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await T.boxFaces(cube)
        let a1 = try FlexiblePressFixtures.a1Project(3, self)
        let am = try await G.openModel(self, a1.project, "A1_0003")
        let ats = try await T.a1TopSide(am)
        var lines = 0
        for (label, m, regions) in [("cube60 edge", cube, [f.top, f.x]), ("cube60 corner", cube, [f.top, f.x, f.y]), ("cube60 top", cube, [f.top]),
                                    ("his r5 edge", rm, edge), ("his r5 corner", rm, [topA, 3, 2]),
                                    ("A1_0003 edge", am, ats.edge), ("A1_0003 corner", am, ats.corner)] {
            let aim = try await m.pressAim(regions)
            for a in aim.asked where !a.accepted {
                lines += 1
                Self.say("FLEX-AP3R WORDS \(label) \(a.target.label): '\(a.line)' (\(a.line.count)) · (i) '\(a.reason)'")
                XCTAssertLessThanOrEqual(a.line.count, 44, "★ \(label) \(a.target.label): one line")
                XCTAssertFalse(a.line.isEmpty, "\(label) \(a.target.label): a line")
                XCTAssertFalse(a.line.contains("press_direction") || a.line.contains("face region"), "★ \(label): plain words — \(a.line)")
                XCTAssertFalse(a.reason.isEmpty, "core's words behind the (i)")
                XCTAssertFalse(a.reason.contains("face region 100"), "★ no raw sector id behind the (i) either")
            }
        }
        XCTAssertGreaterThan(lines, 0, "premise: core refuses some asked targets")

        // `why`: a member core cannot frame
        let slab = try await G.openModel(self, try FlexiblePressFixtures.roundedSlabProject(), "rounded slab")
        let st = try await T.region(slab, load: SIMD3(0, 0, -1))
        var wall: Int? = nil
        for p in try XCTUnwrap(slab.meet).pieces where p.id != st {
            if !(try await slab.regionFrame(p.id)).valid { wall = p.id; break }
        }
        if let w = wall {
            let a = try await slab.pressAim([st, w])
            Self.say("FLEX-AP3R WORDS rounded slab top + wall \(w): why '\(a.why ?? "")' (\(a.why?.count ?? 0)) · (i) '\(a.whyDetail ?? "")'")
            XCTAssertLessThanOrEqual(a.why?.count ?? 99, 44, "★ `why` is one line")
            XCTAssertFalse(a.why?.contains("(") ?? true, "★ plain words")
            XCTAssertTrue(a.whyDetail?.contains("cancel") ?? false, "core's words behind the (i): \(a.whyDetail ?? "")")
        } else {
            Self.say("FLEX-AP3R WORDS rounded slab: every piece is framed by core (no wrapped wall in this build)")
        }
        // the pure rule, on every sentence core's press can refuse with
        let names: (Int) -> String = { $0 == 7 ? "A sector with a very long name indeed" : "Face \($0)" }
        for s in ["press_direction does not point into the part over face region 7: part of it faces along the direction or edge-on to it",
                  "face region 3 and face region 7 are not adjacent (no shared edge); an edge or corner press needs one connected footprint",
                  "face region 3 and face region 7 are sectors of the SAME face in one press; give the press one region for that face",
                  "face region 7 appears twice in one press",
                  "face region 7: the face's normals cancel out (no single direction to push along)",
                  "face region 7: the region's cuts leave nothing of its faces",
                  "face region 7 has no column at a 1.5 mm pitch",
                  "press_direction must be a finite, non-zero vector",
                  "something core says one day"] {
            let l = A.plainLine(s, name: names)
            Self.say("FLEX-AP3R WORDS rule: '\(l)' (\(l.count)) ← '\(s)'")
            XCTAssertLessThanOrEqual(l.count, 44, "★ one line: \(l)")
            XCTAssertFalse(l.contains("press_direction") || l.contains("face region") || l.contains("("), "★ plain: \(l)")
        }
    }

    // MARK: - (4) [Straighten] only where core builds it both ways

    /// ★ MINOR (2). [Straighten] is asked as the face press it turns back into (no direction) AND as the direction it
    /// stores when it stays a press (its own core normal, stated); it is offered only when core builds both. On the
    /// pie's wall (its normals spread past 180°) core presses the face along its own default but refuses that
    /// default stated: [Straighten] is NOT offered there, and its line says why. On a flat face both are built and it
    /// is offered (positive control). Every OFFERED target, stated exactly as a release stores it, is built.
    func testStraightenIsOfferedOnlyWhereCoreBuildsItBothWays() async throws {
        let pie = try await G.openModel(self, try Self.pieProject(), "pie 270")
        var wrapped: Int? = nil
        for p in try XCTUnwrap(pie.meet).pieces {
            let fr = try await pie.regionFrame(p.id)
            if fr.valid, fr.normalSpreadDeg > 100 { wrapped = p.id; break }
        }
        let w = try XCTUnwrap(wrapped, "premise: the pie's wall is one face spread past 100°")
        let aim = try await pie.pressAim([w])
        let st = try XCTUnwrap(aim.asked.first { $0.target.kind == .straighten })
        let asFace = try await pie.pressVerdict([w], direction: nil)
        let stated = try await pie.pressVerdict([w], direction: st.target.direction)
        Self.say("FLEX-AP3R STRAIGHTEN pie wall \(w): as a face \(asFace.accepted ? "built" : "refused") · stated \(stated.accepted ? "built" : "refused '\(stated.reason)'") → asked "
                 + aim.asked.map { "\($0.target.label) \($0.accepted ? "built" : "refused '\($0.line)'")" }.joined(separator: " · ") + " → offered \(aim.offered.map(\.label))")
        XCTAssertTrue(asFace.accepted, "premise: core presses the wrapped face along its own default")
        XCTAssertFalse(stated.accepted, "premise: that default, stated, is edge-on to part of the wall")
        XCTAssertFalse(st.accepted, "★ [Straighten] is not offered where its stored direction is refused")
        XCTAssertFalse(aim.offered.contains { $0.kind == .straighten })
        XCTAssertNotEqual(aim.defaultRelease?.snap, .straighten, "★ nor a new press's default")
        XCTAssertFalse(st.line.isEmpty, "its line says why")
        XCTAssertLessThanOrEqual(st.line.count, 44)
        // positive control: a flat face
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await T.boxFaces(cube)
        let flat = try await cube.pressAim([f.top])
        XCTAssertEqual(flat.offered.first?.kind, .straighten, "control: on a flat face it is offered")
        // every OFFERED target, stated as a release stores it
        let block = try await G.openModel(self, try FlexiblePressAimTests.chamferProject(), "chamfer block")
        let s2 = 1 / 2.0.squareRoot()
        let bt = try await T.region(block, load: SIMD3(0, 0, -1)), bc = try await T.region(block, load: SIMD3(-s2, 0, -s2))
        var n = 0
        for (label, m, regions) in [("pie wall", pie, [w]), ("cube top", cube, [f.top]), ("cube edge", cube, [f.top, f.x]),
                                    ("chamfer edge", block, [bt, bc]), ("chamfer face", block, [bc])] {
            let a = try await m.pressAim(regions)
            for t in a.offered {
                let v = try await m.pressVerdict(t.kind == .straighten ? [regions[0]] : regions, direction: A.chip(t).direction)
                n += 1
                XCTAssertTrue(v.accepted, "★ \(label) \(t.label), stated as stored: \(v.reason)")
            }
        }
        Self.say("FLEX-AP3R STRAIGHTEN every offered target stated as stored: \(n) asked")
    }

    // MARK: - (5) shown snapped only while ON the target

    /// ★ MINOR (D-AP3-1). The screen lights a chip (and the badge) from `on(direction)`: the offered target the
    /// arrow IS on, bit for bit. The box tilts an edge press 20° off its halfway: the stored kind stays "halfway"
    /// (what the box measures from) and `on` is nil; the box at 0 is on it again; one ulp off is not. RED (the
    /// AP3 stub reading the stored kind): it says "Halfway" 20° away.
    func testTheArrowShowsSnappedOnlyOnItsTarget() async throws {
        let cube = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = try await T.boxFaces(cube)
        let edge = try await cube.pressAim([f.top, f.x])
        let half = try XCTUnwrap(edge.offered.first)
        XCTAssertEqual(edge.on(half.direction)?.kind, .halfway, "on the halfway")
        XCTAssertTrue(cube.press(f.bottom, kg: 5))
        let id = try XCTUnwrap(cube.addPress(regions: [f.top, f.x], direction: half.direction, snap: "halfway", kg: 5))
        let box = try XCTUnwrap(edge.box(current: half.direction, snap: .halfway))
        XCTAssertTrue(cube.aimPress(id, box.release(20)))
        let p = try XCTUnwrap(cube.press(id))
        Self.say("FLEX-AP3R ON box 20 off the halfway: stored kind \(p.snap ?? "nil") · shown snapped \(edge.on(p.direction)?.label ?? "nothing")")
        XCTAssertEqual(p.snap, "halfway", "the box measures from it")
        XCTAssertNil(edge.on(p.direction), "★ 20° off: nothing is shown snapped")
        XCTAssertEqual(edge.box(current: p.direction, snap: p.snapTarget)?.target.kind, .halfway, "it is what the box measures from")
        XCTAssertTrue(cube.aimPress(id, box.release(0)))
        let back = try XCTUnwrap(cube.press(id))
        XCTAssertEqual(edge.on(back.direction)?.kind, .halfway, "★ the box at 0 is on it")
        var nudged = half.direction
        nudged.x = nudged.x.nextUp
        XCTAssertNil(edge.on(nudged), "★ one ulp off is not on it")
        let one = try await cube.pressAim([f.top])
        let st = try XCTUnwrap(one.offered.first)
        XCTAssertNil(one.on(T.tilt(st.direction, by: 15)), "a tilt is not straight")
        XCTAssertEqual(one.on(st.direction)?.kind, .straighten)
    }

    // MARK: - (6) a target inside the 1° band

    /// ★ MINOR. A target core builds may sit inside the app's 1° band (here 0.5° into a face). The box measured from it
    /// moves — from the target over the face's normal to 0.5° short of its far edge (179°) — and the knob, snapped
    /// there, follows a finger sliding along the face at 0.7° in; neither ever goes further out than the target. A
    /// target outside the band keeps the 1° rule (89° on a face). RED (the AP3 rule): the box's range was 0…0 and the
    /// knob held at the target whatever the finger did.
    func testATargetInsideTheOneDegreeBandLeavesTheBoxAndTheKnobFree() throws {
        let load = SIMD3<Double>(0, 0, -1)
        func at(depth: Double, longitude: Double) -> SIMD3<Double> {
            let d = depth * .pi / 180, l = longitude * .pi / 180
            return A.canon(SIMD3(cos(d) * cos(l), cos(d) * sin(l), -sin(d)))
        }
        let banded = A.Target(kind: .buildDown, direction: at(depth: 0.5, longitude: 0))
        XCTAssertFalse(A.admissible(banded.direction, loads: [load]), "premise: inside the 1° band")
        let box = try XCTUnwrap(A.box(target: banded, current: banded.direction, fallbacks: [load], loads: [load]))
        Self.say(String(format: "FLEX-AP3R BAND box from a target 0.5° in: range %@ · limit %.9f°", "\(box.spec.range)", box.limit))
        XCTAssertEqual(box.limit, 179, accuracy: 1e-6, "★ the box moves: over the normal to 0.5° short of the far edge")
        XCTAssertEqual(T.bits(box.direction(0)), T.bits(banded.direction), "0 is still the target")
        XCTAssertGreaterThan(simd_dot(box.direction(10), load), simd_dot(banded.direction, load), "10° is further in")
        // the knob, snapped there: the finger slides 30° along the face at 0.7° in (inside the 1° band)
        let along = at(depth: 0.7, longitude: 30)
        XCTAssertFalse(A.admissible(along, loads: [load]), "premise: the finger is inside the 1° band too")
        let held = A.clamp(along, from: banded.direction, loads: [load])
        Self.say(String(format: "FLEX-AP3R BAND knob from the target toward 0.7° in, 30° along: moved %.6f°", T.deg(held, banded.direction)))
        XCTAssertLessThan(T.deg(held, along), 1e-9, "★ the knob follows the finger (no further out than its target)")
        // further out than the target: held at the target's own margin
        let out = at(depth: 0.3, longitude: 30)
        let heldOut = A.clamp(out, from: banded.direction, loads: [load])
        XCTAssertGreaterThanOrEqual(simd_dot(heldOut, load), simd_dot(banded.direction, load) - 1e-15, "★ never further out than the target")
        // a target outside the band keeps the 1° rule
        let straight = A.Target(kind: .straighten, direction: SIMD3(0, 0, -1))
        let face = try XCTUnwrap(A.box(target: straight, current: straight.direction, fallbacks: [SIMD3(1, 0, 0)], loads: [load]))
        XCTAssertEqual(face.limit, 89, accuracy: 1e-6, "control: 1° short of edge-on, as before")
    }
}
