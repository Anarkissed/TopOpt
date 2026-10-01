import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ BATCH E — "a protected face isn't frozen" (his item 4). The cause was the SPLIT: a cut piece
/// (his 'top A', region 103, face 1 cut at x = 50) never reached the run, so its row said "Frozen,
/// not latticed" / "Out of regime" and the Flexible job latticed the whole part. A piece is now its
/// members' outlines clipped to its half-spaces, emitted as ordinary face prisms under its own key.
///
/// Every comparison has a control computed beside it (the whole face, a cut moved to x = 90, the
/// sibling switched off, the old rule's answer) so an assertion cannot pass by measuring nothing.
@MainActor
final class LatticeSectorOutlineTests: XCTestCase {

    // MARK: - fixtures

    /// His pad: 100 × 100 × 20, six B-rep planes — 0 bottom, 1 top, 2 front (y = 0), 3 right
    /// (x = 100), 4 back (y = 100), 5 left (x = 0).
    static func pad() -> ViewerMesh {
        let v: [Float] = [0, 0, 0, 100, 0, 0, 100, 100, 0, 0, 100, 0,
                          0, 0, 20, 100, 0, 20, 100, 100, 20, 0, 100, 20]
        let idx: [Int32] = [0, 2, 1, 0, 3, 2,   4, 5, 6, 4, 6, 7,   0, 1, 5, 0, 5, 4,
                            1, 2, 6, 1, 6, 5,   2, 3, 7, 2, 7, 6,   3, 0, 4, 3, 4, 7]
        let fid: [Int32] = [0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5]
        let n: [SIMD3<Double>] = [SIMD3(0, 0, -1), SIMD3(0, 0, 1), SIMD3(0, -1, 0),
                                  SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(-1, 0, 0)]
        let o: [SIMD3<Double>] = [SIMD3(0, 0, 0), SIMD3(0, 0, 20), SIMD3(0, 0, 0),
                                  SIMD3(100, 0, 0), SIMD3(0, 100, 0), SIMD3(0, 0, 0)]
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fid,
                          faceGeometry: n.indices.map { StepFaceGeometry(kind: .plane, planeNormal: n[$0], planeOrigin: o[$0]) })
    }

    struct Pad {
        let p: ProjectModel
        let gid: UUID
        let top: RegionID
        let a: RegionID      // x ≥ 50
        let b: RegionID      // x < 50
    }

    /// The pad with its top split at x = 50 and ONLY 'top A' in a load group set to Lattice at
    /// 25 mm — his img 4 state. `protected` adds Protect (his rule: protect + lattice = lattice).
    static func splitPad(protected: Bool = false) -> Pad {
        let p = ProjectModel(id: UUID(), name: "Pad split top", material: "PLA", process: .fdm,
                             importedFile: nil, importedMesh: nil)
        p.viewerMesh = pad()
        let top = p.faceRegions.union(faces: [1], named: "top")
        let kids = p.faceRegions.splitManual(top, point: SIMD3(50, 50, 20), normal: SIMD3(1, 0, 0))
        let gid = p.selection.addGroup()
        p.selection.addRegions([kids[0]], to: gid)
        p.force.sync(groups: p.selection.groups)
        p.force.makeLoad(gid)
        if protected { p.force.setProtected(gid, true) }
        p.lattice.enabled = true
        p.lattice.paintDepthMM = 4
        p.lattice.groupRoles[gid] = .include
        p.writeLatticeDepthMM(.region(group: gid, region: kids[0]), mm: 25)
        return Pad(p: p, gid: gid, top: top, a: kids[0], b: kids[1])
    }

    /// A region's prisms, by its key.
    static func prisms(_ p: ProjectModel, _ gid: UUID, _ rid: RegionID) -> [LatticeRegionSpec] {
        let key = LatticeSelectableRef.region(group: gid, region: rid).key
        return p.latticeJobRegions().regions.filter { $0.selectableKey == key }
    }

    /// Every outline vertex of a face prism, in WORLD coordinates (the slab's own frame).
    static func worldVertices(_ r: LatticeRegionSpec) -> [SIMD3<Double>] {
        let (bu, bv) = LatticeRegionMask.basis(LatticeRegionMask.unit(r.normal))
        return r.outlineLoops.flatMap { $0.map { r.origin + bu * $0.x + bv * $0.y } }
    }

    static func area(_ r: LatticeRegionSpec) -> Double { LatticeSectorOutline.evenOddArea(r.outlineLoops) }

    /// The unit square of side `s` centred on the origin, in a face frame.
    static func square(_ s: Double, at c: SIMD2<Double> = .zero) -> [SIMD2<Double>] {
        let h = s / 2
        return [c + SIMD2(-h, -h), c + SIMD2(h, -h), c + SIMD2(h, h), c + SIMD2(-h, h)]
    }

    /// A +z plane face at z = 20 centred on (50, 50): its frame is LatticeRegionMask.basis(+z).
    static func topFace(_ loops: [[SIMD2<Double>]], neighbours: [[FaceID?]] = []) -> LatticeRegionEmission.ResolvedFace {
        .plane(center: SIMD3(50, 50, 20), normal: SIMD3(0, 0, 1), halfUMM: 50, halfWMM: 50,
               outlineLoops: loops, neighbours: neighbours)
    }

    /// World x of a face-frame point on `topFace`.
    static func worldX(_ q: SIMD2<Double>) -> Double {
        let (bu, bv) = LatticeRegionMask.basis(SIMD3(0, 0, 1))
        return (SIMD3<Double>(50, 50, 20) + bu * q.x + bv * q.y).x
    }

    static func loops(of f: LatticeRegionEmission.ResolvedFace?) -> [[SIMD2<Double>]] {
        guard let f, case let .plane(_, _, _, _, l, _) = f else { return [] }
        return l
    }
    static func neighbours(of f: LatticeRegionEmission.ResolvedFace?) -> [[FaceID?]] {
        guard let f, case let .plane(_, _, _, _, _, n) = f else { return [] }
        return n
    }

    static let cutX50 = RegionCut(point: SIMD3(50, 50, 20), normal: SIMD3(1, 0, 0))
    static let cutX90 = RegionCut(point: SIMD3(90, 50, 20), normal: SIMD3(1, 0, 0))

    // MARK: - the clip, on its own

    /// Half the face is kept, and it is the RIGHT half: positional, because an area cannot see a
    /// mirror (memory: "area assertions can't catch a MIRROR").
    func testAHalfPieceKeepsHalfTheFaceOnItsOwnSide() throws {
        let face = Self.topFace([Self.square(100)])
        let half = try XCTUnwrap(LatticeSectorOutline.clip(face, to: [Self.cutX50], ownFace: 1))
        let whole = LatticeSectorOutline.evenOddArea(Self.loops(of: face))
        let kept = LatticeSectorOutline.evenOddArea(Self.loops(of: half))
        XCTAssertEqual(whole, 10000, accuracy: 1e-6, "control: the whole face")
        XCTAssertEqual(kept, 5000, accuracy: 1e-6, "★ half the face")
        for q in Self.loops(of: half).joined() {
            XCTAssertGreaterThanOrEqual(Self.worldX(q), 50 - 1e-9, "★ every vertex on x ≥ 50")
        }
        // RED control: the cut's position is read — at x = 90 a tenth is kept
        let tenth = try XCTUnwrap(LatticeSectorOutline.clip(face, to: [Self.cutX90], ownFace: 1))
        XCTAssertEqual(LatticeSectorOutline.evenOddArea(Self.loops(of: tenth)), 1000, accuracy: 1e-6)
        XCTAssertNotEqual(kept, whole, accuracy: 1, "a clip that ignored the cut would read 10000")
        // the other half: the strict sibling keeps x < 50
        let b = try XCTUnwrap(LatticeSectorOutline.clip(
            face, to: [RegionCut(point: SIMD3(50, 50, 20), normal: SIMD3(-1, 0, 0), strict: true)], ownFace: 1))
        for q in Self.loops(of: b).joined() { XCTAssertLessThanOrEqual(Self.worldX(q), 50 + 1e-9) }
    }

    /// Surviving edges keep the face across them; the cut edge reads the piece's OWN face (so the
    /// seam pass can pair it with the sibling).
    func testTheCutEdgeReadsTheOwnFaceAndTheRestKeepTheirs() throws {
        let sq = Self.square(100)
        let given: [FaceID?] = [2, 3, 4, 5]
        let face = Self.topFace([sq], neighbours: [given])
        // control: which original edge lies wholly on x ≤ 50 (the one the cut removes)
        let dropped = sq.indices.filter { Self.worldX(sq[$0]) < 50 && Self.worldX(sq[($0 + 1) % 4]) < 50 }
        XCTAssertEqual(dropped.count, 1, "control: one edge of the square lies at x = 0")
        let half = try XCTUnwrap(LatticeSectorOutline.clip(face, to: [Self.cutX50], ownFace: 1))
        let loop = try XCTUnwrap(Self.loops(of: half).first)
        let nb = try XCTUnwrap(Self.neighbours(of: half).first)
        XCTAssertEqual(loop.count, nb.count)
        var cutEdges = 0
        for i in loop.indices {
            let a = loop[i], b = loop[(i + 1) % loop.count]
            let onCut = abs(Self.worldX(a) - 50) < 1e-9 && abs(Self.worldX(b) - 50) < 1e-9
            if onCut { cutEdges += 1; XCTAssertEqual(nb[i], 1, "★ the cut edge reads face 1 itself") }
            else { XCTAssertNotEqual(nb[i], 1, "a surviving edge keeps its own neighbour") }
        }
        XCTAssertEqual(cutEdges, 1)
        let kept = Set(given.indices.filter { !dropped.contains($0) }.compactMap { given[$0] })
        XCTAssertEqual(Set(nb.compactMap { $0 }), kept.union([1]),
                       "★ the three surviving edges keep theirs; the dropped edge's face is gone")
    }

    /// A HOLE straddling the cut becomes a notch; the even-odd area is exact.
    func testAHoleAcrossTheCutIsKeptExactly() throws {
        // a 20 × 20 hole centred on world x = 50 (frame-agnostic: built around the face centre)
        let face = Self.topFace([Self.square(100), Self.square(20)])
        let half = try XCTUnwrap(LatticeSectorOutline.clip(face, to: [Self.cutX50], ownFace: 1))
        XCTAssertEqual(LatticeSectorOutline.evenOddArea(Self.loops(of: half)), 5000 - 200, accuracy: 1e-6)
        XCTAssertEqual(LatticeSectorOutline.evenOddArea(Self.loops(of: face)), 10000 - 400, accuracy: 1e-6,
                       "control: the whole face with its hole")
    }

    /// A cut across both arms of a U leaves two arm tips: two SIMPLE loops, and no outline edge
    /// runs across the air between them (a bridge would be rimmed).
    func testACutAcrossAUsArmsGivesTwoLoopsAndNoBridge() throws {
        // the +z face's frame: u = −world y, v = +world x (LatticeRegionMask.basis, core's order)
        let (bu, bv) = LatticeRegionMask.basis(SIMD3(0, 0, 1))
        XCTAssertEqual(bu, SIMD3(0, -1, 0)); XCTAssertEqual(bv, SIMD3(1, 0, 0))
        // a world offset (dx, dy) from the face centre (50, 50) → the frame
        func P(_ dx: Double, _ dy: Double) -> SIMD2<Double> { SIMD2(-dy, dx) }
        // a U: base at dx ∈ [−40, −20], arms out to dx = 40 at dy ∈ [−40, −20] and [20, 40]
        let u: [SIMD2<Double>] = [P(-40, -40), P(40, -40), P(40, -20), P(-20, -20),
                                  P(-20, 20), P(40, 20), P(40, 40), P(-40, 40)]
        let face = Self.topFace([u])
        XCTAssertEqual(Self.loops(of: face).count, 1, "control: the uncut U is one loop")
        XCTAssertEqual(LatticeSectorOutline.evenOddArea([u]), 80 * 80 - 60 * 40, accuracy: 1e-6, "control: the U's area")
        let tips = try XCTUnwrap(LatticeSectorOutline.clip(face, to: [Self.cutX50], ownFace: 1))
        let ls = Self.loops(of: tips)
        XCTAssertEqual(ls.count, 2, "★ two arm tips, two loops")
        XCTAssertEqual(LatticeSectorOutline.evenOddArea(ls), 2 * 40 * 20, accuracy: 1e-6)
        for l in ls { XCTAssertGreaterThan(abs(LatticeSectorOutline.area(l)), 1, "no loop of no width") }
        // ★ no outline edge runs over the air between the arms (|dy| < 20, where dy = −u)
        for l in ls { for i in l.indices {
            let m = 0.5 * (l[i] + l[(i + 1) % l.count])
            XCTAssertFalse(abs(m.x) < 19.999, "an outline edge over the gap at \(m)")
        } }
    }

    /// Wholly outside ⇒ nothing; wholly inside ⇒ the face exactly as it was; two cuts ⇒ a quarter.
    func testOutsideInsideAndTwoCuts() throws {
        let face = Self.topFace([Self.square(100)])
        XCTAssertNil(LatticeSectorOutline.clip(face, to: [RegionCut(point: SIMD3(150, 0, 0), normal: SIMD3(1, 0, 0))], ownFace: 1))
        let inside = try XCTUnwrap(LatticeSectorOutline.clip(face, to: [RegionCut(point: SIMD3(-10, 0, 0), normal: SIMD3(1, 0, 0))], ownFace: 1))
        XCTAssertEqual(Self.loops(of: inside), Self.loops(of: face), "untouched: the same loops")
        let quarter = try XCTUnwrap(LatticeSectorOutline.clip(
            face, to: [Self.cutX50, RegionCut(point: SIMD3(50, 50, 20), normal: SIMD3(0, 1, 0))], ownFace: 1))
        XCTAssertEqual(LatticeSectorOutline.evenOddArea(Self.loops(of: quarter)), 2500, accuracy: 1e-6)
    }

    /// A tilted face: the cut is evaluated in WORLD space through the face's own frame.
    func testATiltedFaceIsCutInWorldSpace() throws {
        let n = simd_normalize(SIMD3<Double>(1, 0, 1))
        let c = SIMD3<Double>(10, 0, 10)
        let face = LatticeRegionEmission.ResolvedFace.plane(center: c, normal: n, halfUMM: 10, halfWMM: 10,
                                                            outlineLoops: [Self.square(20)], neighbours: [])
        let cut = RegionCut(point: c, normal: SIMD3(0, 1, 0))   // world y ≥ 0
        let half = try XCTUnwrap(LatticeSectorOutline.clip(face, to: [cut], ownFace: 9))
        let (bu, bv) = LatticeRegionMask.basis(n)
        let ls = Self.loops(of: half)
        XCTAssertEqual(LatticeSectorOutline.evenOddArea(ls), 200, accuracy: 1e-6)
        for q in ls.joined() { XCTAssertGreaterThanOrEqual((c + bu * q.x + bv * q.y).y, -1e-9) }
    }

    // MARK: - the project: his img 4 state

    /// ★ HIS ITEM 4, the row: 'top A' reaches the run. RED (the old rule): it did not, and the row
    /// said "Frozen, not latticed".
    func testASplitPieceReachesTheRun() {
        let pad = Self.splitPad()
        XCTAssertTrue(pad.p.latticeReachesTheRun(.region(group: pad.gid, region: pad.a)),
                      "★ a split piece is latticed — the row shows no 'Frozen' chip")
        XCTAssertFalse(pad.p.force.isProtected(pad.gid), "control: his Top group is not even protected")
        XCTAssertEqual(pad.p.latticeJobRegions().skippedRegionNames, [], "★ nothing named as left out")
    }

    /// ★ The prism lands only on its own side of the cut, at the piece's own depth, one prism.
    func testThePiecesPrismLandsOnlyOnItsOwnSide() throws {
        let pad = Self.splitPad()
        let prisms = Self.prisms(pad.p, pad.gid, pad.a)
        XCTAssertEqual(prisms.count, 1, "one prism for top A")
        let r = try XCTUnwrap(prisms.first)
        XCTAssertEqual(r.role, .include)
        XCTAssertEqual(r.faceID, 1)
        XCTAssertEqual(r.depthMM, 25, accuracy: 1e-9, "the piece's own depth")
        XCTAssertEqual(Self.area(r), 5000, accuracy: 1e-6, "★ half of face 1")
        for p in Self.worldVertices(r) {
            XCTAssertGreaterThanOrEqual(p.x, 50 - 1e-6, "★ on x ≥ 50 only")
            XCTAssertEqual(p.z, 20, accuracy: 1e-6, "the mouth on the top face")
        }
        // core's own containment, at the voxel: a point under top B is NOT in the prism
        XCTAssertTrue(LatticeRegionMask.containsWholePrism(SIMD3(75, 50, 10), region: r))
        XCTAssertFalse(LatticeRegionMask.containsWholePrism(SIMD3(25, 50, 10), region: r), "★ top B's side is not latticed")
    }

    /// ★ The cut edge is a SEAM when the sibling is latticed (no wall between two latticed halves)
    /// and a RIM when it is not (the lattice ends under a wall).
    func testTheCutEdgeIsASeamOnlyWhenTheSiblingIsLatticed() throws {
        func cutEdgeSeams(_ p: ProjectModel, _ gid: UUID, _ rid: RegionID) throws -> [Bool] {
            let r = try XCTUnwrap(Self.prisms(p, gid, rid).first)
            let (bu, bv) = LatticeRegionMask.basis(LatticeRegionMask.unit(r.normal))
            var out: [Bool] = []
            for (l, loop) in r.outlineLoops.enumerated() { for i in loop.indices {
                let a = r.origin + bu * loop[i].x + bv * loop[i].y
                let b = r.origin + bu * loop[(i + 1) % loop.count].x + bv * loop[(i + 1) % loop.count].y
                if abs(a.x - 50) < 1e-6, abs(b.x - 50) < 1e-6 {
                    out.append(l < r.outlineSeams.count && i < r.outlineSeams[l].count && r.outlineSeams[l][i])
                }
            } }
            return out
        }
        // the sibling off: a rim
        let alone = Self.splitPad()
        XCTAssertEqual(try cutEdgeSeams(alone.p, alone.gid, alone.a), [false], "★ top B not latticed ⇒ a rim on the cut")
        // the sibling latticed: a seam on both sides
        let both = Self.splitPad()
        both.p.selection.addRegions([both.b], to: both.gid)
        both.p.force.sync(groups: both.p.selection.groups)
        XCTAssertEqual(try cutEdgeSeams(both.p, both.gid, both.a), [true], "★ top B latticed ⇒ a seam")
        XCTAssertEqual(try cutEdgeSeams(both.p, both.gid, both.b), [true])
    }

    /// ★ A piece cut again (A → A1, A2) meets its sibling B along x = 50 at a T: every stretch of
    /// that line is a seam on both sides. RED (no T-junction pass): A1/A2's edges are rimmed.
    func testAPieceCutAgainMeetsItsSiblingAtTheT() throws {
        let pad = Self.splitPad()
        let quarters = pad.p.faceRegions.splitManual(pad.a, point: SIMD3(75, 50, 20), normal: SIMD3(0, 1, 0))
        XCTAssertEqual(quarters.count, 2)
        pad.p.selection.removeRegions([pad.a])
        pad.p.selection.addRegions(quarters + [pad.b], to: pad.gid)
        pad.p.force.sync(groups: pad.p.selection.groups)
        let all = pad.p.latticeJobRegions().regions
        XCTAssertEqual(all.count, 3, "two quarters and a half")
        XCTAssertEqual(all.map { Self.area($0) }.reduce(0, +), 10000, accuracy: 1e-6, "★ they tile face 1 exactly")
        var stretch = 0.0
        for r in all {
            let (bu, bv) = LatticeRegionMask.basis(LatticeRegionMask.unit(r.normal))
            for (l, loop) in r.outlineLoops.enumerated() { for i in loop.indices {
                let a = r.origin + bu * loop[i].x + bv * loop[i].y
                let b = r.origin + bu * loop[(i + 1) % loop.count].x + bv * loop[(i + 1) % loop.count].y
                guard abs(a.x - 50) < 1e-6, abs(b.x - 50) < 1e-6 else { continue }
                stretch += simd_length(b - a)
                XCTAssertTrue(l < r.outlineSeams.count && r.outlineSeams[l][i],
                              "★ x = 50 from y \(a.y) to \(b.y) on \(r.selectableKey ?? "?") is a seam")
            } }
        }
        XCTAssertEqual(stretch, 200, accuracy: 1e-6, "control: x = 50 is walked once from each side")
    }

    /// ★ PROTECTED + LATTICE = LATTICE (his rule). A protected cut piece is latticed, protected to
    /// the depth its slab emits, and core's own parser accepts the stage job.
    func testAProtectedPieceIsLatticedAndProtectedToItsSlab() throws {
        let pad = Self.splitPad(protected: true)
        let r = try XCTUnwrap(Self.prisms(pad.p, pad.gid, pad.a).first, "★ protected and latticed")
        let prot = pad.p.faceProtectionSpecs()
        XCTAssertEqual(prot.regionIDs, [pad.a])
        XCTAssertEqual(prot.regionDepthsMM, [r.depthMM], "the protection is the slab (round 3 ruling a)")
        let emission = pad.p.latticeJobRegions()
        let request = RunRequest(
            modelPath: "/tmp/pad.step", material: "PLA", materialsPath: "", rulesPath: "", resolution: 64,
            projectName: "pad", anchorFaceIDs: [0],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [1], force: SIMD3(0, 0, -98))],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            faceProtections: prot.faceIDs, faceProtectionDepthMM: prot.depthMM, faceProtectionDepthsMM: prot.depthsMM,
            faceRegions: pad.p.faceRegions.regions,
            faceProtectionRegionIDs: prot.regionIDs, faceProtectionRegionDepthsMM: prot.regionDepthsMM,
            lattice: pad.p.latticeRunSpec(emission: emission), jobMode: "lattice_part")
        let doc = try RemoteRun.buildJobJSON(request)
        XCTAssertNil(TopOptKit.jobSchemaError(doc), "★ core accepts — \(TopOptKit.jobSchemaError(doc) ?? "")")
        // the wire carries the clipped outline: every outline_uv point on top A's side
        let obj = try XCTUnwrap(try JSONSerialization.jsonObject(with: doc) as? [String: Any])
        let regions = try XCTUnwrap((obj["lattice"] as? [String: Any])?["regions"] as? [[String: Any]])
        XCTAssertEqual(regions.count, 1, "one prism on the wire")
        let geo = (regions[0]["geometry"] as? [String: Any]) ?? regions[0]
        let loops = try XCTUnwrap(geo["outline_uv"] as? [[[Double]]])
        let uv = loops.map { $0.map { SIMD2($0[0], $0[1]) } }
        XCTAssertEqual(LatticeSectorOutline.evenOddArea(uv), 5000, accuracy: 1e-6, "★ half the face on the wire")
    }

    /// ★ "Frozen" only when protected — and never "Out of regime". The words, and where they are
    /// used (a source pin on the row chip and the drawer, which are #354's files).
    func testTheWordsSayProtectedOnlyWhenProtected() throws {
        XCTAssertEqual(LatticeSectorOutline.notLatticedWords(protected: true), "Protected, not latticed")
        XCTAssertEqual(LatticeSectorOutline.notLatticedWords(protected: false), "Not latticed")
        for w in [true, false].map(LatticeSectorOutline.notLatticedWords) {
            XCTAssertFalse(w.lowercased().contains("frozen"))
            XCTAssertLessThanOrEqual(w.split(separator: " ").count, 3, "R7: three words")
        }
        let unprotected = LatticeRegionDrawer.make(card: nil, depthMM: 7, held: false, latticeReachesTheRun: false)
        XCTAssertEqual(unprotected.headline?.text, "Not latticed", "★ an unprotected region is never called frozen")
        XCTAssertNotEqual(unprotected.headline?.verdict, .outOfRegime, "★ never 'Out of regime'")
        let protected = LatticeRegionDrawer.make(card: nil, depthMM: 7, held: true, latticeReachesTheRun: false)
        XCTAssertEqual(protected.headline?.text, "Protected, not latticed")
        // the row chip reads the group's protection
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let wp = try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertTrue(wp.contains("Text(LatticeSectorOutline.notLatticedWords(protected: force.isProtected(g.id)))"),
                      "the row chip says Protected only for a protected group")
    }

    // MARK: - the emission, pure

    private func plane100() -> LatticeRegionEmission.ResolvedFace {
        Self.topFace([Self.square(100)], neighbours: [[2, 3, 4, 5]])
    }

    /// ★ BYTE-IDENTICAL WITHOUT CUTS: the hook's default and an explicit "whole face" are the same
    /// emission, for direct faces, region members and facets alike. Control: a real cut moves it.
    func testWithoutACutTheEmissionIsUnchanged() {
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [7], regionIDs: [101, 102])
        func run(_ cuts: ((RegionID, FaceID) -> [[RegionCut]])?) -> LatticeRegionEmission.Result {
            let members: (UUID, RegionID) -> [FaceID]? = { _, rid in rid == 101 ? [1] : [9] }
            let resolve: (FaceID) -> LatticeRegionEmission.ResolvedFace? = { $0 == 9 ? nil : self.plane100() }
            let facets: (FaceID) -> [LatticeRegionEmission.ResolvedFace] = { _ in [self.plane100(), self.plane100()] }
            if let cuts {
                return LatticeRegionEmission.regions(groups: [group], roles: [gid: .include], primitives: { _ in [] },
                                                     includePrimitives: [], faceDepthMM: 4, regionMembers: members,
                                                     regionCuts: cuts, facets: facets, resolve: resolve)
            }
            return LatticeRegionEmission.regions(groups: [group], roles: [gid: .include], primitives: { _ in [] },
                                                 includePrimitives: [], faceDepthMM: 4, regionMembers: members,
                                                 facets: facets, resolve: resolve)
        }
        let before = run(nil)
        XCTAssertEqual(before.regions.count, 4, "control: face 7, region 101's face 1, region 102's two facets")
        XCTAssertEqual(run { _, _ in [[]] }, before, "★ [[]] is the face as it always was")
        XCTAssertNotEqual(run { rid, _ in rid == 101 ? [[Self.cutX50]] : [[]] }, before, "control: a cut moves it")
    }

    /// The pure emission: a piece emits its own side; a member wholly outside the piece is not a
    /// SKIPPED face (it has a shape — the piece just does not hold it).
    func testTheEmissionClipsAPieceAndDoesNotCountAFaceOutsideItAsSkipped() throws {
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [], regionIDs: [103])
        let r = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include], primitives: { _ in [] }, includePrimitives: [], faceDepthMM: 4,
            regionMembers: { _, _ in [1, 2] },
            regionCuts: { _, _ in [[Self.cutX50]] },
            resolve: { f in
                // face 2: a 100 × 100 face whose every point lies at world x < 50
                f == 2 ? .plane(center: SIMD3(0, 50, 10), normal: SIMD3(-1, 0, 0), halfUMM: 50, halfWMM: 10,
                                outlineLoops: [Self.square(20)], neighbours: [])
                       : self.plane100()
            })
        XCTAssertEqual(r.regions.count, 1, "face 1's half only")
        XCTAssertEqual(Self.area(try XCTUnwrap(r.regions.first)), 5000, accuracy: 1e-6)
        XCTAssertEqual(r.skippedFaces, 0, "★ face 2 lies outside the piece: not a skipped face")
        // control: without the cut both faces are emitted whole
        let whole = LatticeRegionEmission.regions(
            groups: [group], roles: [gid: .include], primitives: { _ in [] }, includePrimitives: [], faceDepthMM: 4,
            regionMembers: { _, _ in [1, 2] },
            resolve: { f in f == 2 ? .plane(center: SIMD3(0, 50, 10), normal: SIMD3(-1, 0, 0), halfUMM: 50, halfWMM: 10,
                                            outlineLoops: [Self.square(20)], neighbours: []) : self.plane100() })
        XCTAssertEqual(whole.regions.count, 2)
        XCTAssertEqual(Self.area(whole.regions[0]), 10000, accuracy: 1e-6)
    }

    /// A member with no outline to clip is a SKIPPED face, as it is unclipped — never "clipped away".
    func testAMemberWithNoOutlineIsStillCountedSkipped() {
        let gid = UUID()
        let group = SelectionGroup(id: gid, name: "C", colorIndex: 0, faces: [], regionIDs: [103])
        let noOutline: LatticeRegionEmission.ResolvedFace = .plane(center: SIMD3(50, 50, 20), normal: SIMD3(0, 0, 1),
                                                                   halfUMM: 50, halfWMM: 50, outlineLoops: [], neighbours: [])
        func run(_ cuts: [[RegionCut]]) -> LatticeRegionEmission.Result {
            LatticeRegionEmission.regions(groups: [group], roles: [gid: .include], primitives: { _ in [] },
                                          includePrimitives: [], faceDepthMM: 4, regionMembers: { _, _ in [1] },
                                          regionCuts: { _, _ in cuts }, resolve: { _ in noOutline })
        }
        XCTAssertEqual(run([[]]).skippedFaces, 1, "control: unclipped, a face with no outline is skipped")
        XCTAssertEqual(run([[Self.cutX50]]).skippedFaces, 1, "★ and so it is inside a piece")
    }

    // MARK: - unsplit projects: the hooks reduce to what was

    /// ★ On every project with no cut and no union of pieces the two hook closures ARE the old
    /// ones: every region's cut sets are `[[]]` and its emitted members are `latticeRegionMembers`.
    /// (The stage job bytes of his real projects, dumped before and after, are in the handoff.)
    func testOnAnUnsplitProjectTheHooksAreTheOldOnes() {
        let (p, gid, rid) = VariantFacePrismFixture.project()
        XCTAssertTrue(p.faceRegions.regions.allSatisfy { $0.cuts.isEmpty && $0.parts.isEmpty }, "control: unsplit")
        for f in p.latticeRegionMemberFaces(rid) {
            XCTAssertEqual(p.latticeRegionCutSets(rid, face: f).count, 1)
            XCTAssertEqual(p.latticeRegionCutSets(rid, face: f).first ?? [RegionCut(point: .zero, normal: SIMD3(1, 0, 0))], [])
        }
        XCTAssertEqual(p.latticeEmittedRegionMembers(gid, rid), p.latticeRegionMembers(rid))
        XCTAssertNotNil(p.latticeRegionMembers(rid))
        // control: split it, and the CHILD has cut sets of its own
        let kids = p.faceRegions.splitManual(rid, point: SIMD3(10, 5, 4.5), normal: SIMD3(0, 1, 0))
        let f = p.latticeRegionMemberFaces(kids[0]).first ?? 0
        XCTAssertEqual(p.latticeRegionCutSets(kids[0], face: f).first?.count, 1)
    }

    // MARK: - the row's 3D depth primitive

    /// ★ The Selections row's 3D depth primitive for 'top A' sits over top A (x ≥ 50), not over the
    /// whole top it was cut from. Control: the uncut 'top' region's primitive spans the whole face.
    func testTheRowsDepthPrimitiveSitsOverThePiece() throws {
        func xRange(_ p: ProjectModel, _ ref: LatticeSelectableRef) throws -> (lo: Float, hi: Float) {
            let plane = try XCTUnwrap(p.latticeDepthPlanes().first { $0.ref == ref }, "the row has a primitive")
            guard case let .shell(shell) = plane.volume.shape else { XCTFail("a shell"); return (0, 0) }
            let xs = shell.base.map(\.x)
            return (xs.min() ?? -1, xs.max() ?? -1)
        }
        let pad = Self.splitPad()
        let a = try xRange(pad.p, .region(group: pad.gid, region: pad.a))
        XCTAssertEqual(a.lo, 50, accuracy: 1e-3, "★ top A's primitive starts at the cut")
        XCTAssertEqual(a.hi, 100, accuracy: 1e-3)
        // control: the whole 'top' region in a group of its own spans the face
        let whole = Self.splitPad()
        let g2 = whole.p.selection.addGroup()
        whole.p.selection.addRegions([whole.top], to: g2)
        whole.p.force.sync(groups: whole.p.selection.groups)
        whole.p.force.setProtected(g2, true)
        whole.p.lattice.groupRoles[g2] = .include
        let t = try xRange(whole.p, .region(group: g2, region: whole.top))
        XCTAssertEqual(t.lo, 0, accuracy: 1e-3, "control: the uncut face's primitive spans 0…100")
        XCTAssertEqual(t.hi, 100, accuracy: 1e-3)
    }
}

