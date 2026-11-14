// ★ his iPad notes 11-09, items 2.3 and 2.4, judged on HIS 2040 stand as saved on his iPad (12:29 AM), restored from its
// own project.json + model.step in $HIS_PROJECT_DIR (read-only copy, never in the repo; skipped where absent), plus a pure
// test of the curved-face rule that always runs.
//   2.3 "Lattice is visible on the green 'Protect faces' inside the hole of the 2040 extrusion area."
//   2.4 "Lattice is being made on the rounded edges" (his Group 3: holes and rounds, Protect skin → No lattice, 4 mm).
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class LatticeCurvedFaceDepthTests: XCTestCase {
    override func tearDown() { LatticeRegionEmission.controlBoreAtItsRadius = false; super.tearDown() }

    private func bolt(concave: Bool?, radius: Double = 5) -> LatticeRegionSpec? {
        LatticeRegionEmission.spec(for: .cylinder(axisPoint: .zero, axisDir: SIMD3(0, 0, 1), radiusMM: radius,
                                                  spanLoMM: -10, spanHiMM: 10, concave: concave),
                                   role: .exclude, depthMM: 4, faceID: 7)
    }

    /// A hole (the part outside its surface) reaches its depth OUT from its radius; a boss keeps its radius.
    func testAHoleReachesItsDepthIntoThePart() throws {
        XCTAssertEqual(try XCTUnwrap(bolt(concave: true)).radiusMM, 9, accuracy: 1e-9, "★ 5 mm hole, 4 mm deep → 9 mm")
        XCTAssertEqual(try XCTUnwrap(bolt(concave: false)).radiusMM, 5, accuracy: 1e-9, "a boss wider than 4 mm: its own radius")
        XCTAssertEqual(try XCTUnwrap(bolt(concave: false, radius: 1.5)).radiusMM, 4, accuracy: 1e-9,
                       "★ an outside round smaller than 4 mm reaches 4 mm through its axis")
        XCTAssertEqual(try XCTUnwrap(bolt(concave: nil)).radiusMM, 5, accuracy: 1e-9, "unknown (Flexible): as before")
        LatticeRegionEmission.controlBoreAtItsRadius = true
        XCTAssertEqual(try XCTUnwrap(bolt(concave: true)).radiusMM, 5, accuracy: 1e-9, "control: the rule before")
        XCTAssertEqual(try XCTUnwrap(bolt(concave: false, radius: 1.5)).radiusMM, 1.5, accuracy: 1e-9, "control: the rule before")
    }
}

final class HisStand1109LatticeTests: XCTestCase {
    override func tearDown() {
        LatticeRegionEmission.controlBoreAtItsRadius = false
        ProjectModel.controlProtectNotKept = false
        super.tearDown()
    }

    struct Stand { let pm: ProjectModel; let mesh: ViewerMesh }

    @MainActor
    static func restore() throws -> Stand {
        guard let dirPath = ProcessInfo.processInfo.environment["HIS_PROJECT_DIR"] else {
            throw XCTSkip("HIS_PROJECT_DIR: his saved 2040 stand (read-only copy) is not given")
        }
        let dir = URL(fileURLWithPath: dirPath)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: dir.appendingPathComponent("project.json")))
        let stepPath = dir.appendingPathComponent("model.step").path
        let im = try TopOptKit.importMesh(path: stepPath)
        let file = ImportedFile(name: "model.step", path: stepPath, triangleCount: im.triangleCount, faceCount: im.faceCount,
                                watertight: im.watertight, pseudoFaces: im.pseudoFaces)
        let pm = ProjectModel(restoring: snap, importedFile: file, importedMesh: im)
        let mesh = ViewerMesh(vertices: im.vertices, indices: im.indices, faceIDs: im.faceIDs, faceGeometry: im.faceGeometry)
        if pm.viewerMesh == nil { pm.viewerMesh = mesh }
        return Stand(pm: pm, mesh: mesh)
    }

    /// The stage's preview occupancy for the project as it stands (the regions the job carries).
    @MainActor
    static func occupancy(_ s: Stand) -> LatticeVoxelGrid {
        let pm = s.pm, lat = pm.lattice
        let emission = pm.latticeJobRegions()
        let scene = LatticeSDFScene(mesh: s.mesh, field: nil, latticeID: lat.topologyID,
                                    statedDensityGoverns: true, allowQuilt: lat.allowQuilt, stageMode: lat.stageMode ?? .structural,
                                    gradeAlong: lat.gradeAlong, algorithm: lat.algorithm, allowableMPa: 50,
                                    boundaryFinishWritten: lat.singleCellMembers, organic: nil,
                                    regions: pm.latticePreviewRegions(emission.regions), rhoMin: 0.05, rhoMax: 0.9, gamma: 1,
                                    whenEmpty: pm.latticeStartsWhole ? .latticeEverything : .latticeNothing,
                                    skinMM: lat.boundary.faceSkinMM(wallRingMM: pm.printParams.wallRingMM),
                                    skippedFaces: emission.skippedFaces, skippedRegionNames: emission.skippedRegionNames,
                                    bandOverrides: lat.bandTreatments, octetBand: lat.algorithm != "organic",
                                    bandGradeMM: lat.gradingMode.fitsShape ? lat.shapeFitBandMM : 0,
                                    beadMM: pm.printParams.strutLineWidthMM)
        return scene.occupancy
    }

    /// Latticed voxels whose centre lies within `mm` of the given faces' surface (stamped, then a 6-neighbour walk).
    static func latticedWithin(_ mm: Double, of faces: Set<FaceID>, _ occ: LatticeVoxelGrid, _ mesh: ViewerMesh) -> Int {
        let n = occ.values.count
        let h = Double(Swift.min(occ.spacing.x, Swift.min(occ.spacing.y, occ.spacing.z)))
        let steps = Int32((mm / h).rounded(.down))
        var d = [Int32](repeating: .max, count: n)
        var queue: [Int] = []
        let step = Float(0.5 * h)
        for t in 0..<Swift.min(mesh.triangleCount, mesh.faceIDs.count) where faces.contains(mesh.faceIDs[t]) {
            func v(_ i: Int) -> SIMD3<Float> {
                let k = Int(mesh.indices[3 * t + i]); return SIMD3(mesh.positions[3 * k], mesh.positions[3 * k + 1], mesh.positions[3 * k + 2])
            }
            let p0 = v(0), e1 = v(1) - p0, e2 = v(2) - p0
            let n1 = Swift.max(1, Int((simd_length(e1) / step).rounded(.up))), n2 = Swift.max(1, Int((simd_length(e2) / step).rounded(.up)))
            for a in 0...n1 { for c in 0...n2 {
                let fa = Float(a) / Float(n1), fb = Float(c) / Float(n2)
                guard fa + fb <= 1.0001 else { break }
                let g = (p0 + e1 * fa + e2 * fb - occ.origin) / occ.spacing
                let x = Int(g.x.rounded()), y = Int(g.y.rounded()), z = Int(g.z.rounded())
                guard x >= 0, y >= 0, z >= 0, x < occ.nx, y < occ.ny, z < occ.nz else { continue }
                let i = (z * occ.ny + y) * occ.nx + x
                if d[i] != 0 { d[i] = 0; queue.append(i) }
            } }
        }
        var head = 0
        while head < queue.count {
            let i = queue[head]; head += 1
            guard d[i] < steps else { continue }
            let x = i % occ.nx, y = (i / occ.nx) % occ.ny, z = i / (occ.nx * occ.ny)
            for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                let X = x + dx, Y = y + dy, Z = z + dz
                guard X >= 0, Y >= 0, Z >= 0, X < occ.nx, Y < occ.ny, Z < occ.nz else { continue }
                let j = (Z * occ.ny + Y) * occ.nx + X
                if d[j] == .max { d[j] = d[i] + 1; queue.append(j) }
            }
        }
        var count = 0
        for i in 0..<n where occ.values[i] != 0 && d[i] <= steps { count += 1 }
        return count
    }

    /// ★ HIS RULE, MEASURED AS HE SEES IT: the material UNDER each face, to `depthMM`, is solid. Points on the face (each
    /// triangle's centroid and 3 inset points), at least `inset` mm from the face's own boundary (so an inside corner, whose
    /// neighbour's material lies within the depth sideways, is not counted), stepped INTO the part along the triangle's
    /// inward normal from half a voxel to `depthMM` less a voxel. Returns (points probed, points that land on a latticed voxel).
    static func latticedUnder(_ faces: Set<FaceID>, depthMM: Double, _ occ: LatticeVoxelGrid, _ mesh: ViewerMesh) -> (probed: Int, latticed: Int) {
        let h = Double(Swift.min(occ.spacing.x, Swift.min(occ.spacing.y, occ.spacing.z)))
        let inset = 1.5 * h
        func pos(_ k: Int) -> SIMD3<Double> {
            SIMD3(Double(mesh.positions[3 * k]), Double(mesh.positions[3 * k + 1]), Double(mesh.positions[3 * k + 2]))
        }
        func key(_ q: SIMD3<Double>) -> SIMD3<Int64> { SIMD3(Int64((q.x * 1e4).rounded()), Int64((q.y * 1e4).rounded()), Int64((q.z * 1e4).rounded())) }
        struct Edge: Hashable { let a: SIMD3<Int64>, b: SIMD3<Int64> }
        let tris = Swift.min(mesh.triangleCount, mesh.faceIDs.count)
        // each face's boundary: edges whose other triangle belongs to another face (or none)
        var owner: [Edge: [FaceID]] = [:]   // one entry per triangle using the edge
        for t in 0..<tris {
            let v = (0..<3).map { pos(Int(mesh.indices[3 * t + $0])) }
            for e in 0..<3 {
                let a = key(v[e]), b = key(v[(e + 1) % 3])
                let k = a.x < b.x || (a.x == b.x && (a.y < b.y || (a.y == b.y && a.z < b.z))) ? Edge(a: a, b: b) : Edge(a: b, b: a)
                owner[k, default: []].append(mesh.faceIDs[t])
            }
        }
        // a face's boundary: an edge of its triangles that another face's triangle shares, or that no other triangle does
        var boundary: [FaceID: [(SIMD3<Double>, SIMD3<Double>)]] = [:]
        for (e, fs) in owner {
            for f in Set(fs) where faces.contains(f) {
                guard fs.count == 1 || fs.contains(where: { $0 != f }) else { continue }
                let a = SIMD3<Double>(Double(e.a.x), Double(e.a.y), Double(e.a.z)) / 1e4
                let b = SIMD3<Double>(Double(e.b.x), Double(e.b.y), Double(e.b.z)) / 1e4
                boundary[f, default: []].append((a, b))
            }
        }
        func distToSegment(_ p: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>) -> Double {
            let ab = b - a, l2 = simd_dot(ab, ab)
            let t = l2 > 0 ? Swift.max(0, Swift.min(1, simd_dot(p - a, ab) / l2)) : 0
            return simd_length(p - (a + ab * t))
        }
        func latticed(_ q: SIMD3<Double>) -> Bool {
            let g = (SIMD3<Float>(q) - occ.origin) / occ.spacing
            let x = Int(g.x.rounded()), y = Int(g.y.rounded()), z = Int(g.z.rounded())
            guard x >= 0, y >= 0, z >= 0, x < occ.nx, y < occ.ny, z < occ.nz else { return false }
            return occ.values[(z * occ.ny + y) * occ.nx + x] > 0.5
        }
        var probed = 0, hit = 0
        for t in 0..<tris where faces.contains(mesh.faceIDs[t]) {
            let f = mesh.faceIDs[t]
            let v = (0..<3).map { pos(Int(mesh.indices[3 * t + $0])) }
            let n = simd_cross(v[1] - v[0], v[2] - v[0])
            guard simd_length(n) > 1e-12 else { continue }
            let inward = -simd_normalize(n)
            let c = (v[0] + v[1] + v[2]) / 3
            for p in [c, (c * 2 + v[0]) / 3, (c * 2 + v[1]) / 3, (c * 2 + v[2]) / 3] {
                let edges = boundary[f] ?? []
                guard edges.allSatisfy({ distToSegment(p, $0.0, $0.1) >= inset }) else { continue }
                probed += 1
                var t = 0.5 * h
                var any = false
                while t <= depthMM - h { if latticed(p + inward * t) { any = true; break }; t += 0.5 * h }
                if any { hit += 1 }
            }
        }
        return (probed, hit)
    }

    /// The concave cylinders among `faces` (holes, inside rounds).
    static func concave(_ faces: [FaceID], _ mesh: ViewerMesh) -> [FaceID] {
        faces.filter { f in
            guard let g = mesh.faceGeometry(f), g.isCylinder, simd_length(g.axisDir) > 1e-9 else { return false }
            return FaceTopology.boreAxisMetrics(f, in: mesh, axisPoint: SIMD3<Float>(g.axisPoint),
                                                axisDir: SIMD3<Float>(simd_normalize(g.axisDir))).concave
        }
    }

    /// ★ 2.4: his Group 3 (holes and rounds, Protect skin → No lattice, 4 mm) keeps its 4 mm: every curved face's region
    /// reaches 4 mm (a hole's past its radius, a small outside round's through its axis), and the preview lattices nothing
    /// within 4 mm (less a voxel) of them.
    @MainActor
    func testHisHolesAndRoundsStaySolidToTheirDepth() throws {
        let s = try Self.restore()
        let pm = s.pm
        let g3 = try XCTUnwrap(pm.latticeGroups.first { $0.name == "Group 3" }, "his Group 3")
        let depth = 4.0
        let cylinders = g3.faces.filter { s.mesh.faceGeometry($0)?.isCylinder == true }
        let holes = Set(Self.concave(cylinders, s.mesh)), rounds = Set(cylinders).subtracting(holes)
        XCTAssertFalse(cylinders.isEmpty, "premise: Group 3 holds holes or rounds")
        print("HIS1109 Group 3 holes/inside rounds: \(holes.sorted().map { "\($0)=\(pm.faceName($0))" })")
        print("HIS1109 Group 3 outside rounds/bosses: \(rounds.sorted().map { "\($0)=\(pm.faceName($0)) R \(s.mesh.faceGeometry($0)!.cylinderRadiusMM)" })")
        let regions = pm.latticeJobRegions().regions
        for f in cylinders {
            let run = Int(pm.runFaceID(f))
            let r = try XCTUnwrap(regions.first { $0.kind == .bolt && $0.faceID == run && $0.role == .exclude }, "\(pm.faceName(f)): its region")
            let R = try XCTUnwrap(s.mesh.faceGeometry(f)).cylinderRadiusMM
            XCTAssertEqual(r.radiusMM, holes.contains(f) ? R + depth : Swift.max(R, depth), accuracy: 1e-6, "★ \(pm.faceName(f)): reaches its 4 mm")
        }
        func count(_ faces: Set<FaceID>, _ occ: LatticeVoxelGrid) -> Int {
            guard !faces.isEmpty else { return 0 }
            let r = Self.latticedUnder(faces, depthMM: depth, occ, s.mesh)
            print("HIS1109 2.4 probe: \(r.probed) points under \(faces.count) faces, \(r.latticed) on lattice")
            return r.latticed
        }
        let occNow = Self.occupancy(s)
        let nowHoles = count(holes, occNow), nowRounds = count(rounds, occNow)
        LatticeRegionEmission.controlBoreAtItsRadius = true
        let occBefore = Self.occupancy(s)
        let beforeHoles = count(holes, occBefore), beforeRounds = count(rounds, occBefore)
        LatticeRegionEmission.controlBoreAtItsRadius = false
        print("HIS1109 2.4 points under his holes/rounds (to \(depth) mm) on lattice: holes now \(nowHoles) before \(beforeHoles) · rounds now \(nowRounds) before \(beforeRounds)")
        XCTAssertGreaterThan(beforeHoles + beforeRounds, 0, "control: the rule before lattices there (the measure can see it)")
        XCTAssertEqual(nowHoles, 0, "★ solid under every hole and inside round, to his 4 mm")
        XCTAssertEqual(nowRounds, 0, "★ solid under every outside round, to his 4 mm")
    }

    /// ★ 2.3: what Topology protects stays solid under the lattice to the Protect skin depth (his Settings, 5 mm): an
    /// exclude per protected face no lattice group names, at that depth, and none latticed within it (less a voxel).
    @MainActor
    func testHisProtectedFacesStaySolidToTheProtectDepth() throws {
        let s = try Self.restore()
        let pm = s.pm
        let depth = pm.force.faceProtectDepthMM
        var protected = Set<FaceID>()
        for g in pm.selection.groups where pm.force.isProtected(g.id) { protected.formUnion(g.faces) }
        let named = Set(pm.latticeGroups.flatMap(\.faces))
        let kept = protected.subtracting(named)
        XCTAssertFalse(kept.isEmpty, "premise: he protects faces no lattice group names (the slot)")
        let regions = pm.latticeJobRegions().regions
        let keeps = regions.filter { $0.role == .exclude && $0.selectableKey?.contains(ProjectModel.protectKeepGroupID.uuidString) == true }
        XCTAssertFalse(keeps.isEmpty, "★ the protected faces reach the job as No lattice")
        for r in keeps where r.kind == .face { XCTAssertEqual(r.depthMM, depth, accuracy: 1e-6, "★ at the Protect skin depth") }
        // core's depth tie: every face region naming a protected face sits at that face's protection depth
        let prot = pm.faceProtectionSpecs()
        for (id, d) in zip(prot.faceIDs, prot.depthsMM) {
            for r in regions where r.kind == .face && r.faceID == id && !r.sectorPiece {
                XCTAssertEqual(r.depthMM, d, accuracy: 1e-6, "★ core's depth tie on face \(id)")
            }
        }
        let nowR = Self.latticedUnder(kept, depthMM: depth, Self.occupancy(s), s.mesh)
        let near = nowR.latticed
        ProjectModel.controlProtectNotKept = true
        let before = Self.latticedUnder(kept, depthMM: depth, Self.occupancy(s), s.mesh).latticed
        let jobBefore = pm.latticeJobRegions().regions.count
        ProjectModel.controlProtectNotKept = false
        print("HIS1109 2.3 points under his protected faces (to \(depth) mm) on lattice: now \(near) of \(nowR.probed) · before \(before) · regions \(regions.count) (before \(jobBefore))")
        XCTAssertGreaterThan(before, 0, "control: the rule before lattices there")
        XCTAssertEqual(near, 0, "★ solid under every protected face, to his Protect skin")
    }

    /// ★ 2.3: a protected face a lattice group names keeps that group's say (Lattice on a protected face is the barrier
    /// model): no Protect keep on it, and its own prism stays.
    @MainActor
    func testAProtectedFaceALatticeGroupNamesKeepsItsSay() throws {
        let s = try Self.restore()
        let pm = s.pm
        let g1 = try XCTUnwrap(pm.latticeGroups.first { $0.name == "Group 1" }, "his Group 1 (Lattice, 7 mm)")
        let face = try XCTUnwrap(g1.faces.first)
        let c = try XCTUnwrap(pm.selection.groups.first { pm.force.isProtected($0.id) }, "his Protect group")
        pm.selection.addFaces([face], to: c.id)
        let run = Int(pm.runFaceID(face))
        let regions = pm.latticeJobRegions().regions
        let on = regions.filter { $0.faceID == run }
        XCTAssertTrue(on.contains { $0.role == LatticeGroupRole.include }, "★ his Lattice prism stays")
        XCTAssertFalse(on.contains { $0.selectableKey?.contains(ProjectModel.protectKeepGroupID.uuidString) == true },
                       "★ no Protect keep over a face his lattice group names")
    }
}
