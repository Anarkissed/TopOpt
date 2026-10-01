import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★★ RULING 2 (maintainer, 2026-09-30): PROTECTION FOLLOWS THE SLAB. His 09-23 ruling moved an
/// expanded wall's far end deeper; core's depth tie makes protect + lattice on one face ONE slab;
/// so a protected, latticed face is protected to the depth its prism EMITS (depth + expand; a
/// negative expand shrinks both), read from the emission — never a second calculation. Only jobs
/// core refuses today change. Every verdict here is core's own parser's.
/// ★★ ROUND 3 RULING (a) (2026-10-01): and a protected, latticed REGION likewise — even though core
/// accepted the old encoding (its tie checks face ids only), which left the slab's last mm unfrozen.
@MainActor
final class LatticeProtectionFollowsSlabTests: XCTestCase {

    /// The stage's `lattice_part` document, built as `AppModel.makeRunRequest` builds it: ONE
    /// emission for the protections and the lattice regions. `preRuling` swaps in the face depths
    /// the app sent before this ruling (the DRAGGED depth, no expand).
    private func stageDocument(_ p: ProjectModel, preRuling: Bool = false) throws -> Data {
        let emission = p.latticeJobRegions()
        var prot = p.faceProtectionSpecs(emission: emission)
        if preRuling { prot.depthsMM = preRulingFaceDepths(p) }
        let request = RunRequest(
            modelPath: "/tmp/part.step", material: "PLA", materialsPath: "", rulesPath: "", resolution: 64,
            projectName: "slab", anchorFaceIDs: [0],
            loadGroups: [TopOptKit.LoadGroupSpec(faceIDs: [4], force: SIMD3(0, 0, -250))],
            minimizePlastic: true, buildDirection: SIMD3(0, 0, 1), infillPercent: 40, wallLoops: 3,
            wallLineWidthOuterMM: 0.45, wallLineWidthInnerMM: 0.45,
            faceProtections: prot.faceIDs, faceProtectionDepthMM: prot.depthMM, faceProtectionDepthsMM: prot.depthsMM,
            faceRegions: p.faceRegions.regions,
            faceProtectionRegionIDs: prot.regionIDs, faceProtectionRegionDepthsMM: prot.regionDepthsMM,
            lattice: p.latticeRunSpec(emission: emission), jobMode: "lattice_part")
        return try RemoteRun.buildJobJSON(request)
    }

    /// What `faceProtectionSpecs` sent before ruling 2, face by face: a latticed group's DRAGGED
    /// depth (`LatticeSlabDepth`, no expand), else the global depth.
    private func preRulingFaceDepths(_ p: ProjectModel) -> [Double] {
        var out: [Double] = []
        var seen = Set<FaceID>()
        for g in p.selection.groups where p.force.isProtected(g.id) {
            let latticed = p.lattice.enabled && p.lattice.groupRoles[g.id] != nil
            for f in g.faces where !seen.contains(f) {
                seen.insert(f)
                out.append(latticed
                    ? LatticeSlabDepth.depthMM(ref: .face(group: g.id, face: f), group: g.id,
                                               perSelectable: p.lattice.selectableDepthMM,
                                               perGroup: p.lattice.groupDepthMM, fallbackMM: p.lattice.paintDepthMM)
                    : p.force.faceProtectDepthMM)
            }
        }
        return out
    }

    private func sortedJSON(_ d: Data) throws -> Data {
        try JSONSerialization.data(withJSONObject: try JSONSerialization.jsonObject(with: d), options: [.sortedKeys])
    }

    /// ★ An expanded, protected wall (face 1, depth 20) — grown and shrunk.
    func testAnExpandedProtectedWallIsProtectedToTheDepthItEmits() throws {
        for e in [3.0, -2.0] {
            let (p, gid, _) = VariantFacePrismFixture.project()
            p.writeLatticeExpandMM(.face(group: gid, face: 1), mm: e)
            let prism = try XCTUnwrap(p.latticeJobRegions().regions.first { $0.kind == .face && $0.faceID == 1 })
            XCTAssertEqual(prism.depthMM, 20 + e, accuracy: 1e-12, "control: the slab emits depth + expand")
            // BEFORE: the dragged depth on the protection, depth + expand on the prism — core refuses
            let before = try stageDocument(p, preRuling: true)
            let why = try XCTUnwrap(TopOptKit.jobSchemaError(before), "expand \(e): the old encoding is refused")
            XCTAssertTrue(why.contains("face 1 is BOTH protected and a lattice region, at two different depths: "
                                       + "the protection is 20.000000 mm and the lattice region is "
                                       + String(format: "%.6f", 20 + e) + " mm"), why)
            // AFTER: one slab, one depth — core accepts
            let prot = p.faceProtectionSpecs()
            XCTAssertEqual(prot.faceIDs, [1])
            XCTAssertEqual(prot.depthsMM, [prism.depthMM], "★ the protection reads the depth the prism emits")
            let after = try stageDocument(p)
            XCTAssertNil(TopOptKit.jobSchemaError(after), "★ expand \(e): accepted — \(TopOptKit.jobSchemaError(after) ?? "")")
        }
    }

    /// Negative control: a wall with no expand is protected to exactly what it was, byte for byte.
    func testAnUnexpandedWallsProtectionAndBytesAreUnchanged() throws {
        let (p, _, _) = VariantFacePrismFixture.project()
        XCTAssertEqual(p.faceProtectionSpecs().depthsMM, preRulingFaceDepths(p))
        XCTAssertEqual(try sortedJSON(try stageDocument(p)), try sortedJSON(try stageDocument(p, preRuling: true)),
                       "★ an accepted job's bytes do not move")
        XCTAssertNil(TopOptKit.jobSchemaError(try stageDocument(p)))
    }

    /// ★★ ROUND 3 RULING (a) (maintainer, 2026-10-01): A REGION FOLLOWS ITS SLAB TOO. A
    /// protected, latticed region is protected to the depth its prisms emit (depth + expand; a
    /// negative expand shrinks both), the same one value from the emission as ruling 2. Core does
    /// not tie region protections, so the old encoding was ACCEPTED — silently leaving the last
    /// `expand` mm of the slab unfrozen (his stand's region 101: 20 against 24.15 mm).
    func testARegionsProtectionFollowsItsSlab() throws {
        for e in [4.15, -2.0] {
            let (p, gid, rid) = VariantFacePrismFixture.project()
            let key = LatticeSelectableRef.region(group: gid, region: rid).key
            p.writeLatticeExpandMM(.region(group: gid, region: rid), mm: e)
            let members = p.latticeJobRegions().regions.filter { $0.selectableKey == key }
            XCTAssertEqual(members.count, 2, "control: the region's two member prisms")
            XCTAssertTrue(members.allSatisfy { abs($0.depthMM - (20 + e)) < 1e-9 }, "control: they reach 20 + \(e) mm")
            let prot = p.faceProtectionSpecs()
            XCTAssertEqual(prot.regionIDs, [rid])
            XCTAssertEqual(prot.regionDepthsMM, [members[0].depthMM], "★ expand \(e): the region's protection is its slab")
            XCTAssertEqual(p.latticeJobRegions().slabDepthMM(selectableKey: key), members[0].depthMM)
            let doc = try stageDocument(p)
            let why = TopOptKit.jobSchemaError(doc)
            XCTAssertNil(why, "core accepts — \(why ?? "")")
            // the wire carries it
            let loads = try XCTUnwrap((try JSONSerialization.jsonObject(with: doc) as? [String: Any])?["loads"] as? [String: Any])
            let entry = try XCTUnwrap((loads["face_protections"] as? [[String: Any]])?.first { $0["region_id"] as? Int == Int(rid) })
            XCTAssertEqual(try XCTUnwrap(entry["depth_mm"] as? Double), 20 + e, accuracy: 1e-9, "★ on the wire")
        }
    }

    /// The region's protection keeps its own depth wherever the run lattices no prism under its
    /// key — and an unexpanded region's bytes do not move.
    func testARegionWithNoSlabOrNoExpandKeepsItsDepth() throws {
        // no expand: the protection was already the slab's depth, byte for byte
        do {
            let (p, _, _) = VariantFacePrismFixture.project()
            XCTAssertEqual(p.faceProtectionSpecs().regionDepthsMM, [20], "no expand ⇒ 20, as before")
        }
        // the region declared Off: no prism under its key ⇒ the dragged depth, even with an expand
        do {
            let (p, gid, rid) = VariantFacePrismFixture.project()
            let ref = LatticeSelectableRef.region(group: gid, region: rid)
            p.writeLatticeExpandMM(ref, mm: 4.15)
            p.lattice.selectableRoles[ref.key] = .off
            XCTAssertNil(p.latticeJobRegions().slabDepthMM(selectableKey: ref.key), "control: Off emits nothing")
            XCTAssertEqual(p.faceProtectionSpecs().regionDepthsMM, [20], "★ no slab ⇒ its dragged depth")
        }
        // a protected group with no lattice role: the global protection depth
        do {
            let (p, gid, rid) = VariantFacePrismFixture.project()
            p.writeLatticeExpandMM(.region(group: gid, region: rid), mm: 4.15)
            p.lattice.groupRoles[gid] = nil
            XCTAssertEqual(p.faceProtectionSpecs().regionDepthsMM, [p.force.faceProtectDepthMM], "★ unlatticed ⇒ the global depth")
        }
    }

    /// A protected, latticed BORE is emitted as a bolt (no face prism, no depth on the wire): its
    /// protection keeps the dragged depth, and core accepts it either way (the tie skips bolts).
    func testABoltFacesProtectionKeepsTheDraggedDepth() throws {
        let p = ProjectModel(id: UUID(), name: "Bore", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = Self.borePlusPlaneMesh()
        let gid = p.selection.addGroup()
        p.selection.pickFaces([1])
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.lattice.enabled = true
        p.lattice.groupRoles[gid] = .include
        p.writeLatticeDepthMM(.face(group: gid, face: 1), mm: 7)
        p.writeLatticeExpandMM(.face(group: gid, face: 1), mm: 3)
        let regions = p.latticeJobRegions().regions
        XCTAssertEqual(regions.map(\.kind), [.bolt], "control: the bore is a bolt, not a face prism")
        XCTAssertEqual(p.faceProtectionSpecs().depthsMM, [7], "★ no face prism ⇒ the dragged depth")
        XCTAssertNil(TopOptKit.jobSchemaError(try stageDocument(p)))
        XCTAssertNil(TopOptKit.jobSchemaError(try stageDocument(p, preRuling: true)))
    }

    /// A CURVED face emits one prism per facet, all with the face's id and the same depth: the one
    /// protection entry follows them all.
    func testEveryFacetOfACurvedFaceSharesTheOneProtection() throws {
        let p = ProjectModel(id: UUID(), name: "Arc", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        p.viewerMesh = Self.arcMesh()
        let gid = p.selection.addGroup()
        p.selection.pickFaces([7])
        p.force.sync(groups: p.selection.groups)
        p.force.setProtected(gid, true)
        p.lattice.enabled = true
        p.lattice.groupRoles[gid] = .include
        p.lattice.paintDepthMM = 5
        p.writeLatticeExpandMM(.face(group: gid, face: 7), mm: 2)
        let facets = p.latticeJobRegions().regions.filter { $0.kind == .face }
        XCTAssertGreaterThan(facets.count, 1, "control: the arc is emitted as facets")
        XCTAssertTrue(facets.allSatisfy { $0.faceID == 7 && abs($0.depthMM - 7) < 1e-9 })
        XCTAssertEqual(p.faceProtectionSpecs().depthsMM, [7], "★ one protection at the facets' depth")
        XCTAssertNotNil(TopOptKit.jobSchemaError(try stageDocument(p, preRuling: true)), "control: refused before")
        XCTAssertNil(TopOptKit.jobSchemaError(try stageDocument(p)), "★ accepted after")
    }

    /// The one definition, at the job's call site: one emission feeds the protections and the regions.
    func testTheStageRequestReadsOneEmissionForBoth() throws {
        var root = URL(fileURLWithPath: #filePath); for _ in 0..<3 { root.deleteLastPathComponent() }
        let app = try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/AppModel.swift"), encoding: .utf8)
        XCTAssertTrue(app.contains("let emission = project.latticeJobRegions()"))
        XCTAssertTrue(app.contains("let protections = project.faceProtectionSpecs(emission: emission)"))
        XCTAssertTrue(app.contains("let latticeSpec = project.latticeRunSpec(emission: emission)"))
        let pm = try String(contentsOf: root.appendingPathComponent("Sources/TopOptFlows/ProjectModel.swift"), encoding: .utf8)
        XCTAssertTrue(pm.contains("let d = emission.slabDepthMM(runFaceID: run) ?? (latticed"),
                      "the protection reads the emission's own depth")
    }

    // MARK: fixtures (copied from LatticeFaceFacetsTests / LatticePageRound2Tests)

    static func arcMesh(steps: Int = 18) -> ViewerMesh {
        var v: [Float] = [], idx: [Int32] = [], fid: [Int32] = []
        let r: Float = 50
        for i in 0...steps {
            let a = Float(i) / Float(steps) * .pi / 2
            v += [r * cos(a), r * sin(a), 0, r * cos(a), r * sin(a), 20]
        }
        for i in 0..<steps {
            let a = Int32(2 * i), b = a + 1, c = a + 2, d = a + 3
            idx += [a, c, b, b, c, d]
            fid += [7, 7]
        }
        return ViewerMesh(vertices: v, indices: idx, faceIDs: fid)
    }

    static func borePlusPlaneMesh() -> ViewerMesh {
        let n = 8
        var verts: [Float] = []
        let r: Float = 2.5
        for k in 0..<n { let a = Float(k) * (2 * .pi / Float(n)); verts += [r * cos(a), r * sin(a), 0] }
        for k in 0..<n { let a = Float(k) * (2 * .pi / Float(n)); verts += [r * cos(a), r * sin(a), 10] }
        verts += [0, 0, 10]
        let topCentre: Int32 = 16
        var indices: [Int32] = []
        var faceIDs: [Int32] = []
        func B(_ k: Int) -> Int32 { Int32(k % n) }
        func T(_ k: Int) -> Int32 { Int32(n + (k % n)) }
        for k in 0..<n {
            indices += [B(k), T(k + 1), B(k + 1), B(k), T(k), T(k + 1)]
            faceIDs += [1, 1]
        }
        for k in 0..<n { indices += [topCentre, T(k), T(k + 1)]; faceIDs += [3] }
        let cyl = StepFaceGeometry(kind: .cylinder, cylinderRadiusMM: 2.5,
                                   axisPoint: SIMD3(0, 0, 0), axisDir: SIMD3(0, 0, 1))
        let plane = StepFaceGeometry(kind: .plane, planeNormal: SIMD3(0, 0, 1), planeOrigin: SIMD3(0, 0, 10))
        let geo: [StepFaceGeometry] = [StepFaceGeometry(kind: .other), cyl, StepFaceGeometry(kind: .other), plane]
        return ViewerMesh(vertices: verts, indices: indices, faceIDs: faceIDs, faceGeometry: geo)
    }
}
