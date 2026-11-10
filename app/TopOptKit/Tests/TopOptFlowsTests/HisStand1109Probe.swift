import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

/// ★ PROBE (his iPad notes 11-09, items 2.3 and 2.4): HIS 2040 stand as saved on his iPad (12:29 AM), restored from its
/// own project.json + model.step in $HIS_PROJECT_DIR (never copied into the repo). Prints his lattice groups, the
/// regions the job emits, and WHERE the stage's preview lattices: next to his Protect faces (the slot), and next to his
/// No-lattice faces (the rounded edges), attributed to the include region that put it there.
final class HisStand1109Probe: XCTestCase {
    @MainActor
    func testWhereThePreviewLattices() throws {
        guard let dirPath = ProcessInfo.processInfo.environment["HIS_PROJECT_DIR"] else { throw XCTSkip("HIS_PROJECT_DIR") }
        let dir = URL(fileURLWithPath: dirPath)
        let snap = try JSONDecoder().decode(ProjectSnapshot.self, from: Data(contentsOf: dir.appendingPathComponent("project.json")))
        let stepPath = dir.appendingPathComponent("model.step").path
        let im = try TopOptKit.importMesh(path: stepPath)
        let file = ImportedFile(name: "model.step", path: stepPath, triangleCount: im.triangleCount, faceCount: im.faceCount,
                                watertight: im.watertight, pseudoFaces: im.pseudoFaces)
        let pm = ProjectModel(restoring: snap, importedFile: file, importedMesh: im)
        let mesh = ViewerMesh(vertices: im.vertices, indices: im.indices, faceIDs: im.faceIDs, faceGeometry: im.faceGeometry)
        if pm.viewerMesh == nil { pm.viewerMesh = mesh }
        let b = mesh.bounds
        print("HIS1109 bounds \(b.min) … \(b.max) · startsWhole \(pm.latticeStartsWhole) · boundary \(pm.lattice.boundary) · algorithm '\(pm.lattice.algorithm)' · mode \(String(describing: pm.lattice.stageMode))")
        for g in pm.latticeGroups {
            let names = g.faces.prefix(40).map { "\($0)=\(pm.faceName($0))" }.joined(separator: " | ")
            print("HIS1109 lattice group \(g.name) zone=\(pm.lattice.zoneGroups.contains(g.id)) faces \(g.faces.count) regions \(g.regionIDs): \(names)")
        }
        var protectedFaces = Set<FaceID>()
        for g in pm.selection.groups where pm.force.isProtected(g.id) {
            for f in g.faces { protectedFaces.insert(f) }
            print("HIS1109 PROTECT group \(g.name): \(g.faces.count) faces")
        }
        let emission = pm.latticeJobRegions()
        let regions = pm.latticePreviewRegions(emission.regions)
        for (i, r) in emission.regions.enumerated() {
            print("HIS1109 region \(i) kind \(r.kind) role \(r.role) face \(r.faceID.map(String.init) ?? "-") depth \(String(format: "%.2f", r.depthMM)) inPlane \(String(format: "%.2f", r.inPlaneOffsetMM)) normal \(r.normal) halfU \(String(format: "%.1f", r.halfUMM)) halfW \(String(format: "%.1f", r.halfWMM)) loops \(r.outlineLoops.map(\.count)) key \(r.selectableKey ?? "-")")
        }
        print("HIS1109 skipped faces \(emission.skippedFaces) names \(emission.skippedRegionNames)")

        let lat = pm.lattice
        let span = (lo: 0.05, hi: 0.9)
        let skinMM = lat.boundary.faceSkinMM(wallRingMM: pm.printParams.wallRingMM)
        let scene = LatticeSDFScene(mesh: mesh, field: nil, latticeID: lat.topologyID,
                                    statedDensityGoverns: true, allowQuilt: lat.allowQuilt, stageMode: lat.stageMode ?? .structural,
                                    gradeAlong: lat.gradeAlong, algorithm: lat.algorithm, allowableMPa: 50,
                                    boundaryFinishWritten: lat.singleCellMembers, organic: nil,
                                    regions: regions, rhoMin: span.lo, rhoMax: span.hi, gamma: 1,
                                    whenEmpty: pm.latticeStartsWhole ? .latticeEverything : .latticeNothing,
                                    skinMM: skinMM, skippedFaces: emission.skippedFaces,
                                    skippedRegionNames: emission.skippedRegionNames,
                                    bandOverrides: lat.bandTreatments, octetBand: lat.algorithm != "organic",
                                    bandGradeMM: lat.gradingMode.fitsShape ? lat.shapeFitBandMM : 0,
                                    beadMM: pm.printParams.strutLineWidthMM)
        let occ = scene.occupancy
        let n = occ.values.count
        let occupied = occ.values.filter { $0 != 0 }.count
        print("HIS1109 occupancy \(occ.nx)×\(occ.ny)×\(occ.nz) spacing \(occ.spacing) · occupied \(occupied) of \(n) · interior \(scene.interiorVoxelCount) · skin \(skinMM)")

        // voxel distance (6-neighbour BFS, in voxels) from a face set's surface
        func distanceFrom(_ faces: Set<FaceID>) -> [Int32] {
            var d = [Int32](repeating: .max, count: n)
            var queue: [Int] = []
            let step = 0.5 * Swift.min(occ.spacing.x, Swift.min(occ.spacing.y, occ.spacing.z))
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
                guard d[i] < 12 else { continue }
                let x = i % occ.nx, y = (i / occ.nx) % occ.ny, z = i / (occ.nx * occ.ny)
                for (dx, dy, dz) in [(1, 0, 0), (-1, 0, 0), (0, 1, 0), (0, -1, 0), (0, 0, 1), (0, 0, -1)] {
                    let X = x + dx, Y = y + dy, Z = z + dz
                    guard X >= 0, Y >= 0, Z >= 0, X < occ.nx, Y < occ.ny, Z < occ.nz else { continue }
                    let j = (Z * occ.ny + Y) * occ.nx + X
                    if d[j] == .max { d[j] = d[i] + 1; queue.append(j) }
                }
            }
            return d
        }
        func centre(_ i: Int) -> SIMD3<Double> {
            let x = i % occ.nx, y = (i / occ.nx) % occ.ny, z = i / (occ.nx * occ.ny)
            return SIMD3(Double(occ.origin.x) + Double(x) * Double(occ.spacing.x),
                         Double(occ.origin.y) + Double(y) * Double(occ.spacing.y),
                         Double(occ.origin.z) + Double(z) * Double(occ.spacing.z))
        }
        let includes = regions.enumerated().filter { $0.element.role == .include }
        func report(_ label: String, _ faces: Set<FaceID>) {
            let d = distanceFrom(faces)
            var byDist = [Int](repeating: 0, count: 8)
            var byRegion: [String: Int] = [:]
            for i in 0..<n where occ.values[i] != 0 && d[i] < 8 {
                byDist[Int(d[i])] += 1
                if d[i] <= 2 {
                    let p = centre(i)
                    let who = includes.filter { LatticeRegionMask.contains(p, region: $0.element) }.map { "r\($0.offset)(\($0.element.faceID.map(String.init) ?? "\($0.element.kind)"))" }
                    byRegion[who.isEmpty ? "no include" : who.joined(separator: "+"), default: 0] += 1
                }
            }
            print("HIS1109 \(label): latticed voxels by distance (voxels) 0…7 \(byDist) · within 2 by include \(byRegion)")
        }
        report("next to PROTECT faces", protectedFaces)
        let g3 = pm.latticeGroups.first { $0.name == "Group 3" }
        let rounded = Set((g3?.faces ?? []).filter { pm.faceName($0).hasPrefix("Rounded") })
        print("HIS1109 Group 3 rounded faces \(rounded.sorted())")
        report("next to Group 3's ROUNDED faces", rounded)
        report("next to ALL Group 3 faces", Set(g3?.faces ?? []))
    }
}
