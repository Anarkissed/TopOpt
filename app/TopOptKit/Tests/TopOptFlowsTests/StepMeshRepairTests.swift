// StepMeshRepairTests — his four refused squish-rig STEPs import closed, with every
// CAD face id kept, and every already-watertight STEP comes back byte-identical
// (round 8, 2026-10-23; the repair is StepMeshRepair.swift).
//
// Fixtures: Fixtures/squish_rig/*.step are his 7 printed rig parts, copied unchanged
// from "TO_STEP-files" (spaces → underscores). B-rep references below are OCCT 7.9.3's
// own numbers for these files: BRepGProp::VolumeProperties (the volume core's step.cpp
// stores as brep_volume) and BRepBndLib::AddOptimal (exact box, no tolerance).
import XCTest
import simd
import TopOptKit

final class StepMeshRepairTests: XCTestCase {

    struct Part {
        let file: String
        let faces: Int
        let brepVolume: Double
        let lo: SIMD3<Double>
        let hi: SIMD3<Double>
    }

    /// The four refused today.
    static let refused: [Part] = [
        Part(file: "Carriage_Arms", faces: 186, brepVolume: 107_627.9596,
             lo: [-61.17334, 18.5, 91.5], hi: [61.17334, 75.54702, 159.5]),
        Part(file: "Pressing_Plate_Mount", faces: 180, brepVolume: 39_983.4694,
             lo: [-30.05761, 15.47, 76.5], hi: [30.05761, 71.27, 159.5]),
        Part(file: "Top_Motor_Mount", faces: 285, brepVolume: 108_602.9939,
             lo: [-67.461, -13.5058, 297.9], hi: [67.461, 99.68448, 368.0]),
        Part(file: "2040_Extrusion_Stand", faces: 162, brepVolume: 114_349.4739,
             lo: [-63.5, -13.5, 0], hi: [63.5, 14.5, 70]),
    ]
    /// Pole slivers in core's stock 0.1 mm tessellation of each refused part.
    static let slivers: [String: Int] = [
        "Carriage_Arms": 8, "Pressing_Plate_Mount": 4, "Top_Motor_Mount": 10,
        "2040_Extrusion_Stand": 2,
    ]
    /// His three that import today.
    static let accepted = ["Base", "PillowBlock_Block_Stand_Left", "PillowBlock_Block_Stand_Right"]

    static let here = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    static func fixture(_ name: String) -> String {
        here.appendingPathComponent("Fixtures/squish_rig/\(name).step").path
    }
    /// Repo-relative file: .../app/TopOptKit/Tests/TopOptFlowsTests/<this> → up 5.
    static func repoFile(_ rel: String) -> String {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u.appendingPathComponent(rel).path
    }
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

    // MARK: - his parts: the diagnosis

    /// Core's stock tessellation of the four: not watertight; the pole slivers are the
    /// whole defect on three of them; on the 2040 stand a broken face 16 remains.
    func testDiagnosisOfTheStockTessellation() throws {
        for p in Self.refused {
            let m = try Self.stock(Self.fixture(p.file))
            XCTAssertFalse(m.watertight, p.file)
            XCTAssertEqual(m.faceCount, p.faces, p.file)
            XCTAssertEqual(StepMeshRepair.poleSliverCount(m), Self.slivers[p.file], p.file)
            let t1 = StepMeshRepair.droppingPoleSlivers(m).mesh
            print("STEP-REPAIR-DIAG \(p.file) stockTris=\(m.triangleCount) "
                + "slivers=\(StepMeshRepair.poleSliverCount(m)) t1Watertight=\(t1.watertight)")
            XCTAssertEqual(t1.watertight, p.file != "2040_Extrusion_Stand", p.file)
        }
        // The Carriage Arms slivers sit on its fillet-corner faces, one each.
        let ca = try Self.stock(Self.fixture("Carriage_Arms"))
        var sliverFaces: [Int32] = []
        for t in 0..<ca.triangleCount {
            let a = ca.indices[3 * t], b = ca.indices[3 * t + 1], c = ca.indices[3 * t + 2]
            if a == b || b == c || a == c { sliverFaces.append(ca.faceIDs[t]) }
        }
        XCTAssertEqual(sliverFaces.sorted(), [108, 112, 114, 118, 120, 134, 139, 155])
    }

    // MARK: - his parts: the repair

    /// All four come back closed + consistently oriented, with the B-rep's face count and
    /// every face id the stock import carried. Three close at T1, the 2040 stand at T2.
    func testRepairClosesTheFourAndKeepsEveryFaceID() throws {
        for p in Self.refused {
            let path = Self.fixture(p.file)
            let stock = try Self.stock(path)
            let (m, r) = StepMeshRepair.repairedWithReport(stock, path: path)
            print("STEP-REPAIR \(p.file) pass=\(r.pass.rawValue) stockTris=\(r.stockTriangles) "
                + "repairedTris=\(r.repairedTriangles) dropped=\(r.droppedSlivers) "
                + "deflection=\(r.linearDeflectionMM.map { "\($0)" } ?? "0.1 (stock)") "
                + "faces=\(m.faceCount)")
            XCTAssertTrue(m.watertight, p.file)
            XCTAssertTrue(StepMeshRepair.isClosedAndOriented(indices: m.indices), p.file)
            XCTAssertEqual(m.faceCount, p.faces, p.file)
            XCTAssertEqual(m.faceIDs.count, m.triangleCount, p.file)
            XCTAssertEqual(Set(m.faceIDs), Set(stock.faceIDs), "every CAD face id kept: \(p.file)")
            XCTAssertEqual(m.faceGeometry, stock.faceGeometry, p.file)
            XCTAssertFalse(m.pseudoFaces, p.file)
            if p.file == "2040_Extrusion_Stand" {
                XCTAssertEqual(r.pass, .retessellated)
                XCTAssertEqual(r.linearDeflectionMM, 0.05)
            } else {
                XCTAssertEqual(r.pass, .poleSlivers, p.file)
                XCTAssertEqual(r.repairedTriangles, r.stockTriangles - Self.slivers[p.file]!, p.file)
                // T1 touches nothing else: same vertices, same order of the kept triangles.
                XCTAssertEqual(m.vertices, stock.vertices, p.file)
            }
            // The full pipeline the hook will run gives the same mesh.
            let piped = try StepMeshRepair.importMesh(path: path)
            XCTAssertEqual(piped.indices, m.indices, p.file)
            XCTAssertEqual(piped.faceIDs, m.faceIDs, p.file)
        }
    }

    /// Volume and box against the B-rep. The box is within 0.1 % per axis. The volume is
    /// within 0.2 %, NOT 0.1 %: core's 0.1 mm / 0.5 rad tessellation itself sits 0.11–0.17 %
    /// off these B-reps (small bores), and the two stands that import TODAY sit at +0.113 %
    /// — a 0.1 % bar would refuse them too. What the repair adds is pinned separately:
    /// T1 changes the volume by exactly nothing.
    func testRepairedVolumeAndBoundingBoxMatchTheBrep() throws {
        for p in Self.refused {
            let path = Self.fixture(p.file)
            let stock = try Self.stock(path)
            let m = StepMeshRepair.repaired(stock, path: path)
            let vol = StepMeshRepair.signedVolume(m)
            let rel = (vol - p.brepVolume) / p.brepVolume
            let (lo, hi) = Self.box(m)
            let ext = p.hi - p.lo
            let dev = simd_max(simd_abs(lo - p.lo), simd_abs(hi - p.hi)) / ext
            print(String(format: "STEP-REPAIR-VOL %@ vol=%.4f brep=%.4f rel=%+.4f%% "
                         + "boxDev=%.5f%%/%.5f%%/%.5f%%", p.file, vol, p.brepVolume,
                         rel * 100, dev.x * 100, dev.y * 100, dev.z * 100))
            XCTAssertLessThan(abs(rel), 0.002, p.file)
            XCTAssertLessThan(dev.max(), 0.001, p.file)
            if p.file != "2040_Extrusion_Stand" {
                XCTAssertEqual(vol, StepMeshRepair.signedVolume(stock), p.file)
            }
        }
    }

    // MARK: - everything else: unchanged

    /// His three that import today, and every other STEP fixture: the gate stays closed
    /// and the mesh is byte-identical to today's import.
    func testAlreadyWatertightImportsComeBackByteIdentical() throws {
        let paths = Self.accepted.map(Self.fixture) + Self.otherWatertightSteps
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
    }

    /// RED CONTROL: force the repair's T2 on Base and the comparator above must see it.
    /// Only the gate keeps already-watertight imports byte-identical.
    func testRedControlForcedRepairIsCaught() throws {
        for name in Self.accepted {
            let path = Self.fixture(name)
            let today = try Self.stock(path)
            let forced = StepMeshRepair.droppingPoleSlivers(
                try StepMeshRepair.stockImport(path: path, linearDeflectionMM: 0.05,
                                               faceGeometry: today.faceGeometry)).mesh
            let diff = Self.differences(today, forced)
            print("STEP-REPAIR-RED \(name) today=\(today.triangleCount) forced=\(forced.triangleCount) "
                + "differs=\(diff)")
            XCTAssertFalse(diff.isEmpty, "the comparator must catch a forced repair: \(name)")
        }
    }

    // MARK: - the hook's pin

    /// PIN for the importMesh hook (TopOptKit.swift, `importMesh(path:linearDeflectionMM:)`).
    /// Before the hook, TopOptKit.importMesh still refuses all four. The hook commit flips
    /// this test: each must then equal `StepMeshRepair.importMesh` and be watertight.
    func testPinBeforeTheHookImportMeshStillRefusesTheFour() throws {
        for p in Self.refused {
            XCTAssertFalse(try TopOptKit.importMesh(path: Self.fixture(p.file)).watertight, p.file)
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
