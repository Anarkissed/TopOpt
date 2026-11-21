// FaceNamesTests — the one face namer, Lattice Setup's face rows and Topology's (the reviewer's ruling 11-06 09:41Z, part 3:
// UI-Notes' (a), from the part's own axes, a fillet "Rounded edge, R 3 mm", one namer). His rule (10-24): never a face
// number — he doesn't see ids in the app.
//
// RED before (saved: scratchpad b2red/FaceNames_build.txt): no FaceNames; the rows said "Face 12".
import XCTest
import simd
import TopOptKit
@testable import TopOptFlows

final class FaceNamesTests: XCTestCase {

    // .../app/TopOptKit/Tests/TopOptFlowsTests/<this file> -> up 5 -> repo root.
    private static let repoRoot: URL = {
        var u = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { u.deleteLastPathComponent() }
        return u
    }()

    private func mesh(_ repoPath: String) throws -> ViewerMesh {
        let m = try TopOptKit.importMesh(path: Self.repoRoot.appendingPathComponent(repoPath).path)
        return ViewerMesh(vertices: m.vertices, indices: m.indices, faceIDs: m.faceIDs,
                          faceGeometry: m.faceGeometry, pseudoFaces: m.pseudoFaces)
    }

    /// ★ The part's own axes, never the camera's: +Z up with no gravity, the world's −Y as the front, +X right. Gravity
    /// along −Y makes +Y up.
    func testTheFrameIsThePartsOwn() {
        let z = FaceNames.Frame(gravity: nil)
        XCTAssertEqual(z.up, SIMD3<Float>(0, 0, 1))
        XCTAssertEqual(z.front, SIMD3<Float>(0, -1, 0))
        XCTAssertEqual(z.right, SIMD3<Float>(1, 0, 0))
        XCTAssertEqual(FaceNames.Frame(gravity: SIMD3<Float>(0, 0, -9810)), z, "gravity down is the default frame")
        let y = FaceNames.Frame(gravity: SIMD3<Float>(0, -1, 0))
        XCTAssertEqual(y.up, SIMD3<Float>(0, 1, 0))
        XCTAssertEqual(simd_dot(y.front, y.up), 0, accuracy: 1e-6, "the front lies flat")
    }

    /// ★ The words.
    func testTheWords() {
        let f = FaceNames.Frame(gravity: nil)
        XCTAssertEqual(FaceNames.flatKind(SIMD3(0, 0, 1), f).text(1), "Top face")
        XCTAssertEqual(FaceNames.flatKind(SIMD3(0, 0, -1), f).text(1), "Underside")
        XCTAssertEqual(FaceNames.flatKind(SIMD3(0, -1, 0), f).text(1), "Front face")
        XCTAssertEqual(FaceNames.flatKind(SIMD3(0, 1, 0), f).text(1), "Back face")
        XCTAssertEqual(FaceNames.flatKind(SIMD3(1, 0, 0), f).text(1), "Right side")
        XCTAssertEqual(FaceNames.flatKind(SIMD3(-1, 0, 0), f).text(1), "Left side")
        XCTAssertEqual(FaceNames.flatKind(simd_normalize(SIMD3(0, -1, 1)), f).text(2), "Sloped face 2, facing up")
        XCTAssertEqual(FaceNames.flatKind(simd_normalize(SIMD3(0.05, 0, 1)), f).text(1), "Top face", "a few degrees of draft")
        XCTAssertEqual(FaceNames.Kind.hole(tenthsMM: 80).text(1), "Hole, \u{2300} 8 mm")
        XCTAssertEqual(FaceNames.Kind.hole(tenthsMM: 55).text(3), "Hole 3, \u{2300} 5.5 mm")
        XCTAssertEqual(FaceNames.Kind.round(tenthsMM: 220).text(1), "Round side, \u{2300} 22 mm")
        XCTAssertEqual(FaceNames.Kind.edge(tenthsMM: 30).text(2), "Rounded edge 2, R 3 mm", "★ a fillet")
    }

    /// ★ His l-bracket (STEP): every face named, none by number; its two Ø5 holes are holes; one name per face but for a
    /// hole's pieces; a name's faces numbered 1, 2, 3… with no gap; and turning gravity over swaps top and underside.
    func testTheLBracket() throws {
        let m = try mesh("core/tests/fixtures/demo/l-bracket.step")
        let faces = FaceTopology.faceIDs(in: m)
        let names = FaceNames.names(in: m, frame: .init(gravity: nil))
        XCTAssertEqual(Set(names.keys), Set(faces), "every face named")
        XCTAssertFalse(names.values.contains { $0.hasPrefix("Face ") }, "★ never a number")
        let bores = faces.filter { FaceTopology.isFastenerBore($0, in: m) }
        XCTAssertFalse(bores.isEmpty)
        for f in bores { XCTAssertTrue(names[f]!.hasPrefix("Hole") && names[f]!.hasSuffix("\u{2300} 5 mm"), "\(names[f]!)") }
        let holes = Set(bores.map { names[$0]! })
        XCTAssertEqual(holes.count, 2, "★ two holes, two names (a split hole's pieces share one): \(holes.sorted())")
        let others = faces.filter { !bores.contains($0) }.map { names[$0]! }
        XCTAssertEqual(Set(others).count, others.count, "every other face its own name: \(others.sorted())")
        assertNumberedWithoutGaps(Array(names.values))
        // turned over: a top is an underside
        let flipped = FaceNames.names(in: m, frame: .init(gravity: SIMD3(0, 0, 1)))
        for f in faces where names[f]!.hasPrefix("Top face") {
            XCTAssertTrue(flipped[f]!.hasPrefix("Underside"), "\(names[f]!) → \(flipped[f]!)")
        }
    }

    /// ★ His shelf bracket (STL, the segmenter's pieces): its three holes (Ø4, Ø9, and one split in two) and its fillets as
    /// rounded edges.
    func testTheShelfBracketsHolesAndRoundedEdges() throws {
        let m = try mesh("core/tests/fixtures/mesh/WallMount_ShelfBracket.stl")
        let names = FaceNames.names(in: m, frame: .init(gravity: nil))
        let bores = FaceTopology.faceIDs(in: m).filter { FaceTopology.isFastenerBore($0, in: m) }
        XCTAssertEqual(bores.count, 4)
        XCTAssertEqual(Set(bores.map { names[$0]! }).count, 3, "★ three holes: \(Set(bores.map { names[$0]! }).sorted())")
        XCTAssertTrue(names.values.contains { $0.hasPrefix("Rounded edge") && $0.contains(", R ") }, "★ its fillets")
        XCTAssertFalse(names.values.contains { $0.hasPrefix("Face ") }, "never a number")
        assertNumberedWithoutGaps(Array(names.values))
    }

    /// ★ One namer, read by the project under its own gravity: Lattice Setup's face rows (latticeRowName) say what it says.
    /// Its number only before the part has a mesh. The Flexible stage's rows keep their numbers until a ruling moves them
    /// (latticeSelectableName: Flexible names faces "Face n" in many more places of its own).
    @MainActor func testTheProjectNamesItsFacesWithIt() throws {
        let m = try mesh("core/tests/fixtures/demo/l-bracket.step")
        let p = ProjectModel(id: UUID(), name: "l-bracket", material: "PLA", process: .fdm, importedFile: nil, importedMesh: nil)
        XCTAssertEqual(p.faceName(3), "Face 3", "no mesh yet: its number")
        p.viewerMesh = m
        for f in FaceTopology.faceIDs(in: m) {
            XCTAssertEqual(p.faceName(f), FaceNames.name(f, in: m, frame: .init(gravity: nil)))
            XCTAssertEqual(p.latticeRowName(.face(group: UUID(), face: f)), p.faceName(f), "★ Lattice Setup's face rows")
            XCTAssertEqual(p.latticeSelectableName(.face(group: UUID(), face: f)), "Face \(f)", "Flexible's, as today")
        }
        p.force.setGravity(direction: SIMD3(0, 0, 1))   // the part turned over
        let top = try XCTUnwrap(FaceTopology.faceIDs(in: m).first { FaceNames.name($0, in: m, frame: .init(gravity: nil))!.hasPrefix("Top face") })
        XCTAssertTrue(p.faceName(top).hasPrefix("Underside"), "★ the part's own up, from its gravity: \(p.faceName(top))")
    }

    /// ★ One namer: Lattice Setup's face rows and Topology's read the same words.
    func testTheRowsReadTheNamer() throws {
        let src = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "app/TopOptKit/Sources/TopOptFlows/WorkspacePlaceholder.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("title: \"Face \\(f)\""), "Topology's face card names the face")
        XCTAssertTrue(src.contains("title: project.faceName(f)"), "Topology's face card reads the namer")
        XCTAssertTrue(src.contains("info: \"\\(project.faceName(f)) is in"), "and its (i)")
        XCTAssertFalse(src.contains("Text(\"Face \\(project.runFaceID(f))\")"), "a lattice region's member faces too")
        XCTAssertTrue(src.contains("name: project.latticeRowName(ref)"), "Lattice Setup's face rows")
        XCTAssertTrue(src.contains("LatticeSetupCopy.removed(project.latticeRowName(ref))"), "and its removed toast")
        XCTAssertFalse(src.contains("project.latticeSelectableName(ref)"), "nothing on Lattice Setup reads Flexible's name")
        let model = try String(contentsOf: Self.repoRoot.appendingPathComponent(
            "app/TopOptKit/Sources/TopOptFlows/ProjectModel.swift"), encoding: .utf8)
        XCTAssertTrue(model.contains("case let .face(_, f): return faceName(f)"), "Lattice Setup's face rows read it")
    }

    /// Each name's numbered faces run 1 (no number), 2, 3… with no gap.
    private func assertNumberedWithoutGaps(_ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        let re = try! NSRegularExpression(pattern: #"^(.*?)(?: (\d+))?(,.*)?$"#)
        var seen: [String: Set<Int>] = [:]
        for n in Set(names) {
            guard let m = re.firstMatch(in: n, range: NSRange(n.startIndex..., in: n)) else { continue }
            let base = (Range(m.range(at: 1), in: n).map { String(n[$0]) } ?? n)
                + (Range(m.range(at: 3), in: n).map { String(n[$0]) } ?? "")
            let k = Range(m.range(at: 2), in: n).flatMap { Int(n[$0]) } ?? 1
            seen[base, default: []].insert(k)
        }
        for (base, ks) in seen {
            XCTAssertEqual(ks, Set(1...ks.count), "\(base): \(ks.sorted())", file: file, line: line)
        }
    }
}
