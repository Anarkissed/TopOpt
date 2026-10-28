// FlexiblePressFixturesTests — the angled-press fixtures are what they claim (task 2026-10-07, batch AP0).
// A fixture that is not what its name says makes every later number a measurement of the wrong part.
import XCTest
import simd
@testable import TopOptFlows
@testable import TopOptKit

@MainActor
final class FlexiblePressFixturesTests: XCTestCase {

    /// The cube has 6 faces of 3600 mm²; the pad has 6 faces; the STEP cube has 6 B-rep faces (skip
    /// counted); the rounded slab's count is printed with the faces core flags as wrapping, and equals
    /// the recorded one (Fixtures/angled_press_goldens/rounded_slab.txt).
    func testFixturesAreWhatTheyClaim() async throws {
        // the 60 mm cube
        let cube = try TopOptKit.importMesh(path: try FlexiblePressFixtures.cube60Path())
        let cubeAreas = FlexiblePressFixtures.faceAreas(cube)
        print("FLEX-AP FIXTURE cube60: faces \(cube.faceCount) pseudo \(cube.pseudoFaces) watertight \(cube.watertight) areas "
              + cubeAreas.keys.sorted().map { String(format: "%d:%.6f", $0, cubeAreas[$0]!) }.joined(separator: " "))
        XCTAssertEqual(cube.faceCount, 6)
        XCTAssertTrue(cube.pseudoFaces, "an STL: core's pseudo-faces")
        XCTAssertTrue(cube.watertight)
        XCTAssertEqual(cubeAreas.count, 6)
        for (f, a) in cubeAreas { XCTAssertEqual(a, 3600, accuracy: 1e-6, "cube face \(f)") }
        let cubeProject = try FlexiblePressFixtures.cube60Project()
        XCTAssertEqual(cubeProject.importedFile?.faceCount, 6)
        XCTAssertNotNil(cubeProject.viewerMesh)
        // ★ RED CONTROL: the same instrument on a 60 × 60 × 59 box sees a face that is not 3600 mm²
        let box = try TopOptKit.importMesh(path: try FlexiblePressFixtures.write(
            "box60x60x59.stl", FlexiblePressFixtures.asciiSTL("box", FlexiblePressFixtures.boxTriangles(60, 60, 59))))
        XCTAssertTrue(FlexiblePressFixtures.faceAreas(box).values.contains { abs($0 - 3600) > 1 }, "control: the area check can fail")

        // C1's pad
        let pad = try FlexiblePressFixtures.padProject()
        print("FLEX-AP FIXTURE C1 pad: faces \(pad.importedFile?.faceCount ?? -1)")
        XCTAssertEqual(pad.importedFile?.faceCount, 6)

        // the rounded slab: recorded, never assumed
        let facts = try await FlexibleAngledGoldens.slabFacts()
        print("FLEX-AP FIXTURE rounded slab:\n" + facts)
        for kind in FlexiblePressFixtures.SlabKind.allCases {
            let slab = try TopOptKit.importMesh(path: try FlexiblePressFixtures.slabPath(kind))
            XCTAssertTrue(slab.watertight, "\(kind): closed")
            XCTAssertEqual(FlexiblePressFixtures.faceAreas(slab).values.reduce(0, +),
                           Self.slabSurfaceArea(kind), accuracy: 1e-3, "\(kind): every triangle is in a face")
        }
        try FlexibleAngledGoldens.assertGolden(facts, "rounded_slab.txt")

        // core's STEP cube (B-rep faces; a counted skip when OCCT throws)
        let step = try FlexiblePressFixtures.stepCubeProject("FlexiblePressFixturesTests.testFixturesAreWhatTheyClaim")
        let stepMesh = try TopOptKit.importMesh(path: FlexiblePressFixtures.stepCubePath)
        let stepAreas = FlexiblePressFixtures.faceAreas(stepMesh)
        print("FLEX-AP FIXTURE STEP cube: faces \(stepMesh.faceCount) pseudo \(stepMesh.pseudoFaces) areas "
              + stepAreas.keys.sorted().map { String(format: "%d:%.6f", $0, stepAreas[$0]!) }.joined(separator: " "))
        XCTAssertEqual(step.importedFile?.faceCount, 6)
        XCTAssertFalse(stepMesh.pseudoFaces, "B-rep faces")
        for (f, a) in stepAreas { XCTAssertEqual(a, 100, accuracy: 1e-6, "STEP cube face \(f) (10 mm cube)") }
    }

    /// His round-5 pad as saved is the pad he left (6 faces, top split into Top A / Top B, four presses).
    func testHisPadAndTheStandRestore() throws {
        let r = try FlexiblePressFixtures.hisRound5(self)
        XCTAssertEqual(r.project.importedFile?.faceCount, 6)
        let flex = try XCTUnwrap(r.project.lattice.flexible)
        let pressed = flex.loadedFaces.map(\.faceRegionID).sorted()
        print("FLEX-AP FIXTURE his r5: pressed \(pressed) · resting \(flex.faces.filter { !$0.isLoaded }.map(\.faceRegionID))")
        XCTAssertEqual(pressed, [3, 5, FlexibleHisProject.topA, FlexibleHisProject.topB].sorted())
        let m2 = try FlexiblePressFixtures.m2Project("FlexiblePressFixturesTests.testHisPadAndTheStandRestore")
        print("FLEX-AP FIXTURE M2 stand: faces \(m2.importedFile?.faceCount ?? -1)")
        XCTAssertGreaterThan(m2.importedFile?.faceCount ?? 0, 6)
    }

    /// A slab's exact surface: two caps (the outline polygon's shoelace area) and the side wall (the
    /// outline's length × height) — the polygon's, not the circle's.
    static func slabSurfaceArea(_ kind: FlexiblePressFixtures.SlabKind) -> Double {
        let s = FlexiblePressFixtures.slab
        let o = FlexiblePressFixtures.roundedOutline(width: s.width, depth: s.depth, radii: kind.radii, facets: s.facets)
        var area = 0.0, perimeter = 0.0
        for i in 0..<o.count {
            let a = o[i], b = o[(i + 1) % o.count]
            area += (a.x * b.y - b.x * a.y) / 2
            perimeter += simd_length(b - a)
        }
        return 2 * area + perimeter * s.height
    }
}
