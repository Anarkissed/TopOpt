// FlexibleMeetReviewTests — the AP2 verifier's findings, confirmed and fixed (task 2026-10-07, angled presses, batch
// AP2 REVIEW; FlexibleMeet / FlexibleEdgeCandidates / FlexibleStageModel+Meet and the press-verdict pass-through).
//
//   (1) core's face_adjacency DECIDES what is offered (it was fetched and never read);
//   (2) a closed polyline's point and an equal-length tie do not depend on the triangle order (his l bracket's bore
//       rims moved 4.4 mm and renumbered when the same triangles arrived reversed);
//   (3) a face taken out of the Flexible setup (settings.removedRegions) is listed, never offered;
//   (4) a blend's curved member is exempt from the wrap rule only while it turns no further than its edge does
//       (M2's "blend" [9, 41, 1, 42, 4, 31] ran through face 4, which spreads 163°);
//   (5) the 15° rule's margin on the M2's fillet seams is printed and pinned (a mesher change shows up red);
//   (6) core's facts are read only from the scene of the CURRENT regions (a cut made after the open read the old
//       scene and cached "not framed by core" for the new sectors);
//   (7) FlexibleMeet is built off the main actor;
//   (8) CORE'S VERDICT on a press direction (binding amendment A4): build_press_stack through a thin guarded
//       pass-through — a per-member load check is a Swift copy that core contradicts on curved members;
//   (9) a seam lying IN a cut plane belongs only to the sector whose area is beside it.
//
// Each test runs its RED control against the instrument the finding names, so a green run also shows each check
// can fail. STEP parts need OCCT: a part the importer refuses is a COUNTED skip ("FLEX-AP SKIP …"), never a pass.
import XCTest
import CoreGraphics
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleMeetReviewTests: XCTestCase {
    typealias G = FlexibleAngledGoldens
    typealias Pair = FlexibleMeet.Pair

    // MARK: - helpers

    /// The same mesh, its triangles in the opposite order (positions untouched).
    static func reversed(_ mesh: ViewerMesh) -> ViewerMesh {
        let n = mesh.triangleCount
        var idx: [Int32] = [], fid: [Int32] = []
        for t in (0..<n).reversed() {
            idx += [Int32(mesh.indices[3 * t]), Int32(mesh.indices[3 * t + 1]), Int32(mesh.indices[3 * t + 2])]
            fid.append(mesh.faceIDs[t])
        }
        return ViewerMesh(vertices: mesh.positions, indices: idx, faceIDs: fid, pseudoFaces: mesh.pseudoFaces)
    }

    /// A candidate as the list shows it: number, kind, members, offered, and its point at the 1e-4 mm key.
    static func sig(_ c: FlexibleEdgeCandidates) -> [String] {
        c.candidates.map { k in
            let q = [k.point.x, k.point.y, k.point.z].map { Int64(($0 / FlexibleMeet.keyMM).rounded()) }
            return "#\(k.number) \(k.kind) \(k.members) \(k.offered) @\(q)"
        }
    }

    static func deg(_ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
        acos(min(1, max(-1, simd_dot(simd_normalize(a), simd_normalize(b))))) * 180 / .pi
    }

    static func cubeFaces(_ mesh: ViewerMesh) -> (top: Int, x: Int, y: Int, bottom: Int, x0: Int, y0: Int) {
        (FlexibleSquishFixture.face(mesh, axis: 2, value: 60), FlexibleSquishFixture.face(mesh, axis: 0, value: 60),
         FlexibleSquishFixture.face(mesh, axis: 1, value: 60), FlexibleSquishFixture.face(mesh, axis: 2, value: 0),
         FlexibleSquishFixture.face(mesh, axis: 0, value: 0), FlexibleSquishFixture.face(mesh, axis: 1, value: 0))
    }

    /// A STEP part's model, or a counted skip.
    func stepModel(_ label: String, _ test: String, _ make: (String) throws -> ProjectModel,
                   skips: inout [String]) async throws -> (ProjectModel, FlexibleStageModel)? {
        do {
            let pm = try make(test)
            return (pm, try await G.openModel(self, pm, label))
        } catch let s as XCTSkip {
            skips.append("\(label): \(s.message ?? "skipped")")
            return nil
        }
    }

    // MARK: - (1) core's adjacency decides what is offered

    /// ★ FINDING 1 (major). Core's face_adjacency is the whole-face authority (r6 §3; core's build_press_stack
    /// refuses a footprint its face_adjacency does not connect). With the cube's top–x pair taken out of core's
    /// answer, the top–x edge is LISTED but not offered, in plain words; the corner {top, x, y} stays offered
    /// (core's own rule: one footprint connected through y). With no pair at all nothing is offered. A pair core
    /// has and the page cannot draw is named (coreOnlyFacePairs), never invented. RED (run here, before the fix):
    /// facts.adjacency was never read, so the top–x edge stayed offered.
    func testCoreAdjacencyDecidesWhatIsOffered() async throws {
        let m = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let meet = try XCTUnwrap(m.meet)
        let f = Self.cubeFaces(try XCTUnwrap(m.project.viewerMesh))
        let facts = try await m.meetFacts()
        let whole = FlexibleEdgeCandidates.make(meet: meet, facts: facts)
        XCTAssertEqual(whole.candidates.filter(\.offered).count, 20, "premise: the cube offers its 12 edges and 8 corners")
        XCTAssertEqual(whole.appOnlyFacePairs, [])
        XCTAssertEqual(whole.coreOnlyFacePairs, [])

        var cut = facts
        cut.adjacency[f.top].removeAll { $0 == f.x }
        cut.adjacency[f.x].removeAll { $0 == f.top }
        let c = FlexibleEdgeCandidates.make(meet: meet, facts: cut)
        let edge = try XCTUnwrap(c.candidates.first { Set($0.members) == [f.top, f.x] }, "the top–x edge is still listed")
        print("FLEX-AP2R ADJ cube60 without core's top–x pair: #\(edge.number) offered \(edge.offered) why '\(edge.why ?? "")' · "
              + "app-only \(c.appOnlyFacePairs) core-only \(c.coreOnlyFacePairs) · offered \(c.candidates.filter(\.offered).count)")
        XCTAssertFalse(edge.offered, "★ core does not see top and x touch: never offered")
        XCTAssertTrue(edge.why?.contains("core's model") ?? false, "one line says why")
        XCTAssertEqual(c.appOnlyFacePairs, [Pair(f.top, f.x)])
        let corner = try XCTUnwrap(c.corners.first { Set($0.members) == [f.top, f.x, f.y] })
        XCTAssertTrue(corner.offered, "core's footprint rule: top, x and y are connected through y")
        XCTAssertEqual(c.candidates.filter(\.offered).count, 19)
        XCTAssertEqual(Self.sig(c).map { $0.replacingOccurrences(of: " false @", with: " true @") },
                       Self.sig(whole), "the list and its numbers do not move")

        var none = facts
        none.adjacency = Array(repeating: [], count: facts.adjacency.count)
        let n = FlexibleEdgeCandidates.make(meet: meet, facts: none)
        XCTAssertEqual(n.candidates.filter(\.offered).count, 0, "★ core sees no face touch: nothing is offered")
        XCTAssertEqual(n.appOnlyFacePairs.count, 12)

        var extra = facts
        extra.adjacency[f.top] = (extra.adjacency[f.top] + [f.bottom]).sorted()
        extra.adjacency[f.bottom] = (extra.adjacency[f.bottom] + [f.top]).sorted()
        let e = FlexibleEdgeCandidates.make(meet: meet, facts: extra)
        XCTAssertEqual(e.coreOnlyFacePairs, [Pair(f.top, f.bottom)], "a pair the page cannot draw is named")
        XCTAssertEqual(e.candidates.count, 20, "and never invented")
    }

    // MARK: - (2) the triangle order moves nothing

    /// ★ FINDING 2. A closed polyline (a bore's rim) starts at its lowest point by position and runs one way, and
    /// equal-length polylines are ordered by position, so a candidate's point and number do not depend on the
    /// order the triangles arrive in: his r5, his l bracket and the M2 stand (STEP: counted skips), the same
    /// triangles reversed, give the same list (number, kind, members, offered, point at the 1e-4 mm key). RED
    /// (run here, before the fix): the l bracket's bore rims [0, 8], [0, 9] moved 4.4 mm and renumbered; the
    /// square loop's middle depended on the segment it was met at first.
    func testNumbersAndPointsIgnoreTheTriangleOrder() async throws {
        // the pure rule: a closed square and two equal open lines, met in two orders
        let sq = [SIMD3<Double>(0, 0, 0), SIMD3(10, 0, 0), SIMD3(10, 10, 0), SIMD3(0, 10, 0)]
        func seg(_ a: Int, _ b: Int) -> FlexibleMeet.Segment { .init(p: sq[a], q: sq[b], triA: 0, triB: 1) }
        let loopA = FlexibleMeet.chain([seg(0, 1), seg(1, 2), seg(2, 3), seg(3, 0)])
        let loopB = FlexibleMeet.chain([seg(2, 1), seg(3, 2), seg(0, 3), seg(1, 0)].reversed())
        let mA = try XCTUnwrap(FlexibleMeet.midpoint(loopA)), mB = try XCTUnwrap(FlexibleMeet.midpoint(loopB))
        print("FLEX-AP2R ORDER square loop: middle \(mA) vs \(mB) · polylines \(loopA) vs \(loopB)")
        XCTAssertEqual(loopA, loopB, "★ one loop, one start, one direction")
        XCTAssertEqual(mA, mB)
        let two = [FlexibleMeet.Segment(p: SIMD3(0, 0, 0), q: SIMD3(5, 0, 0), triA: 0, triB: 1),
                   FlexibleMeet.Segment(p: SIMD3(0, 9, 0), q: SIMD3(5, 9, 0), triA: 2, triB: 3)]
        let tA = FlexibleMeet.midpoint(FlexibleMeet.chain(two)), tB = FlexibleMeet.midpoint(FlexibleMeet.chain(two.reversed()))
        print("FLEX-AP2R ORDER equal lines: middle \(String(describing: tA)) vs \(String(describing: tB))")
        XCTAssertEqual(tA, tB, "★ a tie between equal lines is broken by position")

        var skips: [String] = []
        var parts: [(String, ProjectModel, FlexibleStageModel)] = []
        let r5 = try FlexiblePressFixtures.hisRound5(self)
        parts.append(("his r5", r5.project, try await G.openModel(self, r5.project, "his r5")))
        let t = "FlexibleMeetReviewTests.testNumbersAndPointsIgnoreTheTriangleOrder"
        if let p = try await stepModel("l bracket", t, FlexiblePressFixtures.lBracketProject, skips: &skips) { parts.append(("l bracket", p.0, p.1)) }
        if let p = try await stepModel("M2 stand", t, FlexiblePressFixtures.m2Project, skips: &skips) { parts.append(("M2 stand", p.0, p.1)) }
        for (label, pm, m) in parts {
            let facts = try await m.meetFacts()
            let a = FlexibleEdgeCandidates.make(meet: try XCTUnwrap(m.meet), facts: facts)
            let mesh = try XCTUnwrap(pm.viewerMesh)
            let rev = Self.reversed(mesh)
            let rmeet = FlexibleMeet(mesh: rev, regions: FlexibleRegions(model: pm.faceRegions, mesh: rev))
            var rf = facts
            let n = mesh.triangleCount
            rf.triangleLoads = Dictionary(uniqueKeysWithValues: facts.triangleLoads.map { (n - 1 - $0.key, $0.value) })
            let b = FlexibleEdgeCandidates.make(meet: rmeet, facts: rf)
            let diffs = zip(Self.sig(a), Self.sig(b)).filter { $0 != $1 }
            print("FLEX-AP2R ORDER \(label): \(a.candidates.count) candidates · reversed order identical \(Self.sig(a) == Self.sig(b))"
                  + (diffs.isEmpty ? "" : " · first differences \(diffs.prefix(4))"))
            XCTAssertEqual(Self.sig(a), Self.sig(b), "\(label): the triangle order moves no number and no point")
        }
        print("FLEX-AP2R ORDER STEP skips \(skips.count)" + (skips.isEmpty ? "" : " — " + skips.joined(separator: "; ")))
    }

    // MARK: - (3) a face taken out of the setup

    /// ★ FINDING 4. r6 §3: the candidates' regions are the Flexible regions MINUS removed ones
    /// (settings.removedRegions: a face he deleted from the Flexible setup that a main-page group still holds).
    /// Such a face's edges and corners stay LISTED — the numbers do not move — but are never offered, in one
    /// line. RED (run here, before the fix): all 20 stayed offered.
    func testAFaceTakenOutOfTheSetupIsListedNotOffered() async throws {
        let m = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = Self.cubeFaces(try XCTUnwrap(m.project.viewerMesh))
        let before = try await m.edgeCandidates()
        m.edit { $0.removedRegions = [f.top] }
        XCTAssertTrue(m.settings.isRemoved(f.top), "premise")
        let after = try await m.edgeCandidates()
        let withTop = after.candidates.filter { $0.members.contains(f.top) }
        print("FLEX-AP2R REMOVED cube60, top taken out: offered \(after.candidates.filter(\.offered).count) of \(after.candidates.count) · "
              + withTop.map { "#\($0.number) \($0.offered) '\($0.why ?? "")'" }.joined(separator: " | "))
        XCTAssertEqual(withTop.count, 8, "the top's 4 edges and 4 corners are still listed")
        XCTAssertTrue(withTop.allSatisfy { !$0.offered }, "★ never offered")
        XCTAssertTrue(withTop.allSatisfy { $0.why?.contains("taken out of the Flexible setup") ?? false }, "one line says why")
        XCTAssertEqual(after.candidates.filter(\.offered).count, 12)
        XCTAssertEqual(after.candidates.map { "#\($0.number) \($0.members)" }, before.candidates.map { "#\($0.number) \($0.members)" },
                       "the numbers do not move")
    }

    // MARK: - (4) a blend's curved members turn no further than its edge

    /// ★ FINDING 9 (the chain exemption). A blend's curved chain is exempt from the wrap rule because a fillet
    /// spreads by the angle of the edge it rounds — so the exemption holds only while each chain member's spread
    /// (core's normal_spread_deg) is at most the angle between the blend's two flats (core's loads). On the M2
    /// stand every offered blend obeys it, and the "blend" from the sliver flat 9 through face 4 (163°) to 31 is
    /// listed, not offered, naming face 4; the r 3 fillet [18, 61, 2] is still offered. RED (run here, before the
    /// fix): [9, 41, 1, 42, 4, 31] was offered.
    func testABlendsCurvedMembersTurnNoFurtherThanItsEdge() async throws {
        var skips: [String] = []
        guard let step = try await stepModel("M2 stand", "FlexibleMeetReviewTests.testABlendsCurvedMembersTurnNoFurtherThanItsEdge",
                                               FlexiblePressFixtures.m2Project, skips: &skips) else {
            print("FLEX-AP2R BLEND STEP skips \(skips.count) — " + skips.joined(separator: "; "))
            throw XCTSkip(skips.joined())
        }
        let m = step.1
        let facts = try await m.meetFacts()
        let c = try await m.edgeCandidates()
        func spread(_ r: Int) -> Double { facts.frames[r]?.normalSpreadDeg ?? .nan }
        var turnsFurther = 0
        for b in c.candidates where b.kind == .blend {
            let la = try XCTUnwrap(facts.frames[b.members.first!]?.load), lb = try XCTUnwrap(facts.frames[b.members.last!]?.load)
            let edgeDeg = Self.deg(la, lb)
            let chain = Array(b.members.dropFirst().dropLast())
            let over = chain.filter { spread($0) > edgeDeg }
            print(String(format: "FLEX-AP2R BLEND #%d %@ edge %.1f° chain spreads %@ · %@", b.number, "\(b.members)", edgeDeg,
                         "\(chain.map { String(format: "%.1f", spread($0)) })", b.offered ? "offered" : "not offered: \(b.why ?? "")"))
            if !over.isEmpty {
                turnsFurther += 1
                XCTAssertFalse(b.offered, "★ \(b.members): a chain member turns further than the edge (\(over))")
                XCTAssertTrue(over.contains { m.name($0).isEmpty == false && (b.why ?? "").contains(m.name($0)) },
                              "\(b.members): the line names the member")
            }
        }
        print("FLEX-AP2R BLEND M2: \(c.candidates.filter { $0.kind == .blend }.count) blends, \(turnsFurther) with a member that turns further")
        let fillet = try XCTUnwrap(c.candidates.first { $0.kind == .blend && Set($0.members) == [18, 61, 2] })
        XCTAssertTrue(fillet.offered, "the r 3 fillet is offered")
        if let sliver = c.candidates.first(where: { $0.kind == .blend && $0.members == [9, 41, 1, 42, 4, 31] }) {
            XCTAssertFalse(sliver.offered, "★ face 4 spreads \(spread(4))°")
        }
        XCTAssertGreaterThan(turnsFurther, 0, "premise: the stand has such a chain")
    }

    // MARK: - (5) the 15° rule's margin

    /// ★ FINDING 10. The flat-to-fillet seam angle is the first facet row's (core's STEP mesher, 0.5 rad
    /// angular deflection), close under 15°. Printed: every seam segment's angle between core's two triangle
    /// normals, the worst SMOOTH one (< 15°) and the mildest CREASED one, and pinned: each sits at least
    /// `margin` from 15°, so a mesher change that moves one across shows up red here, by name, before it
    /// silently turns a fillet into edges. CONTROL (run here): the rule at 14° instead of 15° breaks blends — the
    /// seams near the threshold carry them.
    func testTheTangentRuleMarginOnTheM2() async throws {
        var skips: [String] = []
        guard let step = try await stepModel("M2 stand", "FlexibleMeetReviewTests.testTheTangentRuleMarginOnTheM2",
                                               FlexiblePressFixtures.m2Project, skips: &skips) else {
            print("FLEX-AP2R MARGIN STEP skips \(skips.count) — " + skips.joined(separator: "; "))
            throw XCTSkip(skips.joined())
        }
        let m = step.1
        let meet = try XCTUnwrap(m.meet)
        let facts = try await m.meetFacts()
        var worstSmooth = (deg: 0.0, pair: Pair(0, 0)), mildestCrease = (deg: 180.0, pair: Pair(0, 0))
        var hist = [Int](repeating: 0, count: 8)   // 2.5° bins from 10°
        for (pair, s) in meet.seams where s.kind == .edge {
            for seg in s.segments where seg.triA != seg.triB {
                guard let la = facts.triangleLoads[seg.triA], let lb = facts.triangleLoads[seg.triB] else { continue }
                let d = Self.deg(la, lb)
                if d >= 10, d < 30 { hist[Int((d - 10) / 2.5)] += 1 }
                if simd_dot(la, lb) <= FlexibleMainPageLoads.straightCos {
                    if d < mildestCrease.deg { mildestCrease = (d, pair) }
                } else if d > worstSmooth.deg { worstSmooth = (d, pair) }
            }
        }
        let margin = 0.5
        print(String(format: "FLEX-AP2R MARGIN M2: worst smooth seam %.3f° (%@), mildest crease %.3f° (%@) · margins %.3f° / %.3f° · "
                     + "segments per 2.5° from 10°: %@", worstSmooth.deg, "\(worstSmooth.pair)", mildestCrease.deg,
                     "\(mildestCrease.pair)", 15 - worstSmooth.deg, mildestCrease.deg - 15, "\(hist)"))
        XCTAssertLessThanOrEqual(worstSmooth.deg, 15 - margin, "★ a smooth seam (\(worstSmooth.pair)) sits within \(margin)° of the rule")
        XCTAssertGreaterThanOrEqual(mildestCrease.deg, 15 + margin, "★ a crease (\(mildestCrease.pair)) sits within \(margin)° of the rule")

        // ★ CONTROL: at 14° the near-threshold fillet seams turn into creases and blends break
        let c15 = FlexibleEdgeCandidates.make(meet: meet, facts: facts)
        let c14 = FlexibleEdgeCandidates.make(meet: meet, facts: facts, creaseCos: cos(14 * Double.pi / 180))
        let b15 = c15.candidates.filter { $0.kind == .blend }.count, b14 = c14.candidates.filter { $0.kind == .blend }.count
        print("FLEX-AP2R MARGIN control: blends at 15° \(b15), at 14° \(b14)")
        XCTAssertLessThan(b14, b15, "control: one degree lower, the fillets' first seams crease")
    }

    // MARK: - (6) core's facts come from the scene of the current regions

    /// ★ FINDING 12. A cut made after the scene opened (item 2's [Done]) changes the regions; until the scene is
    /// re-opened for them, core's facts are NOT read from the old scene (which does not declare the new sectors
    /// and would have cached "not framed by core" for them): meetFacts, edgeCandidates, regionFrame and
    /// pressVerdict throw "The part changed …". Re-opened, the sectors are core's. RED (run here, before the
    /// fix): meetFacts answered from the old scene.
    func testCoreFactsWaitForTheSceneOfTheCurrentRegions() async throws {
        let pm = try FlexiblePressFixtures.cube60Project()
        let m = try await G.openModel(self, pm, "cube60")
        let f = Self.cubeFaces(try XCTUnwrap(pm.viewerMesh))
        _ = try await m.meetFacts()
        var fr = pm.faceRegions
        let topID = fr.union(faces: [FaceID(f.top)], named: "top")
        let halves = fr.splitManual(topID, point: SIMD3(30, 0, 60), normal: SIMD3(1, 0, 0))
        XCTAssertEqual(halves.count, 2)
        pm.faceRegions = fr
        XCTAssertNotEqual(m.currentSceneKey, m.openedKey, "premise: the regions changed after the open")
        var refusals: [String] = []
        do { _ = try await m.meetFacts(); XCTFail("★ meetFacts read the old scene") } catch { refusals.append("\(error)") }
        do { _ = try await m.edgeCandidates(); XCTFail("★ edgeCandidates read the old scene") } catch { refusals.append("\(error)") }
        do { _ = try await m.regionFrame(f.x); XCTFail("★ regionFrame read the old scene") } catch { refusals.append("\(error)") }
        do { _ = try await m.pressVerdict([f.x], direction: nil); XCTFail("★ pressVerdict read the old scene") } catch { refusals.append("\(error)") }
        print("FLEX-AP2R STALE cube60 after a cut: \(refusals)")

        m.openScene()
        try await FlexibleHisProject.waitFor(120, "the re-opened scene") { m.sceneState == .ready && m.openedKey == m.currentSceneKey }
        let c = try await m.edgeCandidates()
        let a = FlexibleRegions.wireID(try XCTUnwrap(fr.region(halves[0]))), b = FlexibleRegions.wireID(try XCTUnwrap(fr.region(halves[1])))
        print("FLEX-AP2R STALE re-opened: \(c.edges.count) edges, \(c.corners.count) corners, offered \(c.candidates.filter(\.offered).count); "
              + "not offered: " + c.candidates.filter { !$0.offered }.map { "#\($0.number) '\($0.why ?? "")'" }.joined(separator: " "))
        XCTAssertEqual(c.edges.count, 14, "the split top: 4 + 6 + 4")
        XCTAssertEqual(c.corners.count, 8)
        XCTAssertTrue(c.candidates.filter { $0.members.contains(a) || $0.members.contains(b) }.allSatisfy(\.offered),
                      "the sectors are framed by the scene that declares them")
    }

    // MARK: - (7) built off the main actor

    /// ★ FINDING 13. FlexibleMeet is a pure value over the viewer mesh and the regions; pick mode builds it with
    /// meetOffMain(), off the main actor, and every later reader (the sync `meet`, meetFacts, edgeCandidates)
    /// reuses that build. RED (run here, before the fix): it was built on the main thread.
    func testTheMeetIsBuiltOffTheMainActor() async throws {
        let pm = try FlexiblePressFixtures.cube60Project()
        let m = FlexibleStageModel(project: pm, materialsPath: FlexibleHisProject.materialsPath,
                                   stampsPath: FlexibleHisProject.stampsPath, persist: {})
        let g = await m.meetOffMain()
        print("FLEX-AP2R MAIN cube60: built \(m.meetCache.builds) time(s), on the main thread \(String(describing: m.meetCache.lastBuildOnMainThread))")
        XCTAssertEqual(m.meetCache.lastBuildOnMainThread, false, "★ built off the main thread")
        XCTAssertEqual(m.meetCache.builds, 1)
        XCTAssertEqual(g?.seams.count, 12)
        _ = m.meet
        _ = await m.meetOffMain()
        XCTAssertEqual(m.meetCache.builds, 1, "every later reader reuses the build")
        // a regions change rebuilds it, still off the main thread
        var fr = pm.faceRegions
        let top = FlexibleSquishFixture.face(try XCTUnwrap(pm.viewerMesh), axis: 2, value: 60)
        _ = fr.splitManual(fr.union(faces: [FaceID(top)], named: "top"), point: SIMD3(30, 0, 60), normal: SIMD3(1, 0, 0))
        pm.faceRegions = fr
        let g2 = await m.meetOffMain()
        XCTAssertEqual(m.meetCache.builds, 2)
        XCTAssertEqual(m.meetCache.lastBuildOnMainThread, false)
        XCTAssertEqual(g2?.pieces.count, 7, "the split top's two sectors and five faces")
    }

    // MARK: - (8) core's verdict on a press direction

    /// ★ FINDING 7 (major; binding amendment A4: "offer only directions core accepts"). pressVerdict asks core's
    /// build_press_stack through a thin pass-through under bridge.cpp's one guard. On the cube: the edge's and the
    /// corner's halfway (Σ core's inward normals) are built — 45.00° and 54.74° from each member face, from core's
    /// own load; a member's own normal and build Z (down and up, A8) are refused for the edge in core's words; the
    /// top alone takes build Z down ("straighten"); a footprint core does not connect is refused. On the M2 stand
    /// (counted skip) the corner [33, 34, 57] along build Z down: every member's core load points into the part,
    /// yet core refuses (face 57 is curved: some of its triangles are edge-on) — the per-member check is not
    /// core's rule. RED (run here, before the fix): the verdict was that per-member Swift check.
    func testCoreSaysWhichDirectionsAPressTakes() async throws {
        let m = try await G.openModel(self, try FlexiblePressFixtures.cube60Project(), "cube60")
        let f = Self.cubeFaces(try XCTUnwrap(m.project.viewerMesh))
        let lt = try await m.regionFrame(f.top).load, lx = try await m.regionFrame(f.x).load, ly = try await m.regionFrame(f.y).load

        let edge = try await m.pressVerdict([f.top, f.x], direction: lt + lx)
        print(String(format: "FLEX-AP2R VERDICT cube edge halfway: accepted %@ · %.4f° / %.4f° from the faces · build angle %.4f side %@ · %d columns",
                     "\(edge.accepted)", Self.deg(edge.load, lt), Self.deg(edge.load, lx), edge.buildAngleDeg, "\(edge.side)", edge.columns))
        XCTAssertTrue(edge.accepted, edge.reason)
        XCTAssertEqual(Self.deg(edge.load, lt), 45, accuracy: 1e-9, "★ 45.00° from the top, core's load")
        XCTAssertEqual(Self.deg(edge.load, lx), 45, accuracy: 1e-9)
        XCTAssertEqual(edge.buildAngleDeg, 45, accuracy: 1e-9)
        XCTAssertTrue(edge.side, "core: more than 15° off Z is a side press")
        XCTAssertGreaterThan(edge.columns, 0)

        let corner = try await m.pressVerdict([f.top, f.x, f.y], direction: lt + lx + ly)
        print(String(format: "FLEX-AP2R VERDICT cube corner halfway: accepted %@ · %.6f° / %.6f° / %.6f°", "\(corner.accepted)",
                     Self.deg(corner.load, lt), Self.deg(corner.load, lx), Self.deg(corner.load, ly)))
        XCTAssertTrue(corner.accepted, corner.reason)
        for l in [lt, lx, ly] { XCTAssertEqual(Self.deg(corner.load, l), acos(1 / 3.0.squareRoot()) * 180 / .pi, accuracy: 1e-9, "★ 54.74°") }

        for (label, d) in [("the top's normal", lt), ("x's normal", lx), ("build Z down", SIMD3<Double>(0, 0, -1)),
                           ("build Z up", SIMD3<Double>(0, 0, 1))] {
            let v = try await m.pressVerdict([f.top, f.x], direction: d)
            print("FLEX-AP2R VERDICT cube edge along \(label): accepted \(v.accepted) · '\(v.reason)'")
            XCTAssertFalse(v.accepted, "★ A4/A8: core refuses \(label) for the edge")
            XCTAssertTrue(v.reason.contains("does not point into the part"), "core's words: \(v.reason)")
        }
        let straighten = try await m.pressVerdict([f.top], direction: SIMD3(0, 0, -1))
        XCTAssertTrue(straighten.accepted, "a single face takes its own normal: straighten")
        let apart = try await m.pressVerdict([f.top, f.bottom], direction: nil)
        print("FLEX-AP2R VERDICT cube top + bottom: accepted \(apart.accepted) · '\(apart.reason)'")
        XCTAssertFalse(apart.accepted)
        XCTAssertTrue(apart.reason.contains("not adjacent"), "core's words: \(apart.reason)")
        // every offered cube candidate's halfway is built
        let c = try await m.edgeCandidates()
        for k in c.candidates where k.offered {
            var h = SIMD3<Double>.zero
            for r in k.members { h += try await m.regionFrame(r).load }
            let v = try await m.pressVerdict(k.members, direction: h)
            XCTAssertTrue(v.accepted, "#\(k.number) \(k.members): \(v.reason)")
        }
        // an undeclared region is an error, not a verdict
        do { _ = try await m.pressVerdict([987_654], direction: nil); XCTFail("an undeclared region throws") } catch {
            XCTAssertTrue("\(error)".contains("not declared"), "\(error)")
        }
        let src = try String(contentsOf: FlexibleHisProject.repoRoot.appendingPathComponent(
            "app/TopOptKit/Sources/TopOptBridge/flexible_bridge.cpp"), encoding: .utf8)
        XCTAssertTrue(src.contains("bridge_guard_run(\"flexible_scene_press_verdict\""), "the verdict runs under the one guard")
        XCTAssertTrue(src.contains("fx::build_press_stack(s->model, fp, s->regions, s->grid, s->mask, 0, s->build,"), "core's own press stack")

        // the M2: core's rule is per TRIANGLE, the per-member check is not
        var skips: [String] = []
        guard let step = try await stepModel("M2 stand", "FlexibleMeetReviewTests.testCoreSaysWhichDirectionsAPressTakes",
                                                FlexiblePressFixtures.m2Project, skips: &skips) else {
            print("FLEX-AP2R VERDICT STEP skips \(skips.count) — " + skips.joined(separator: "; "))
            throw XCTSkip(skips.joined())
        }
        let m2 = step.1
        let down = SIMD3<Double>(0, 0, -1)
        var memberSays = true
        for r in [33, 34, 57] {
            let fr = try await m2.regionFrame(r)
            print(String(format: "FLEX-AP2R VERDICT M2 face %d: load · down %.4f, spread %.1f°", r, simd_dot(fr.load, down), fr.normalSpreadDeg))
            if simd_dot(fr.load, down) <= 0 { memberSays = false }
        }
        let v = try await m2.pressVerdict([33, 34, 57], direction: down)
        print("FLEX-AP2R VERDICT M2 [33, 34, 57] along build Z down: per-member check \(memberSays ? "accepts" : "refuses") · core accepted \(v.accepted) '\(v.reason)'")
        XCTAssertTrue(memberSays, "premise: every member's core load points into the part")
        XCTAssertFalse(v.accepted, "★ core refuses it: a triangle of face 57 does not face against build Z")
        XCTAssertTrue(v.reason.contains("does not point into the part"), "core's words: \(v.reason)")
        print("FLEX-AP2R VERDICT STEP skips 0")
    }

    // MARK: - (9) a seam in a cut plane

    /// ★ FINDING 6. FlexibleMeet clips a seam by a sector's cuts CLOSED (core's clip_into rule for surfaces). A
    /// seam lying IN a cut plane passes a closed clip for BOTH sectors, though the face lies beside it on one side
    /// only. So a seam on a cut plane goes to the sector whose own area is beside it (the triangle that holds the
    /// seam lies on its side). Fixture: an L-shaped prism whose L cap is split along the plane of the inner floor
    /// wall: the lower sector touches that wall along 40 mm, the upper one does not; the upper touches the inner
    /// riser wall. RED (run here, before the fix): the upper sector "touched" the floor wall too. CONTROL: the
    /// strict voxel-centre rule (FaceRegionGeometry.inside) would give the seam to the UPPER sector — the wrong one.
    func testASeamOnACutPlaneBelongsOnlyToTheSectorBesideIt() throws {
        let arm = 60.0, t = 20.0, hgt = 60.0, depth = 20.0
        let outline: [SIMD2<Double>] = [SIMD2(-t / 2, -t / 2), SIMD2(arm - t / 2, -t / 2), SIMD2(arm - t / 2, t / 2),
                                        SIMD2(t / 2, t / 2), SIMD2(t / 2, hgt - t / 2), SIMD2(-t / 2, hgt - t / 2)]
        let path = try FlexiblePressFixtures.write("ap2r_l_prism.stl",
                                                   FlexiblePressFixtures.asciiSTL("lprism", FlexiblePressFixtures.extrudedTriangles(outline, height: depth)))
        let pm = try FlexiblePressFixtures.project(path: path, name: "L prism")
        let mesh = try XCTUnwrap(pm.viewerMesh)
        let cap = FlexibleSquishFixture.face(mesh, axis: 2, value: Float(depth))
        let floorWall = FlexibleSquishFixture.face(mesh, axis: 1, value: Float(t / 2))
        let riserWall = FlexibleSquishFixture.face(mesh, axis: 0, value: Float(t / 2))
        XCTAssertTrue(cap >= 0 && floorWall >= 0 && riserWall >= 0, "premise: the cap and the two inner walls")
        var fr = pm.faceRegions
        let capID = fr.union(faces: [FaceID(cap)], named: "cap")
        let halves = fr.splitManual(capID, point: SIMD3(0, t / 2, depth), normal: SIMD3(0, 1, 0))
        XCTAssertEqual(halves.count, 2)
        let upper = FlexibleRegions.wireID(try XCTUnwrap(fr.region(halves[0])))   // y ≥ t/2: the riser's cap
        let lower = FlexibleRegions.wireID(try XCTUnwrap(fr.region(halves[1])))   // y < t/2: the floor's cap
        let meet = FlexibleMeet(mesh: mesh, regions: FlexibleRegions(model: fr, mesh: mesh))
        func len(_ a: Int, _ b: Int) -> Double { meet.seam(a, b)?.length ?? 0 }
        print(String(format: "FLEX-AP2R ONPLANE L prism: lower–floor wall %.4f · upper–floor wall %.4f · upper–riser %.4f · lower–riser %.4f mm",
                     len(lower, floorWall), len(upper, floorWall), len(upper, riserWall), len(lower, riserWall)))
        XCTAssertEqual(len(lower, floorWall), arm - t, accuracy: 1e-6, "the floor's cap meets the floor wall along it")
        XCTAssertFalse(meet.touches(upper, floorWall), "★ the riser's cap has no area beside the floor wall")
        XCTAssertEqual(len(upper, riserWall), hgt - t, accuracy: 1e-6)
        XCTAssertFalse(meet.touches(lower, riserWall))
        XCTAssertTrue(meet.connected([lower, floorWall]))
        XCTAssertFalse(meet.connected([upper, floorWall]))

        // ★ CONTROL: the strict voxel-centre rule puts the seam's middle in the UPPER sector
        let mid = SIMD3<Double>(arm / 2, t / 2, depth)
        let cu = try XCTUnwrap(fr.region(halves[0])).cuts, cl = try XCTUnwrap(fr.region(halves[1])).cuts
        print("FLEX-AP2R ONPLANE control: strict rule — upper \(FaceRegionGeometry.inside(mid, cu)) lower \(FaceRegionGeometry.inside(mid, cl))")
        XCTAssertTrue(FaceRegionGeometry.inside(mid, cu), "control: the strict rule gives the seam to the upper sector")
        XCTAssertFalse(FaceRegionGeometry.inside(mid, cl))
    }
}
