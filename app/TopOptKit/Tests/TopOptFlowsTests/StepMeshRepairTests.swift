// StepMeshRepairTests — STEP parts core refuses as "not watertight" import closed, with every CAD face id
// kept, and every already-watertight STEP comes back byte-identical (round 8, 2026-10-23; the repair is
// StepMeshRepair.swift).
//
// Parts: SyntheticStepParts.swift writes them at run time (his order of 2026-10-24 removed his seven rig
// STEPs from the tree). `filletedBlock` reproduces the pole slivers his Carriage Arms, Pressing Plate Mount
// and Top Motor Mount had (closed by T1); `lippedPlateAndCorner` reproduces his 2040 Extrusion Stand, a face
// BRepMesh breaks at 0.1 mm plus a pole sliver (closed by T2 at 0.05 mm, then T1); `slotPlate` and
// `roundedBracket` stand for his three parts that import without repair.
//
// RED CONTROL (2026-10-24): with TOPOPT_STEP_REPAIR_RED_CONTROL=1 in the environment, every call these tests
// and FlexibleStepRepairHookTests make into the repair goes to the UNREPAIRED path instead (core's stock
// import; the mesh handed back unchanged). The tests that prove the repair must then fail.
import XCTest
import simd
import TopOptKit

final class StepMeshRepairTests: XCTestCase {

    typealias Part = SyntheticStepParts.Part

    /// Refused today.
    static let refused = SyntheticStepParts.refused
    /// Import today without repair.
    static let accepted = SyntheticStepParts.accepted

    static func path(_ part: Part) -> String { SyntheticStepParts.path(part) }
    /// Repo-relative file: .../app/TopOptKit/Tests/TopOptFlowsTests/<this> → up 5.
    static func repoFile(_ rel: String) -> String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent(rel).path
    }
    static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    /// Every other STEP the suites import, for the byte-identical check.
    static var otherWatertightSteps: [String] {
        [repoFile("core/tests/fixtures/demo/l-bracket.step"),
         repoFile("core/tests/fixtures/step/cube.step"),
         repoFile("core/tests/fixtures/step/cylinder.step"),
         here.appendingPathComponent("Fixtures/M2_verticalStand.step").path]
    }

    /// core's stock import, straight through the bridge, so these tests read TODAY's mesh
    /// before and after the importMesh hook lands. Face geometry is deflection-independent
    /// and taken from TopOptKit.importMesh (which the hook never changes).
    static func stock(_ path: String) throws -> ImportedMesh {
        let geometry = try TopOptKit.importMesh(path: path).faceGeometry
        return try StepMeshRepair.stockImport(path: path, linearDeflectionMM: 0,
                                              faceGeometry: geometry)
    }

    // MARK: - the repair under test (or, under the red control, the unrepaired path)

    static let redControl = ProcessInfo.processInfo.environment["TOPOPT_STEP_REPAIR_RED_CONTROL"] == "1"

    static func repairedWithReport(_ m: ImportedMesh, path: String) -> (mesh: ImportedMesh, report: StepMeshRepairReport) {
        // Red control: the gate held shut (a path that is not a STEP), so the mesh comes back untouched.
        StepMeshRepair.repairedWithReport(m, path: redControl ? path + ".red-control-not-a-step" : path)
    }
    static func repaired(_ m: ImportedMesh, path: String) -> ImportedMesh {
        redControl ? m : StepMeshRepair.repaired(m, path: path)
    }
    /// The hooked TopOptKit.importMesh (H47).
    static func hookedImport(_ path: String) throws -> ImportedMesh {
        redControl ? try unrepaired(path) : try TopOptKit.importMesh(path: path)
    }
    /// StepMeshRepair.importMesh: today's import, the gate, the repair.
    static func pipelineImport(_ path: String) throws -> ImportedMesh {
        redControl ? try unrepaired(path) : try StepMeshRepair.importMesh(path: path)
    }
    /// core's stock import with no call into the hooked importMesh at all (so nothing records the file
    /// as repaired); face geometry is left empty. The red control's stand-in for every repaired import.
    static func unrepaired(_ path: String) throws -> ImportedMesh {
        try StepMeshRepair.stockImport(path: path, linearDeflectionMM: 0, faceGeometry: [])
    }

    // MARK: - T1 on a hand-built mesh

    /// A unit tetrahedron, outward, faces 0…3, with a pole sliver (1, 1, 3) of face 7 in
    /// the middle of the list: T1 drops exactly that triangle and keeps the others'
    /// order and face ids; volume is unchanged (1/6).
    func testT1DropsOnlyTheRepeatedCornerTriangleAndKeepsFaceIDs() {
        let v: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
        let idx: [Int32] = [0, 2, 1, 0, 1, 3, 1, 1, 3, 1, 2, 3, 0, 3, 2]
        let m = ImportedMesh(vertices: v, indices: idx, faceIDs: [0, 1, 7, 2, 3],
                             vertexCount: 4, triangleCount: 5, faceCount: 8,
                             watertight: StepMeshRepair.isWatertight(indices: idx))
        XCTAssertFalse(m.watertight, "the sliver's self-edge is a boundary edge")
        XCTAssertEqual(StepMeshRepair.poleSliverCount(m), 1)

        let (out, report) = StepMeshRepair.repairedWithReport(m, path: "/x/part.STEP",
                                                              reimport: { _ in
            XCTFail("T1 closes it; T2 must not run"); return m })
        XCTAssertEqual(report.pass, .poleSlivers)
        XCTAssertEqual(report.droppedSlivers, 1)
        XCTAssertEqual(out.indices, [0, 2, 1, 0, 1, 3, 1, 2, 3, 0, 3, 2])
        XCTAssertEqual(out.faceIDs, [0, 1, 2, 3])
        XCTAssertEqual(out.vertices, v)
        XCTAssertEqual(out.triangleCount, 4)
        XCTAssertTrue(out.watertight)
        XCTAssertTrue(StepMeshRepair.isClosedAndOriented(indices: out.indices))
        XCTAssertEqual(StepMeshRepair.signedVolume(out), 1.0 / 6.0, accuracy: 1e-12)
        XCTAssertEqual(StepMeshRepair.signedVolume(m), StepMeshRepair.signedVolume(out))

        // THE GATE: not a STEP ⇒ untouched; already watertight ⇒ untouched.
        XCTAssertFalse(StepMeshRepair.needsRepair(path: "/x/part.stl", mesh: m))
        let again = StepMeshRepair.repairedWithReport(out, path: "/x/part.step")
        XCTAssertEqual(again.report.pass, .notNeeded)
        XCTAssertEqual(again.mesh.indices, out.indices)
    }

    /// Nothing passes ⇒ the original mesh comes back, still not watertight (refused as today).
    func testNothingAcceptedReturnsTheOriginal() {
        let v: [Float] = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
        let open: [Int32] = [0, 2, 1, 0, 1, 3, 1, 2, 3]   // one face missing
        let m = ImportedMesh(vertices: v, indices: open, faceIDs: [0, 1, 2],
                             vertexCount: 4, triangleCount: 3, faceCount: 4, watertight: false)
        var rungs: [Double] = []
        let (out, report) = StepMeshRepair.repairedWithReport(m, path: "/x/p.stp", reimport: {
            rungs.append($0); throw TopOptError(message: "no file") })
        XCTAssertEqual(report.pass, .gaveUp)
        XCTAssertEqual(rungs, [0.05, 0.025], "T2 walks half, then a quarter, of core's 0.1 mm")
        XCTAssertEqual(out.indices, open)
        XCTAssertFalse(out.watertight)
    }

    // MARK: - the refused parts: the diagnosis

    /// Core's stock tessellation of the refused parts: not watertight. Each pole sliver is a welded
    /// (a, a, b): zero area, a self-edge used once, an edge used four times; they sit on the fillet-corner
    /// faces, one each, and are the whole defect on the block (T1 alone closes it). On the lipped plate a
    /// broken face remains: at 0.1 mm its triangles cover MORE than the face (triangles over the air) and
    /// leave edges open, with no error from the import; at 0.05 mm the same face has the face's area.
    func testDiagnosisOfTheStockTessellation() throws {
        for p in Self.refused {
            let path = Self.path(p)
            let m = try Self.stock(path)
            XCTAssertFalse(m.watertight, p.name)
            XCTAssertEqual(m.faceCount, p.faces, p.name)
            XCTAssertEqual(StepMeshRepair.poleSliverCount(m), p.slivers, p.name)
            let t1 = StepMeshRepair.droppingPoleSlivers(m).mesh
            print("STEP-REPAIR-DIAG \(p.name) stockTris=\(m.triangleCount) "
                + "slivers=\(StepMeshRepair.poleSliverCount(m)) t1Watertight=\(t1.watertight)")
            XCTAssertEqual(t1.watertight, p.brokenFace == nil, p.name)

            // The slivers: one per fillet-corner face; (a, a, b) with zero area.
            var sliverFaces: [Int32] = []
            for t in 0..<m.triangleCount {
                let a = m.indices[3 * t], b = m.indices[3 * t + 1], c = m.indices[3 * t + 2]
                guard a == b || b == c || a == c else { continue }
                sliverFaces.append(m.faceIDs[t])
                XCTAssertEqual(Self.area(m, t), 0, "a pole sliver has zero area: \(p.name)")
            }
            XCTAssertEqual(sliverFaces.sorted(), p.sliverFaces, p.name)
            let uses = Self.edgeUses(m)
            let selfEdges = uses.filter { $0.key.a == $0.key.b }
            XCTAssertEqual(selfEdges.count, p.slivers, "one self-edge per sliver: \(p.name)")
            XCTAssertTrue(selfEdges.values.allSatisfy { $0 == 1 }, "each self-edge is used once: \(p.name)")

            if let f = p.brokenFace {
                // The broken face, at core's 0.1 mm: more triangle area than the face, and open edges.
                let stockArea = Self.faceArea(m, f)
                let open = Self.openFaces(m)
                print(String(format: "STEP-REPAIR-DIAG %@ face %d: %.3f mm² of triangles on a %.3f mm² face, open faces %@",
                             p.name, f, stockArea, p.brokenFaceArea, "\(open.sorted())"))
                XCTAssertGreaterThan(stockArea, p.brokenFaceArea + 1, "triangles over the air beside the lip: \(p.name)")
                XCTAssertTrue(open.contains(f), "the broken face is open: \(p.name)")
                XCTAssertFalse(Self.openFaces(t1).isEmpty, "T1 leaves it open: \(p.name)")
                // At half the deflection the same face is whole.
                let finer = try StepMeshRepair.stockImport(path: path, linearDeflectionMM: 0.05,
                                                           faceGeometry: m.faceGeometry)
                XCTAssertEqual(Self.faceArea(finer, f), p.brokenFaceArea, accuracy: 0.001 * p.brokenFaceArea, p.name)
                XCTAssertFalse(Self.openFaces(finer).contains(f), p.name)
            } else {
                // The four-use edges: one per sliver, and nothing else is open.
                XCTAssertEqual(uses.filter { $0.key.a != $0.key.b && $0.value == 4 }.count, p.slivers, p.name)
                XCTAssertTrue(uses.allSatisfy { $0.key.a == $0.key.b || $0.value == 2 || $0.value == 4 }, p.name)
            }
        }
        // The same checks' negative control: the clean parts show neither defect.
        for p in Self.accepted {
            let m = try Self.stock(Self.path(p))
            XCTAssertTrue(m.watertight, p.name)
            XCTAssertEqual(StepMeshRepair.poleSliverCount(m), 0, p.name)
            XCTAssertEqual(Self.openFaces(m), [], p.name)
        }
    }

    // MARK: - the refused parts: the repair

    /// Each comes back closed + consistently oriented, with the B-rep's face count and every face id the
    /// stock import carried. The block closes at T1; the lipped plate at T2 (0.05 mm), whose own T1 then
    /// drops its sliver.
    func testRepairClosesTheRefusedPartsAndKeepsEveryFaceID() throws {
        for p in Self.refused {
            let path = Self.path(p)
            let stock = try Self.stock(path)
            let (m, r) = Self.repairedWithReport(stock, path: path)
            print("STEP-REPAIR \(p.name) pass=\(r.pass.rawValue) stockTris=\(r.stockTriangles) "
                + "repairedTris=\(r.repairedTriangles) dropped=\(r.droppedSlivers) "
                + "deflection=\(r.linearDeflectionMM.map { "\($0)" } ?? "0.1 (stock)") "
                + "faces=\(m.faceCount)")
            XCTAssertTrue(m.watertight, p.name)
            XCTAssertTrue(StepMeshRepair.isClosedAndOriented(indices: m.indices), p.name)
            XCTAssertEqual(m.faceCount, p.faces, p.name)
            XCTAssertEqual(m.faceIDs.count, m.triangleCount, p.name)
            XCTAssertEqual(Set(m.faceIDs), Set(stock.faceIDs), "every CAD face id kept: \(p.name)")
            XCTAssertEqual(Set(m.faceIDs), Set((0..<Int32(p.faces)).map { $0 }), "every face has triangles: \(p.name)")
            XCTAssertEqual(m.faceGeometry, stock.faceGeometry, p.name)
            XCTAssertFalse(m.pseudoFaces, p.name)
            if p.brokenFace != nil {
                XCTAssertEqual(r.pass, .retessellated, p.name)
                XCTAssertEqual(r.linearDeflectionMM, 0.05, p.name)
                XCTAssertEqual(r.droppedSlivers, p.slivers, "T2's own T1 drops the re-meshed slivers: \(p.name)")
            } else {
                XCTAssertEqual(r.pass, .poleSlivers, p.name)
                XCTAssertEqual(r.droppedSlivers, p.slivers, p.name)
                XCTAssertEqual(r.repairedTriangles, r.stockTriangles - p.slivers, p.name)
                // T1 touches nothing else: same vertices, same order of the kept triangles.
                XCTAssertEqual(m.vertices, stock.vertices, p.name)
            }
            // The full pipeline the hook runs gives the same mesh.
            let piped = try Self.pipelineImport(path)
            XCTAssertEqual(piped.indices, m.indices, p.name)
            XCTAssertEqual(piped.faceIDs, m.faceIDs, p.name)
        }
    }

    /// Volume and box against the exact B-rep: the box within 0.1 % per axis, the volume within 0.2 %
    /// (the bar his parts needed: core's 0.1 mm / 0.5 rad tessellation itself sat 0.11-0.17 % off them).
    /// The lipped plate's stock mesh is +1 % off (its broken face's triangles over the air); repaired it is
    /// back within the bar. What T1 adds is pinned separately: it changes the volume by exactly nothing.
    func testRepairedVolumeAndBoundingBoxMatchTheBrep() throws {
        for p in Self.refused {
            let path = Self.path(p)
            let stock = try Self.stock(path)
            let m = Self.repaired(stock, path: path)
            let vol = StepMeshRepair.signedVolume(m)
            let rel = (vol - p.brepVolume) / p.brepVolume
            let (lo, hi) = Self.box(m)
            let ext = p.hi - p.lo
            let dev = simd_max(simd_abs(lo - p.lo), simd_abs(hi - p.hi)) / ext
            print(String(format: "STEP-REPAIR-VOL %@ vol=%.4f brep=%.4f rel=%+.4f%% stockRel=%+.4f%% "
                         + "boxDev=%.5f%%/%.5f%%/%.5f%%", p.name, vol, p.brepVolume, rel * 100,
                         (StepMeshRepair.signedVolume(stock) - p.brepVolume) / p.brepVolume * 100,
                         dev.x * 100, dev.y * 100, dev.z * 100))
            XCTAssertLessThan(abs(rel), 0.002, p.name)
            XCTAssertLessThan(dev.max(), 0.001, p.name)
            if p.brokenFace == nil {
                XCTAssertEqual(vol, StepMeshRepair.signedVolume(stock), p.name)
            }
        }
    }

    // MARK: - everything else: unchanged

    /// The parts that import today, and every other STEP fixture: the gate stays closed
    /// and the mesh is byte-identical to today's import (every face id where it was).
    func testAlreadyWatertightImportsComeBackByteIdentical() throws {
        let paths = Self.accepted.map(Self.path) + Self.otherWatertightSteps
        for path in paths {
            let today = try Self.stock(path)
            XCTAssertTrue(today.watertight, path)
            XCTAssertEqual(Self.differences(today, try TopOptKit.importMesh(path: path)), [], path)
            XCTAssertFalse(StepMeshRepair.needsRepair(path: path, mesh: today), path)
            let (out, r) = StepMeshRepair.repairedWithReport(today, path: path)
            XCTAssertEqual(r.pass, .notNeeded, path)
            XCTAssertEqual(Self.differences(today, out), [], path)
            let piped = try StepMeshRepair.importMesh(path: path)
            XCTAssertEqual(Self.differences(today, piped), [], path)
            // T1 forced on a clean mesh is the identity too (nothing to drop).
            XCTAssertEqual(Self.differences(today, StepMeshRepair.droppingPoleSlivers(today).mesh),
                           [], path)
        }
        for p in Self.accepted {
            let today = try Self.stock(Self.path(p))
            XCTAssertEqual(today.faceCount, p.faces, p.name)
            XCTAssertEqual(Set(today.faceIDs), Set((0..<Int32(p.faces)).map { $0 }), p.name)
            XCTAssertEqual(StepMeshRepair.poleSliverCount(today), 0, p.name)
        }
    }

    /// RED CONTROL: force the repair's T2 on the clean parts and the comparator above must see it.
    /// Only the gate keeps already-watertight imports byte-identical.
    func testRedControlForcedRepairIsCaught() throws {
        for p in Self.accepted {
            let path = Self.path(p)
            let today = try Self.stock(path)
            let forced = StepMeshRepair.droppingPoleSlivers(
                try StepMeshRepair.stockImport(path: path, linearDeflectionMM: 0.05,
                                               faceGeometry: today.faceGeometry)).mesh
            let diff = Self.differences(today, forced)
            print("STEP-REPAIR-RED \(p.name) today=\(today.triangleCount) forced=\(forced.triangleCount) "
                + "differs=\(diff)")
            XCTAssertFalse(diff.isEmpty, "the comparator must catch a forced repair: \(p.name)")
        }
    }

    // MARK: - the hook (H47, ruling 2026-10-23 18:56 (1))

    /// The hooked TopOptKit.importMesh ACCEPTS the refused parts: watertight, closed and
    /// consistently wound, positive volume, the B-rep's face count with every face id the
    /// stock import carried, and exactly the mesh the repair gives on today's import.
    /// (Replaces testPinBeforeTheHookImportMeshStillRefusesTheFour.) The pin of the hook's
    /// text is FlexibleStepRepairHookTests.
    func testHookedImportMeshAcceptsTheRefusedParts() throws {
        for p in Self.refused {
            let path = Self.path(p)
            let stock = try Self.stock(path)
            XCTAssertFalse(stock.watertight, "today's bridge import is still open: \(p.name)")
            let m = try Self.hookedImport(path)
            XCTAssertTrue(m.watertight, p.name)
            XCTAssertTrue(StepMeshRepair.isClosedAndOriented(indices: m.indices), p.name)
            XCTAssertGreaterThan(StepMeshRepair.signedVolume(m), 0, p.name)
            XCTAssertEqual(m.faceCount, p.faces, p.name)
            XCTAssertEqual(Set(m.faceIDs), Set(stock.faceIDs), "every CAD face id kept: \(p.name)")
            let expected = StepMeshRepair.repaired(stock, path: path)
            XCTAssertEqual(Self.differences(expected, m), [], p.name)
        }
    }

    // MARK: - helpers

    static func box(_ m: ImportedMesh) -> (SIMD3<Double>, SIMD3<Double>) {
        var lo = SIMD3<Double>(repeating: .infinity), hi = SIMD3<Double>(repeating: -.infinity)
        for i in m.indices {
            let k = Int(i) * 3
            let p = SIMD3<Double>(Double(m.vertices[k]), Double(m.vertices[k + 1]),
                                  Double(m.vertices[k + 2]))
            lo = simd_min(lo, p); hi = simd_max(hi, p)
        }
        return (lo, hi)
    }

    static func corner(_ m: ImportedMesh, _ i: Int32) -> SIMD3<Double> {
        let k = Int(i) * 3
        return SIMD3(Double(m.vertices[k]), Double(m.vertices[k + 1]), Double(m.vertices[k + 2]))
    }
    /// Triangle t's area (mm²).
    static func area(_ m: ImportedMesh, _ t: Int) -> Double {
        let a = corner(m, m.indices[3 * t]), b = corner(m, m.indices[3 * t + 1]), c = corner(m, m.indices[3 * t + 2])
        return simd_length(simd_cross(b - a, c - a)) / 2
    }
    /// The triangle area of one face (mm²).
    static func faceArea(_ m: ImportedMesh, _ face: Int32) -> Double {
        (0..<m.triangleCount).filter { m.faceIDs[$0] == face }.reduce(0) { $0 + area(m, $1) }
    }
    /// Uses of each undirected edge (a self-edge (a, a) included).
    static func edgeUses(_ m: ImportedMesh) -> [Pair: Int] {
        var uses: [Pair: Int] = [:]
        for t in 0..<m.triangleCount {
            for k in 0..<3 {
                let a = m.indices[3 * t + k], b = m.indices[3 * t + (k + 1) % 3]
                uses[Pair(min(a, b), max(a, b)), default: 0] += 1
            }
        }
        return uses
    }
    struct Pair: Hashable { let a: Int32, b: Int32; init(_ a: Int32, _ b: Int32) { self.a = a; self.b = b } }
    /// The faces owning a triangle on an edge that is not used exactly twice (a self-edge counts).
    static func openFaces(_ m: ImportedMesh) -> Set<Int32> {
        let uses = edgeUses(m)
        var out: Set<Int32> = []
        for t in 0..<m.triangleCount {
            for k in 0..<3 {
                let a = m.indices[3 * t + k], b = m.indices[3 * t + (k + 1) % 3]
                if a == b || uses[Pair(min(a, b), max(a, b))] != 2 { out.insert(m.faceIDs[t]) }
            }
        }
        return out
    }

    /// Every field that differs, comparing floats by bit pattern.
    static func differences(_ a: ImportedMesh, _ b: ImportedMesh) -> [String] {
        var d: [String] = []
        if a.vertices.map(\.bitPattern) != b.vertices.map(\.bitPattern) { d.append("vertices") }
        if a.indices != b.indices { d.append("indices") }
        if a.faceIDs != b.faceIDs { d.append("faceIDs") }
        if a.vertexCount != b.vertexCount { d.append("vertexCount") }
        if a.triangleCount != b.triangleCount { d.append("triangleCount") }
        if a.faceCount != b.faceCount { d.append("faceCount") }
        if a.watertight != b.watertight { d.append("watertight") }
        if a.faceGeometry != b.faceGeometry { d.append("faceGeometry") }
        if a.pseudoFaces != b.pseudoFaces { d.append("pseudoFaces") }
        return d
    }
}
