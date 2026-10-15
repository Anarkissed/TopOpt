// FlexibleLatticeSectionsTests — round 7 batch M2 (step 2b), written BEFORE the code (the stubs' red run:
// round7/batch_m2/r7m2_red_run.txt). His img3 words of 2026-10-14: "As noted, only the places with face-prisms get
// latticed. In this example, when I tapped the top, it selected the model's top face, rather than one of the lattice's top
// faces." and "the pressed curves continue right through the entire model rather than the lattice section. It must only be
// the lattice section - regardless of what shape it is." The reviewer's ruling 3: the sections are FLEXIBLE-ONLY sectors
// carried in the job. His answer 7 (clarified): "an EQUAL SHARE PER LATTICE PART (two parts = 5 lb each of 10 lb, whatever
// their size), only on the latticed parts".
// Judged on HIS LIVE LATTICE (A1_0003 + Group C = Face 3 + Face 5 at 25 mm): the Top is cut into two 25 × 100 mm lattice
// sections, Faces 0, 2 and 4 into 25 mm bands; Faces 3 and 5 lie wholly inside their own face-prisms.
// Each test runs its RED control inside.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexibleLatticeSectionsTests: XCTestCase {
    typealias F = FlexibleM2Fixtures

    override func tearDown() {
        FlexibleLatticeSections.controlWholeFace = false
        FlexibleLatticeSections.controlAlwaysCut = false
        FlexibleLatticeSections.controlFingerprintIDs = false
        FlexibleMainPageLoads.controlAreaShare = false
        super.tearDown()
    }

    func width(_ p: ProjectModel) -> Double { F.box(p).hi.x - F.box(p).lo.x }

    // MARK: - (1) a tap on the Top selects the lattice under it

    func testATapOnTheTopSelectsTheLatticeUnderIt() async throws {
        let (r, _, m) = try await F.pad(self)
        let p = r.project
        m.tapFace(1, point: F.onTop(p, x: width(p) - 10))
        let sec = try XCTUnwrap(m.selectedRegion, "the tap selected something")
        XCTAssertTrue(FlexibleRegions.isFlexible(sec), "★ a Flexible lattice section, never Face 1 (\(sec))")
        let a = F.area(m, sec, face: 1)
        XCTAssertEqual(a, 2500, accuracy: 2.5, "★ the Top's lattice under Face 3's 25 mm face-prism: 25 × 100 mm²")
        try await F.reopen(m, "the section's stack")
        let st = try XCTUnwrap(m.stack(sec), "core stacked the section")
        let share = Double(st.latticedColumns) / Double(max(1, st.columns.count))
        print(String(format: "FLEX-M2-TAP section %d: %.1f mm² · core: %d columns, %d latticed (%.3f) · extent %.2f × %.2f mm · pitch %.3f",
                     sec, a, st.columns.count, st.latticedColumns, share, st.uExtentMM, st.vExtentMM, st.pitchMM))
        XCTAssertGreaterThanOrEqual(share, 0.95, "★ core: the section's columns are latticed")
        XCTAssertEqual(min(st.uExtentMM, st.vExtentMM), 25, accuracy: st.pitchMM, "★ core frames the section only: 25 mm across")
        // the middle: solid — nothing is selected, one line and one fix
        let before = m.selectedRegion
        m.tapFace(1, point: F.onTop(p, x: width(p) / 2))
        XCTAssertEqual(m.selectedRegion, before, "★ a tap on solid selects nothing")
        XCTAssertEqual(m.toast, FlexibleRowCopy.solidHere, "★ its one line")
        XCTAssertLessThanOrEqual(FlexibleRowCopy.solidHere.count, 44)
        XCTAssertEqual(m.toastFix, .goToLattice, "★ its one fix: [Go to Lattice]")

        // ★ RED CONTROL: today's whole face
        FlexibleLatticeSections.controlWholeFace = true
        let (r2, _, m2) = try await F.pad(self)
        m2.tapFace(1, point: F.onTop(r2.project, x: width(r2.project) - 10))
        XCTAssertEqual(m2.selectedRegion, 1, "control: the tap selects the model's whole top face")
        try await F.reopen(m2, "control")
        if let s1 = m2.stack(1) {
            print("FLEX-M2-TAP control: Face 1 — \(s1.columns.count) columns, \(s1.latticedColumns) latticed")
            XCTAssertLessThan(Double(s1.latticedColumns) / Double(max(1, s1.columns.count)), 0.95, "control: most of Face 1 has no lattice")
        }
    }

    // MARK: - (2) a face wholly inside one face-prism is the face itself

    func testAFaceWhollyInsideOnePrismIsTheFaceItself() async throws {
        let (r, _, m) = try await F.pad(self)
        XCTAssertTrue(F.pieces(m, face: 3).isEmpty, "★ Face 3 lies wholly inside its face-prism: no section")
        XCTAssertTrue(F.pieces(m, face: 5).isEmpty, "★ Face 5 too")
        XCTAssertNotNil(m.settings.face(3), "Face 3 is pressed as itself (region 3)")
        XCTAssertNotNil(m.settings.face(5), "Face 5 as itself")
        XCTAssertFalse(F.pieces(m, face: 1).isEmpty, "premise: the Top is cut (it is partly latticed)")
        // the C1 pad (a 20 mm face-prism under its top: the whole pad) and his pad's send set (the Top at 20 mm)
        let c1 = try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
        let mc = try await FlexibleAngledGoldens.openModel(self, c1, "the C1 pad")
        XCTAssertTrue(mc.sectorSet.isEmpty, "★ the C1 pad: every face wholly latticed — no Flexible sector")
        let a1 = try FlexiblePressFixtures.a1Project(3, self)
        let ma = try await FlexibleAngledGoldens.openModel(self, a1.project, "A1_0003 at 20 mm")
        XCTAssertTrue(ma.sectorSet.isEmpty, "★ his pad with the Top at 20 mm: no Flexible sector")
        let jobBefore = try F.sendEntries(m)
        _ = r

        // ★ RED CONTROL: every face a face-prism meets is cut — Face 3 gets a piece and its job entry moves
        FlexibleLatticeSections.controlAlwaysCut = true
        let (_, _, m2) = try await F.pad(self)
        let p3 = F.pieces(m2, face: 3)
        print("FLEX-M2-WHOLE control: Face 3's pieces \(p3.map(\.wireID))")
        XCTAssertFalse(p3.isEmpty, "control: Face 3 is cut although wholly inside")
        let jobControl = try F.sendEntries(m2)
        let moved = jobBefore.keys.contains { jobBefore[$0]?.faces[3] != jobControl[$0]?.faces[3] }
        XCTAssertTrue(moved, "control: Face 3's job entry moves")
    }

    // MARK: - (3) the Top's load presses only its sections, an equal share each

    func testTheTopsLoadPressesOnlyItsSectionsAtEqualShares() async throws {
        let (r, _, m) = try await F.pad(self)
        let p = r.project
        let mesh = try XCTUnwrap(p.viewerMesh)
        let topGroup = try XCTUnwrap(p.selection.groups.first { $0.name == "Top" })
        func topEntries() -> [FlexibleFaceSettings] {
            m.settings.loadedFaces.filter { m.regions.faces(of: $0.faceRegionID, mesh: mesh) == [1] }
        }
        XCTAssertNil(m.settings.face(1), "★ no entry for the whole Top")
        var top = topEntries()
        XCTAssertEqual(top.count, 2, "★ two lattice sections pressed")
        XCTAssertTrue(top.allSatisfy { FlexibleRegions.isFlexible($0.faceRegionID) && $0.weightFrom == topGroup.id }, "linked to the Top")
        XCTAssertEqual(top.map(\.weightKg).sorted(), [5, 5], "★ an equal share per lattice part: 5 of 10 kg each")
        // Face 5's face-prism at 10 mm: the sections are 25 and 10 mm wide — still half each
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        p.writeLatticeDepthMM(.face(group: c.id, face: 5), mm: 10)
        try await F.reopen(m, "Face 5 at 10 mm")
        top = topEntries()
        let areas = top.map { F.area(m, $0.faceRegionID, face: 1) }.sorted()
        print("FLEX-M2-SHARE sections \(top.map(\.faceRegionID)) · areas \(areas) · kg \(top.map(\.weightKg))")
        XCTAssertEqual(areas.count, 2)
        if areas.count == 2 { XCTAssertEqual(areas[0], 1000, accuracy: 1); XCTAssertEqual(areas[1], 2500, accuracy: 2.5) }
        for e in top { XCTAssertEqual(e.weightKg, 5, accuracy: 1e-9, "★ \(e.faceRegionID): half of 10 kg whatever its size") }
        XCTAssertEqual(FlexibleEdgeStrips.regionsInTwoEntries(m.settings), [], "no region in two entries")
        XCTAssertTrue(FlexibleEdgeStrips.sharedSurface(m.settings, regions: m.regions, mesh: mesh).isEmpty, "no two entries share surface")
        XCTAssertEqual(m.settings.face(0)?.role, "resting", "★ the bottom rests WHOLE (D2)")

        // ★ RED CONTROL: by area (25 : 10)
        FlexibleMainPageLoads.controlAreaShare = true
        m.adoptMainPageLoads()
        let control = topEntries().map(\.weightKg).sorted()
        print("FLEX-M2-SHARE control (area): \(control)")
        XCTAssertEqual(control.count, 2)
        if control.count == 2 { XCTAssertEqual(control[0], 10 * 10 / 35, accuracy: 1e-6, "control: 10 kg split 25 : 10") }
    }

    // MARK: - (4) the curves span only the lattice section

    func testTheCurvesSpanOnlyTheLatticeSection() async throws {
        let (r, _, m) = try await F.pad(self)
        let p = r.project
        m.tapFace(1, point: F.onTop(p, x: width(p) - 10))
        let sec = try XCTUnwrap(m.selectedRegion)
        XCTAssertTrue(FlexibleRegions.isFlexible(sec), "the section (\(sec))")
        try await F.reopen(m, "the section")
        let k = try XCTUnwrap(m.key(sec), "the section is pressed")
        let g = try XCTUnwrap(m.geometry[k], "its drawings' geometry")
        let st = try XCTUnwrap(m.stacks[k])
        let cuts = m.regions.cuts(of: sec)
        for pt in g.baselineX.points + g.baselineY.points {
            XCTAssertTrue(F.inside(pt, cuts), "★ every curve point lies inside the section: \(pt)")
        }
        let len = { (pts: [SIMD3<Double>]) in zip(pts, pts.dropFirst()).reduce(0) { $0 + simd_distance($1.0, $1.1) } }
        print(String(format: "FLEX-M2-CURVES baseline X %.2f mm · Y %.2f mm", len(g.baselineX.points), len(g.baselineY.points)))
        XCTAssertEqual(min(len(g.baselineX.points), len(g.baselineY.points)), 25, accuracy: st.pitchMM + 1e-6, "★ the curve spans 25 mm")
        let latticed = Set(st.columns.indices.filter { st.columns[$0].latticeMM > 0 })
        XCTAssertEqual(m.prismColumns(sec), latticed, "★ the prism stands on the latticed columns")
        // the dent: nothing moves on the Top's solid middle
        let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
        let ch = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: false, drawnLattice: nil)
        let dents = try XCTUnwrap(ch.dents, "a dent is drawn")
        let (lo, hi) = F.box(p)
        let pos = overlay.mesh.flat.positions
        var middle = 0, moved = 0
        for v in 0..<min(dents.count, pos.count / 3) {
            let x = Double(pos[3 * v]), z = Double(pos[3 * v + 2])
            guard abs(z - hi.z) < 1e-3, x > lo.x + 25 + 1e-3, x < hi.x - 25 - 1e-3 else { continue }
            middle += 1
            if abs(dents[v]) > 1e-9 { moved += 1 }
        }
        print("FLEX-M2-CURVES the Top's middle: \(middle) vertices, \(moved) moved")
        XCTAssertGreaterThan(middle, 0, "premise: the overlay has vertices on the Top's middle")
        XCTAssertEqual(moved, 0, "★ the solid middle never moves")

        // ★ RED CONTROL: the whole Top pressed (today's)
        FlexibleLatticeSections.controlWholeFace = true
        let (_, _, m2) = try await F.pad(self)
        let k2 = try XCTUnwrap(m2.key(1))
        let g2 = try XCTUnwrap(m2.geometry[k2])
        let l2 = max(len(g2.baselineX.points), len(g2.baselineY.points))
        print(String(format: "FLEX-M2-CURVES control: Face 1's baseline %.2f mm", l2))
        XCTAssertEqual(l2, 100, accuracy: 1, "control: the curve runs through the whole model (100 mm)")
    }

    // MARK: - (5) a section keeps its id and its curves through a depth change

    func testASectionKeepsItsIdAndCurvesThroughADepthChange() async throws {
        let (r, _, m) = try await F.pad(self)
        let p = r.project
        let c = try XCTUnwrap(p.selection.groups.first { $0.name == "Group C" })
        m.tapFace(1, point: F.onTop(p, x: width(p) - 5))
        let sec = try XCTUnwrap(m.selectedRegion)
        XCTAssertTrue(FlexibleRegions.isFlexible(sec), "the section (\(sec))")
        let drawn = FlexCurve(x: [0, 0.3, 1], y: [0.2, 0.9, 0.4])
        m.edit { s in guard var f = s.face(sec) else { return }; f.shape = nil; f.curveX = drawn; s.setFace(f) }
        XCTAssertEqual(m.settings.face(sec)?.curveX, drawn, "premise: his curve on the section")
        p.writeLatticeDepthMM(.face(group: c.id, face: 3), mm: 17.26)
        try await F.reopen(m, "Face 3 at 17.26 mm")
        m.tapFace(1, point: F.onTop(p, x: width(p) - 5))
        XCTAssertEqual(m.selectedRegion, sec, "★ the same section, the same id")
        XCTAssertEqual(m.settings.face(sec)?.curveX, drawn, "★ his curve kept")
        XCTAssertEqual(F.area(m, sec, face: 1), 1726, accuracy: 1.726, "★ 17.26 × 100 mm²")

        // ★ RED CONTROL: a section keyed by its geometry — the depth change re-keys it
        FlexibleLatticeSections.controlFingerprintIDs = true
        let (r2, _, m2) = try await F.pad(self)
        let p2 = r2.project
        let c2 = try XCTUnwrap(p2.selection.groups.first { $0.name == "Group C" })
        m2.tapFace(1, point: F.onTop(p2, x: width(p2) - 5))
        let sec2 = try XCTUnwrap(m2.selectedRegion)
        p2.writeLatticeDepthMM(.face(group: c2.id, face: 3), mm: 17.26)
        try await F.reopen(m2, "control: Face 3 at 17.26 mm")
        m2.tapFace(1, point: F.onTop(p2, x: width(p2) - 5))
        print("FLEX-M2-KEEP control: \(sec2) → \(m2.selectedRegion ?? -1)")
        XCTAssertNotEqual(m2.selectedRegion, sec2, "control: a geometry key gives the section a new id")
    }

    // MARK: - (6) the carry never leaves the whole face beside its sections

    func testTheCarryNeverLeavesTheWholeFaceBesideItsSections() async throws {
        // the Top pressed whole BEFORE the face-prisms (his pad as saved), then his live lattice, then the part opens again
        let (r, _, m) = try await F.pad(self, live: false)
        let p = r.project
        let mesh = try XCTUnwrap(p.viewerMesh)
        let old = try XCTUnwrap(m.settings.face(1), "premise: the Top pressed whole")
        try FlexibleR7M1Fixtures.hisLiveLattice(p)
        try await F.reopen(m, "his live lattice")
        let s = m.settings
        XCTAssertNil(s.face(1), "★ the whole-Top entry is gone")
        let copies = s.faces.filter { m.regions.faces(of: $0.faceRegionID, mesh: mesh) == [1] }
        XCTAssertEqual(copies.count, 2, "★ two copies, one per lattice section")
        XCTAssertEqual(Set(copies.map(\.squeezeGroup)), [old.squeezeGroup], "his group carried")
        for cp in copies {
            XCTAssertTrue(FlexibleRegions.isFlexible(cp.faceRegionID))
            XCTAssertEqual(cp.deepestMM, old.deepestMM, "his deepest squish carried")
            // the stamp stays where he drew it ON THE PART (kept stored); its centre lies on solid ⇒ the section is Curves
            if let s0 = old.designStamp {
                let s1 = try XCTUnwrap(cp.designStamp, "the stamp is kept on \(cp.faceRegionID)")
                let p0 = try await m.frameWorker.withScene { try FlexibleSceneFrames($0).fromUV(.face(1), [SIMD2(s0.centreU, s0.centreV)]) }
                let p1 = try await m.frameWorker.withScene { try FlexibleSceneFrames($0).fromUV(.face(cp.faceRegionID), [SIMD2(s1.centreU, s1.centreV)]) }
                print("FLEX-M2-CARRY \(cp.faceRegionID): stamp (\(s0.centreU), \(s0.centreV)) → (\(s1.centreU), \(s1.centreV)) · on the part \(p0[0]) → \(p1[0]) · shape \(cp.shape ?? "curves")")
                XCTAssertLessThan(simd_distance(p0[0], p1[0]), 1e-6, "★ the stamp stays where he drew it on the part")
                let holds = F.inside(p0[0], m.regions.cuts(of: cp.faceRegionID))
                XCTAssertEqual(cp.isStampShape, holds, "★ Stamp only on the section holding its centre; Curves elsewhere")
            }
        }
        XCTAssertTrue(FlexibleEdgeStrips.sharedSurface(s, regions: m.regions, mesh: mesh).isEmpty, "★ no two entries share surface")

        // ★ RED CONTROL: no carry — the whole Top stays beside its sections (core's shared_footprint)
        let (r2, _, m2) = try await F.pad(self, live: false)
        m2.controlNoCarry = true
        try FlexibleR7M1Fixtures.hisLiveLattice(r2.project)
        try await F.reopen(m2, "control")
        let on1 = m2.settings.loadedFaces.filter { m2.regions.faces(of: $0.faceRegionID, mesh: mesh) == [1] }
        let shared = FlexibleEdgeStrips.sharedSurface(m2.settings, regions: m2.regions, mesh: mesh)
        print("FLEX-M2-CARRY control: loaded entries on the Top \(on1.map(\.faceRegionID)) · shared surface \(shared)")
        XCTAssertEqual(on1.count, 3, "control: the whole Top AND its two sections")
        XCTAssertFalse(shared.isEmpty, "control: two entries share surface (core refuses: shared_footprint)")
    }

    // MARK: - (7) the Squish page tints where the lattice is

    func testTheSquishPageTintsWhereTheLatticeIs() async throws {
        let (r, _, m) = try await F.pad(self)
        let p = r.project
        let mesh = try XCTUnwrap(p.viewerMesh)
        // Face 4's lattice bands, unpressed (his entries there removed)
        for f in m.settings.faces where m.regions.faces(of: f.faceRegionID, mesh: mesh) == [4] { m.removeFace(f.faceRegionID) }
        try await F.reopen(m, "Face 4 unpressed")
        func violet(_ sectionTints: Bool) throws -> (bands: Int, bandViolet: Int, middle: Int, middleTinted: Int) {
            let overlay = try XCTUnwrap(FlexiblePageChannels.overlay(model: m))
            let ch = FlexiblePageChannels.channels(model: m, overlay: overlay, xray: false, drawnLattice: nil, sectionTints: sectionTints)
            let tints = try XCTUnwrap(ch.tints)
            let (lo, hi) = F.box(p)
            let token = FlexibleStageStyle.facePrismTint
            var out = (0, 0, 0, 0)
            for (i, f) in overlay.keptFace.enumerated() where f == 4 {
                let x = overlay.keptCentroid[i].x
                let t = SIMD4<Float>(tints[24 * i], tints[24 * i + 1], tints[24 * i + 2], tints[24 * i + 3])
                let isViolet = t.w > 0.05 && simd_distance(SIMD3(t.x, t.y, t.z), token) < 0.05
                if x < lo.x + 25 || x > hi.x - 25 { out.0 += 1; if isViolet { out.1 += 1 } }
                else { out.2 += 1; if t.w > 0.01 { out.3 += 1 } }
            }
            return out
        }
        let on = try violet(true)
        print("FLEX-M2-TINT Face 4: band triangles \(on.bands) (violet \(on.bandViolet)) · middle \(on.middle) (tinted \(on.middleTinted))")
        XCTAssertGreaterThan(on.bands, 0, "premise: Face 4's bands are their own triangles (the overlay cuts at the band)")
        XCTAssertEqual(on.bandViolet, on.bands, "★ the lattice bands wear the face-prism violet")
        XCTAssertEqual(on.middleTinted, 0, "★ the solid middle stays the part's colour")
        // ★ RED CONTROL: no section tint (today's)
        let off = try violet(false)
        XCTAssertEqual(off.bandViolet, 0, "control: nothing says where a tap works")
    }

    // MARK: - (8) edges nest inside the lattice section

    func testEdgesNestInsideTheLatticeSection() async throws {
        let (r, _, m) = try await F.pad(self)
        let p = r.project
        let mesh = try XCTUnwrap(p.viewerMesh)
        let band5Before = F.pieces(m, face: 2).first { m.regions.cuts(of: $0.wireID).isEmpty == false && F.area(m, $0.wireID, face: 2) > 1
            && FlexibleEdgeStrips.area(FlexibleEdgeStrips.triangles(face: 2, mesh: mesh), m.regions.cuts(of: $0.wireID) + [RegionCut(point: F.box(p).lo + SIMD3(25.5, 0, 0), normal: SIMD3(1, 0, 0))]) < 1e-6 }
        let bandA = try XCTUnwrap(band5Before, "Face 2's band under Face 5's face-prism (x ≤ 25)")
        let bandACuts = m.regions.cuts(of: bandA.wireID)
        let pick = try await F.pickMode(m)
        let e14 = try XCTUnwrap(F.edge(m, pick, faces: [2, 3]), "Edge 14: Face 2's band + Face 3")
        m.toggleEdgePick(e14.number)
        let why = try await F.done(m)
        XCTAssertNil(why)
        let press = try XCTUnwrap(m.presses.first { $0.strip != nil })
        let k2 = try XCTUnwrap(press.strip?.members.firstIndex { $0.face == 2 })
        let strip2 = press.regions[k2]
        let tris2 = FlexibleEdgeStrips.triangles(face: 2, mesh: mesh)
        let (lo, hi) = F.box(p)
        let bandB: [RegionCut] = [RegionCut(point: SIMD3(hi.x - 25, lo.y, lo.z), normal: SIMD3(1, 0, 0))]
        let aStrip = F.area(m, strip2, face: 2)
        let aIn = FlexibleEdgeStrips.area(tris2, m.regions.cuts(of: strip2) + bandB)
        print(String(format: "FLEX-M2-EDGE Face 2's strip %d: %.2f mm², inside the band %.2f mm²", strip2, aStrip, aIn))
        XCTAssertGreaterThan(aStrip, 1)
        XCTAssertEqual(aIn, aStrip, accuracy: 1e-6 * max(1, aStrip), "★ the strip lies inside Face 2's lattice band")
        let rests = (m.regions.flexible?.pieces ?? []).filter { $0.kind == .rest && m.regions.faces(of: $0.wireID, mesh: mesh) == [2] }
        let restArea = rests.reduce(0) { $0 + F.area(m, $1.wireID, face: 2) }
        XCTAssertEqual(aStrip + restArea, 25 * (hi.z - lo.z), accuracy: 0.05, "★ the band's rest is the band less the strip")
        XCTAssertEqual(m.regions.cuts(of: bandA.wireID), bandACuts, "★ the Face 5 band is untouched")
        // an edge whose lattice lies in two places on a member face (Face 2's bottom edge, along its whole length)
        let along = FlexibleStrip.Member(face: 2, root: -1, origin: lo, away: [SIMD3(0, 0, 1)], along: SIMD3(1, 0, 0),
                                         span: [0, hi.x - lo.x], capMM: (hi.z - lo.z) / 2)
        let two = FlexibleStrip(kind: .edge, label: "Edge 99", widthMM: 4, order: 99, members: [along])
        let id = UUID()
        let set = FlexibleSectors.resolve(mesh: mesh, faceRegions: m.restoredFaceRegions, includes: F.includes(p),
                                          strips: [(id, two)], newPicks: [id], numbers: FlexibleSectorNumbers())
        XCTAssertEqual(set.refused[id], FlexibleRowCopy.latticeInTwoPlaces("Edge 99"), "★ refused with its one line")

        // ★ RED CONTROL: I2's whole-face root — the strip crosses the solid middle
        FlexibleLatticeSections.controlWholeFace = true
        let cset = FlexibleSectors.resolve(mesh: mesh, faceRegions: m.restoredFaceRegions, includes: F.includes(p),
                                           strips: [(id, two)], newPicks: [id], numbers: FlexibleSectorNumbers())
        let reg = cset.stripRegions[id]?.first
        let crossing = reg.flatMap { cset.piece($0) }.map { FlexibleEdgeStrips.area(tris2, $0.region.cuts + [RegionCut(point: SIMD3(lo.x + 30, lo.y, lo.z), normal: SIMD3(1, 0, 0)), RegionCut(point: SIMD3(hi.x - 30, lo.y, lo.z), normal: SIMD3(-1, 0, 0))]) } ?? 0
        print("FLEX-M2-EDGE control: refused \(cset.refused[id] ?? "none") · strip area over the solid middle \(crossing) mm²")
        XCTAssertNil(cset.refused[id], "control: accepted")
        XCTAssertGreaterThan(crossing, 1, "control: the strip crosses the solid middle")
    }

    // MARK: - (9) the job declares the sections; every other entry byte-identical

    func testTheJobDeclaresSectionsAndEveryOtherEntryIsByteIdentical() async throws {
        FlexibleLatticeSections.controlWholeFace = true
        let (_, _, m0) = try await F.pad(self)
        let before = try F.sendEntries(m0)   // the bytes before M2 (whole faces)
        FlexibleLatticeSections.controlWholeFace = false
        let (r, _, m) = try await F.pad(self)
        let after = try F.sendEntries(m)
        XCTAssertEqual(Set(before.keys), Set(after.keys), "the same sends")
        let mesh = try XCTUnwrap(r.project.viewerMesh)
        for (send, b) in before {
            let a = try XCTUnwrap(after[send])
            for id in [0, 3, 5] where b.faces[id] != nil {
                XCTAssertEqual(a.faces[id], b.faces[id], "★ \(send): face \(id)'s entry byte-identical")
            }
            for id in [1, 2, 4] where b.faces[id] != nil {
                XCTAssertNil(a.faces[id], "★ \(send): face \(id) presses its lattice sections, never the whole face")
                let secs = a.faces.keys.filter { FlexibleRegions.isFlexible($0) && m.regions.faces(of: $0, mesh: mesh) == [id] }
                XCTAssertEqual(secs.count, 2, "\(send): face \(id)'s two sections")
                for s in secs { XCTAssertNotNil(a.declared[s], "\(send): section \(s) declared in face_regions") }
            }
            for (id, d) in b.declared { XCTAssertEqual(a.declared[id], d, "\(send): declaration \(id) byte-identical") }
            let added = a.declared.keys.filter { b.declared[$0] == nil }.sorted()
            XCTAssertTrue(added.allSatisfy(FlexibleRegions.isFlexible), "\(send): only Flexible sectors are added: \(added)")
            print("FLEX-M2-JOB \(send): +\(added.count) declarations \(added.prefix(8)) · faces \(a.faces.keys.sorted())")
        }
        // core reads every send
        for send in FlexibleAngledGoldens.sends(m) {
            let job = try m.runJobJSON(resting: Set(send.resting))
            XCTAssertNoThrow(try FlexibleCore.parseJobBlock(job), "\(send.title): core parses the job")
        }
        // ★ RED CONTROL: the whole Top stays an entry
        XCTAssertTrue(before.values.contains { $0.faces[1] != nil }, "control: the whole Top is an entry")
    }
}
