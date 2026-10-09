// FlexiblePressFixtures — the parts the ANGLED PRESSES batches are judged on (task 2026-10-07,
// angled presses, batch AP0: baselines at 01ec5e3c, no behaviour change).
//
//   * cube60Project()      a 60 mm cube, written as an ASCII STL and imported through core
//                          (TopOptKit.importMesh), built the way FlexibleHisProject.padProject
//                          builds C1's pad: 6 pseudo-faces of 3600 mm² each. Its edge is the ruling's
//                          45.00° and its corner the 54.74°.
//   * roundedSlabProject() an extruded rounded rectangle, 60 × 40 × 20 mm, its four VERTICAL edges
//                          filleted (r 5 mm) with 16 facets per 90°: every crease on its side wall is
//                          under core's 8° (segment.cpp), so the dihedral growth may wrap a flat, the
//                          fillet and the next flat into one pseudo-face. The count is RECORDED, never
//                          assumed (FlexiblePressFixturesTests prints it and which faces core flags).
//                          oneFilletSlabProject() rounds ONE vertical edge and keeps three sharp.
//   * stepCubeProject()    core's own STEP fixture (core/tests/fixtures/step/cube.step, a 10 mm cube):
//                          B-rep faces. XCTSkip with a printed reason when OCCT throws (the skip is
//                          COUNTED: the line starts "FLEX-AP SKIP").
//   * his pad              FlexibleHisProject.restore(round5Dir, asSaved: true) (memory: judge with
//                          HIS project restored), C1's pad (FlexibleHisProject.padProject) and the M2
//                          stand (Fixtures/M2_verticalStand.step).
//   * the frozen S0 set    (AP0 fix-up) the A1 store's projects and his 'l bracket 3', restored from
//                          angled_presses/s0_frozen after a SHA-256 check against its SHA256SUMS.
//
// Every generated part is written once per process into its own temporary folder, from the same
// arithmetic every time, so its bytes are the same on every run.
import XCTest
import CryptoKit
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
enum FlexiblePressFixtures {

    // MARK: - where generated parts go

    nonisolated static let generatedDir: URL = {
        let d = FileManager.default.temporaryDirectory
            .appendingPathComponent("flex-ap-fixtures-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// A printed, greppable skip (the batch counts skips per class, never only greens).
    static func skip(_ test: String, _ reason: String) -> XCTSkip {
        print("FLEX-AP SKIP \(test): \(reason)")
        return XCTSkip(reason)
    }

    // MARK: - ASCII STL

    typealias Tri = (SIMD3<Double>, SIMD3<Double>, SIMD3<Double>)

    /// An ASCII STL of `tris` (each wound so its normal points OUT of the part).
    nonisolated static func asciiSTL(_ name: String, _ tris: [Tri]) -> String {
        func f(_ d: Double) -> String { String(format: "%.9g", d == 0 ? 0 : d) }
        func v(_ p: SIMD3<Double>) -> String { "\(f(p.x)) \(f(p.y)) \(f(p.z))" }
        var s = "solid \(name)\n"
        for (a, b, c) in tris {
            let n = simd_normalize(simd_cross(b - a, c - a))
            s += "  facet normal \(v(n))\n    outer loop\n"
            s += "      vertex \(v(a))\n      vertex \(v(b))\n      vertex \(v(c))\n"
            s += "    endloop\n  endfacet\n"
        }
        return s + "endsolid \(name)\n"
    }

    /// Write `text` at `name` in the generated folder (once per process; same bytes every run).
    nonisolated static func write(_ name: String, _ text: String) throws -> String {
        let url = generatedDir.appendingPathComponent(name)
        let data = Data(text.utf8)
        if (try? Data(contentsOf: url)) != data { try data.write(to: url, options: .atomic) }
        return url.path
    }

    /// A box [0, sx] × [0, sy] × [0, sz] as 12 outward-wound triangles.
    nonisolated static func boxTriangles(_ sx: Double, _ sy: Double, _ sz: Double) -> [Tri] {
        func p(_ x: Double, _ y: Double, _ z: Double) -> SIMD3<Double> { SIMD3(x * sx, y * sy, z * sz) }
        // each quad (a, b, c, d) counter-clockwise seen from OUTSIDE
        let quads: [[SIMD3<Double>]] = [
            [p(0, 0, 0), p(0, 1, 0), p(1, 1, 0), p(1, 0, 0)],   // bottom, −Z
            [p(0, 0, 1), p(1, 0, 1), p(1, 1, 1), p(0, 1, 1)],   // top, +Z
            [p(0, 0, 0), p(1, 0, 0), p(1, 0, 1), p(0, 0, 1)],   // y = 0, −Y
            [p(0, 1, 0), p(0, 1, 1), p(1, 1, 1), p(1, 1, 0)],   // y = sy, +Y
            [p(0, 0, 0), p(0, 0, 1), p(0, 1, 1), p(0, 1, 0)],   // x = 0, −X
            [p(1, 0, 0), p(1, 1, 0), p(1, 1, 1), p(1, 0, 1)],   // x = sx, +X
        ]
        return quads.flatMap { q in [(q[0], q[1], q[2]), (q[0], q[2], q[3])] }
    }

    /// The slab's outline (counter-clockwise from above): a corner of radius r > 0 is an arc of `facets`
    /// segments, a corner of radius 0 is sharp (one point). The arcs' ends are EXACT (cos/sin of a
    /// multiple of 90° written as 0 / ±1). Corners in order: +X+Y, −X+Y, −X−Y, +X−Y.
    nonisolated static func roundedOutline(width: Double, depth: Double, radii: [Double], facets: Int) -> [SIMD2<Double>] {
        let hx = width / 2, hy = depth / 2
        let signs = [SIMD2(1.0, 1.0), SIMD2(-1.0, 1.0), SIMD2(-1.0, -1.0), SIMD2(1.0, -1.0)]
        let ends = [SIMD2(1.0, 0), SIMD2(0, 1.0), SIMD2(-1.0, 0), SIMD2(0, -1.0), SIMD2(1.0, 0)]
        var pts: [SIMD2<Double>] = []
        for q in 0..<4 {
            let r = radii[q]
            let c = signs[q] * SIMD2(hx - r, hy - r)
            guard r > 0 else { pts.append(c); continue }
            for k in 0...facets {
                let deg = Double(q) * 90 + Double(k) * 90 / Double(facets)
                let dir = k == 0 ? ends[q] : k == facets ? ends[q + 1] : SIMD2(cos(deg * .pi / 180), sin(deg * .pi / 180))
                pts.append(c + r * dir)
            }
        }
        return pts
    }

    /// The outline extruded from z = 0 to `height`, its caps fanned from the centre.
    nonisolated static func extrudedTriangles(_ outline: [SIMD2<Double>], height: Double) -> [Tri] {
        var tris: [Tri] = []
        let n = outline.count
        let c0 = SIMD3<Double>(0, 0, 0), c1 = SIMD3<Double>(0, 0, height)
        for i in 0..<n {
            let a = outline[i], b = outline[(i + 1) % n]
            let a0 = SIMD3(a.x, a.y, 0), b0 = SIMD3(b.x, b.y, 0)
            let a1 = SIMD3(a.x, a.y, height), b1 = SIMD3(b.x, b.y, height)
            tris.append((a0, b0, b1)); tris.append((a0, b1, a1))     // side, outward
            tris.append((c0, b0, a0))                                // bottom, −Z
            tris.append((c1, a1, b1))                                // top, +Z
        }
        return tris
    }

    // MARK: - projects

    /// A project over a part file, built the way FlexibleHisProject.padProject builds C1's pad.
    static func project(path: String, name: String) throws -> ProjectModel {
        let m = try TopOptKit.importMesh(path: path)
        let file = ImportedFile(name: (path as NSString).lastPathComponent, path: path, triangleCount: m.triangleCount,
                                faceCount: m.faceCount, watertight: m.watertight, pseudoFaces: m.pseudoFaces)
        let pm = ProjectModel(id: UUID(), name: name, material: "ABS", process: .fdm, importedFile: file, importedMesh: m)
        pm.lattice.flexible = FlexibleStageSettings(materialID: "varioshore_tpu")
        return pm
    }

    static let cubeSideMM = 60.0

    static func cube60Path() throws -> String {
        try write("cube60.stl", asciiSTL("cube60", boxTriangles(cubeSideMM, cubeSideMM, cubeSideMM)))
    }

    /// The 60 mm cube (pseudo-faces). FlexiblePressFixturesTests asserts 6 faces of 3600 mm².
    static func cube60Project() throws -> ProjectModel { try project(path: cube60Path(), name: "cube60") }

    static let slab = (width: 60.0, depth: 40.0, height: 20.0, radius: 5.0, facets: 16)

    /// The four corners' radii of each slab: all four rounded (the batch's fixture), and ONE rounded
    /// (+X+Y) with three sharp 90° corners — a flat, its fillet and the next flat between sharp creases,
    /// the "face that wraps round the edge" of spec §5.
    enum SlabKind: String, CaseIterable {
        case rounded = "rounded_slab_60x40x20_r5_16"
        case oneFillet = "one_fillet_slab_60x40x20_r5_16"
        var radii: [Double] { self == .rounded ? [5, 5, 5, 5] : [5, 0, 0, 0] }
    }

    static func slabPath(_ kind: SlabKind = .rounded) throws -> String {
        let outline = roundedOutline(width: slab.width, depth: slab.depth, radii: kind.radii, facets: slab.facets)
        return try write(kind.rawValue + ".stl", asciiSTL(kind.rawValue, extrudedTriangles(outline, height: slab.height)))
    }
    static func roundedSlabPath() throws -> String { try slabPath(.rounded) }

    static func roundedSlabProject() throws -> ProjectModel { try project(path: roundedSlabPath(), name: "rounded slab") }
    static func oneFilletSlabProject() throws -> ProjectModel { try project(path: slabPath(.oneFillet), name: "one-fillet slab") }

    static var stepCubePath: String { FlexibleHisProject.repoRoot.appendingPathComponent("core/tests/fixtures/step/cube.step").path }

    /// Core's 10 mm STEP cube (B-rep faces). XCTSkip — printed and counted — when OCCT throws.
    static func stepCubeProject(_ test: String) throws -> ProjectModel {
        guard FileManager.default.fileExists(atPath: stepCubePath) else { throw skip(test, "core/tests/fixtures/step/cube.step is absent") }
        do { return try project(path: stepCubePath, name: "step cube") } catch {
            throw skip(test, "the STEP importer threw on cube.step: \(error)")
        }
    }

    static var m2Path: String {
        FlexibleHisProject.repoRoot.appendingPathComponent("app/TopOptKit/Tests/TopOptFlowsTests/Fixtures/M2_verticalStand.step").path
    }

    /// His M2 stand (STEP). XCTSkip — printed and counted — when OCCT throws.
    static func m2Project(_ test: String) throws -> ProjectModel {
        do { return try project(path: m2Path, name: "M2 verticalStand") } catch {
            throw skip(test, "the STEP importer threw on M2_verticalStand.step: \(error)")
        }
    }

    /// C1's pad, nothing pressed.
    static func padProject() throws -> ProjectModel {
        try FlexibleHisProject.padProject(FlexibleStageSettings(materialID: "varioshore_tpu"))
    }

    /// His round-5 pad AS SAVED (no [Lattice under it] taps), through the app's own restore.
    static func hisRound5(_ test: XCTestCase) throws -> FlexibleHisProject.Restored {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.round5Dir, asSaved: true)
        test.addTeardownBlock { r.cleanup() }
        return r
    }

    /// His round-3 pad (0004) AS SAVED.
    static func his0004(_ test: XCTestCase) throws -> FlexibleHisProject.Restored {
        let r = try FlexibleHisProject.restore(FlexibleHisProject.dir, asSaved: true)
        test.addTeardownBlock { r.cleanup() }
        return r
    }

    // MARK: - the FROZEN S0 set (AP0 fix-up)

    /// The S0 projects frozen beside the stage-job hashes (s0_frozen/README.txt): his7/ and a1/, with
    /// SHA256SUMS. The A1 store's Flexible projects are restored from HERE, never from the simulator.
    nonisolated static var frozenDir: URL {
        FlexibleHisProject.repoRoot.appendingPathComponent(
            "docs/handoffs/evidence/2026-09-29-flexible-screens/angled_presses/s0_frozen", isDirectory: true)
    }

    /// The A1 store's project n (1…4): A1000001-0000-4000-8000-00000000000n.
    nonisolated static func a1Dir(_ n: Int) -> URL {
        frozenDir.appendingPathComponent("a1/A1000001-0000-4000-8000-00000000000\(n)", isDirectory: true)
    }

    /// The recorded SHA-256 of a frozen file (its path relative to s0_frozen), from SHA256SUMS.
    static func frozenSum(_ rel: String) throws -> String {
        let sums = try String(contentsOf: frozenDir.appendingPathComponent("SHA256SUMS"), encoding: .utf8)
        let line = try XCTUnwrap(sums.split(separator: "\n").first { $0.hasSuffix("  " + rel) }, "\(rel) is in SHA256SUMS")
        return String(line.prefix(64))
    }

    /// Fails unless every file of the frozen project folder `dir` has its recorded SHA-256 (a moved
    /// input is a different part, so its golden would measure the wrong thing).
    static func assertFrozen(_ dir: URL) throws {
        let rel = dir.deletingLastPathComponent().lastPathComponent + "/" + dir.lastPathComponent
        for f in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
            let now = SHA256.hash(data: try Data(contentsOf: dir.appendingPathComponent(f))).map { String(format: "%02x", $0) }.joined()
            XCTAssertEqual(now, try frozenSum("\(rel)/\(f)"), "★ the frozen input \(rel)/\(f) moved")
        }
    }

    /// The A1 store's project n AS SAVED, from the frozen copy, through the app's own restore.
    static func a1Project(_ n: Int, _ test: XCTestCase) throws -> FlexibleHisProject.Restored {
        try assertFrozen(a1Dir(n))
        let r = try FlexibleHisProject.restore(a1Dir(n), asSaved: true)
        test.addTeardownBlock { r.cleanup() }
        return r
    }

    /// His 'l bracket 3' (S0's 92A8016E, a STEP part), frozen. XCTSkip — printed and counted — when OCCT throws.
    static func lBracketProject(_ test: String) throws -> ProjectModel {
        let dir = frozenDir.appendingPathComponent("his7/92A8016E-FCCD-421D-B19E-4A1EC81C98A5", isDirectory: true)
        try assertFrozen(dir)
        do { return try project(path: dir.appendingPathComponent("model.step").path, name: "l bracket 3") } catch {
            throw skip(test, "the STEP importer threw on the l bracket: \(error)")
        }
    }

    // MARK: - facts

    /// Each face id's area (mm²), summed in Double over its triangles.
    nonisolated static func faceAreas(_ m: ImportedMesh) -> [Int: Double] {
        var out: [Int: Double] = [:]
        func p(_ i: Int32) -> SIMD3<Double> {
            let k = Int(i) * 3
            return SIMD3(Double(m.vertices[k]), Double(m.vertices[k + 1]), Double(m.vertices[k + 2]))
        }
        for t in 0..<m.triangleCount {
            let a = p(m.indices[3 * t]), b = p(m.indices[3 * t + 1]), c = p(m.indices[3 * t + 2])
            out[Int(m.faceIDs[t]), default: 0] += simd_length(simd_cross(b - a, c - a)) / 2
        }
        return out
    }
}
